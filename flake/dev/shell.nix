{ inputs, ... }:
{
  perSystem =
    {
      config,
      pkgs,
      ...
    }:
    let
      luarcPkgs = pkgs.extend inputs.gen-luarc.overlays.default;
    in
    {
      devShells.default = pkgs.mkShell {
        name = "neotest-nix-dev";
        shellHook = ''
          ${config.pre-commit.installationScript}
          ln -fs ${luarcPkgs.luarc-to-json config.pre-commit.settings.hooks.lua-ls.settings.configuration} .luarc.json
        '';
        packages =
          config.pre-commit.settings.enabledPackages
          ++ (with pkgs; [
            lua-language-server
            nil
            nixfmt
          ]);
      };
    };
}
