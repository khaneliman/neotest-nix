{ inputs, ... }:
{
  perSystem =
    {
      config,
      pkgs,
      system,
      ...
    }:
    let
      luarcPkgs = pkgs.extend inputs.gen-luarc.overlays.default;
      neorocksPkgs = pkgs.extend inputs.neorocks.overlays.default;
      nixParser = pkgs.neovimUtils.grammarToPlugin pkgs.tree-sitter-grammars.tree-sitter-nix;

      # Neovim >= 0.11 is the coding-standards floor (CONTRIBUTING.md), but
      # neither of the checks below actually pins to it: nixpkgs-unstable's
      # `neovim-unwrapped` and `neovim-nightly` are both already well past it
      # (0.12+ as of writing). Pull a real 0.11.x from the nixos-25.05 release
      # branch instead, via a hash-pinned `fetchTarball` rather than a flake
      # input: a flake input would mean editing flake/dev/flake.nix and
      # flake/dev/flake.lock, doubling the surface this change touches, and a
      # *branch* input would move under us. `neovim-unwrapped` there is
      # 0.11.5 (verified) and its closure is fully cached on
      # cache.nixos.org (~23 MiB, no source build), so this costs one small
      # substitution, not a second nixpkgs checkout.
      nixpkgs-0-11-src = builtins.fetchTarball {
        url = "https://github.com/NixOS/nixpkgs/archive/ac62194c3917d5f474c1a844b6fd6da2db95077d.tar.gz";
        sha256 = "16KkgfdYqjaeRGBaYsNrhPRRENs0qzkQVUooNHtoy2w=";
      };
      pkgs-0-11 = import nixpkgs-0-11-src {
        inherit system;
        config = { };
      };
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
          # Regenerate doc/neotest-nix.txt from the LuaCATS annotations in
          # types.lua and stage it, so the vimdoc lands in the same commit as
          # the change. In CI this gates staleness: if the committed doc does
          # not match the source, vimcats rewrites it and pre-commit fails.
          docgen = {
            enable = true;
            name = "regenerate vimdoc (vimcats)";
            entry = toString (
              pkgs.writeShellScript "neotest-nix-docgen-hook" ''
                set -eu
                ${pkgs.vimcats}/bin/vimcats -a lua/neotest-nix/types.lua > doc/neotest-nix.txt
                git add doc/neotest-nix.txt 2>/dev/null || true
              ''
            );
            files = "^(lua/neotest-nix/types\\.lua|doc/neotest-nix\\.txt)$";
            pass_filenames = false;
          };
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
        # Exercises the documented Neovim >= 0.11 floor itself, rather than
        # relying on stable/nightly happening to be new enough. `neovim`
        # comes from the pinned nixpkgs-0-11-src above; the Lua rocks
        # environment (`luaPackages`) still comes from this system's own
        # neorocksPkgs, matching nvim-stable-test/nvim-nightly-test -- only
        # the Neovim binary itself needs to be the older one.
        nvim-0-11-test = neorocksPkgs.neorocksTest {
          name = "nvim-0-11-test";
          pname = "neotest-nix";
          src = ../..;
          neovim = pkgs-0-11.neovim-unwrapped;
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
