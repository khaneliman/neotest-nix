{
  perSystem =
    { pkgs, ... }:
    {
      treefmt = {
        flakeCheck = true;
        flakeFormatter = true;
        projectRootFile = "flake.nix";

        programs = {
          mdformat.enable = true;
          nixfmt = {
            enable = true;
            package = pkgs.nixfmt;
          };
          statix.enable = true;
          stylua.enable = true;
          taplo.enable = true;
        };

        settings.global.excludes = [
          "*.luacheckrc"
          "LICENSE"
          "flake.lock"
        ];
      };
    };
}
