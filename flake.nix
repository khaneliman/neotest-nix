{
  description = "A Neotest adapter for Nix flakes.";

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
          neotest-nix = prev.vimUtils.buildVimPlugin {
            pname = name;
            version = "0.0.0";
            # Allowlist only the files the plugin ships. Adding a new
            # runtime dir (doc/, plugin/, after/, ...) means adding it here.
            src = final.lib.fileset.toSource {
              root = ./.;
              fileset = final.lib.fileset.unions [
                ./LICENSE
                ./lua
                ./queries
              ];
            };
            dependencies = with prev.vimPlugins; [
              neotest
              nvim-treesitter.grammarPlugins.nix
              nvim-nio
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
        "x86_64-darwin"
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
        };

      flake.overlays.default = plugin-overlay;
    };
}
