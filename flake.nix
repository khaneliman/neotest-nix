{
  description = "A Neotest adapter for Nix flakes.";

  nixConfig = {
    extra-substituters = [
      "https://nix-community.cachix.org"
      "https://neotest-nix.cachix.org"
    ];
    extra-trusted-public-keys = [
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      "neotest-nix.cachix.org-1:6XwnLB/F0uhwJkg+yDehvd7PJb77uXi+/X0zBv784d0="
    ];
  };

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";

    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs =
    inputs@{
      nixpkgs,
      flake-parts,
      ...
    }:
    let
      name = "neotest-nix";
      plugin-overlay = final: prev: {
        vimPlugins = prev.vimPlugins // {
          # Grammar-only plugin built straight from the upstream tree-sitter-nix
          # grammar, so the adapter depends on the parser alone rather than on
          # the nvim-treesitter plugin. The runtime code loads it through the
          # built-in vim.treesitter APIs.
          tree-sitter-nix-grammar = prev.neovimUtils.grammarToPlugin prev.tree-sitter-grammars.tree-sitter-nix;

          neotest-nix = prev.vimUtils.buildVimPlugin {
            pname = name;
            version = "2.1.2"; # x-release-please-version
            # Allowlist only the files the plugin ships. maybeMissing entries
            # are picked up automatically if/when those runtime dirs are added.
            src = final.lib.fileset.toSource {
              root = ./.;
              fileset = final.lib.fileset.unions [
                ./LICENSE
                ./lua
                ./queries
                (final.lib.fileset.maybeMissing ./doc)
                (final.lib.fileset.maybeMissing ./plugin)
                (final.lib.fileset.maybeMissing ./after)
                (final.lib.fileset.maybeMissing ./ftplugin)
              ];
            };
            dependencies = [
              final.vimPlugins.neotest
              final.vimPlugins.nvim-nio
              final.vimPlugins.tree-sitter-nix-grammar
            ];
            doCheck = false;
          };
        };
      };
    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        flake-parts.flakeModules.partitions
      ];

      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      partitions = {
        dev = {
          module = ./flake/dev;
          extraInputsFlake = ./flake/dev;
        };
      };

      partitionedAttrs = {
        checks = "dev";
        devShells = "dev";
        formatter = "dev";
      };

      perSystem =
        {
          config,
          pkgs,
          system,
          ...
        }:
        {
          _module.args.pkgs = import nixpkgs {
            inherit system;
            overlays = [
              plugin-overlay
            ];
          };

          legacyPackages = pkgs;

          packages.neotest-nix = pkgs.vimPlugins.neotest-nix;
          packages.default = config.packages.neotest-nix;

          # Regenerate doc/neotest-nix.txt from the LuaCATS annotations in
          # lua/neotest-nix/types.lua. `nix run .#docgen` from the repo root.
          apps.docgen = {
            type = "app";
            meta.description = "Regenerate doc/neotest-nix.txt from LuaCATS annotations with vimcats";
            program = toString (
              pkgs.writeShellScript "neotest-nix-docgen" ''
                exec ${pkgs.vimcats}/bin/vimcats -a lua/neotest-nix/types.lua > doc/neotest-nix.txt
              ''
            );
          };
        };

      flake.overlays.default = plugin-overlay;
    };
}
