{
  description = "A Neotest adapter for Nix flakes.";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";

    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs =
    inputs@{
      self,
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
            src = self;
            dependencies = with prev.vimPlugins; [
              neotest
              nvim-nio
              plenary-nvim
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
        { system, ... }:
        {
          _module.args.pkgs = import nixpkgs {
            inherit system;
            overlays = [
              plugin-overlay
            ];
          };

          packages.default = self.packages.${system}.neotest-nix;
          packages.neotest-nix = self.legacyPackages.${system}.vimPlugins.neotest-nix;
          legacyPackages = import nixpkgs {
            inherit system;
            overlays = [
              plugin-overlay
            ];
          };
        };

      flake.overlays.default = plugin-overlay;
    };
}
