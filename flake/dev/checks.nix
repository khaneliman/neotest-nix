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
      luarc = luarcPkgs.mk-luarc {
        nvim = luarcPkgs.neovim-unwrapped;
        plugins = with luarcPkgs.vimPlugins; [
          neotest
          nvim-nio
          plenary-nvim
        ];
        disabled-diagnostics = [
          "duplicate-set-field"
          "undefined-doc-class"
          "undefined-doc-name"
        ];
      };
    in
    {
      pre-commit = {
        check.enable = false;
        settings.hooks = {
          editorconfig-checker.enable = true;
          luacheck.enable = true;
          lua-ls = {
            enable = true;
            settings.configuration = luarc;
          };
          treefmt.enable = true;
        };
      };

      checks = {
        pre-commit-hooks = config.pre-commit.settings.run;
      };
    };
}
