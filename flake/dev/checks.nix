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
      neorocksPkgs = pkgs.extend inputs.neorocks.overlays.default;
      nixParser = pkgs.neovimUtils.grammarToPlugin pkgs.tree-sitter-grammars.tree-sitter-nix;
      luarc = luarcPkgs.mk-luarc {
        nvim = luarcPkgs.neovim-unwrapped;
        plugins = with luarcPkgs.vimPlugins; [
          neotest
          nvim-nio
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
        nvim-stable-test = neorocksPkgs.neorocksTest {
          name = "nvim-stable-test";
          pname = "neotest-nix";
          src = ../..;
          neovim = neorocksPkgs.neovim-unwrapped;
          luaPackages =
            ps: with ps; [
              neotest
              nvim-nio
            ];
          preCheck = ''
            export NEOTEST_NIX_TEST_RTP="${nixParser}"
          '';
        };
        nvim-nightly-test = neorocksPkgs.neorocksTest {
          name = "nvim-nightly-test";
          pname = "neotest-nix";
          src = ../..;
          neovim = neorocksPkgs.neovim-nightly;
          luaPackages =
            ps: with ps; [
              neotest
              nvim-nio
            ];
          preCheck = ''
            export NEOTEST_NIX_TEST_RTP="${nixParser}"
          '';
        };
      };
    };
}
