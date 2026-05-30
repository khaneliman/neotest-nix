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
      baseLuarc = luarcPkgs.mk-luarc {
        nvim = luarcPkgs.neovim-unwrapped;
        plugins = with luarcPkgs.vimPlugins; [
          neotest
          nvim-nio
        ];
        disabled-diagnostics = [
          "duplicate-set-field"
          "undefined-doc-class"
          "undefined-doc-name"
          # luassert's assert.* fields are built dynamically; EmmyLua has no
          # type defs for them, so disable the field check rather than annotate.
          "undefined-field"
        ];
      };
      # mk-luarc has no `globals` knob, so merge busted's test globals into its
      # output. One .luarc.json then serves both lua-language-server and EmmyLua.
      luarc = luarcPkgs.lib.recursiveUpdate baseLuarc {
        diagnostics.globals = [
          "describe"
          "it"
          "before_each"
          "after_each"
          "pending"
          "setup"
          "teardown"
          "lazy_setup"
          "lazy_teardown"
          "finally"
          "insulate"
          "expose"
          "randomize"
          "assert"
          "spy"
          "stub"
          "mock"
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
