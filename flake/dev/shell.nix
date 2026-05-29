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
      nixParser = pkgs.neovimUtils.grammarToPlugin pkgs.tree-sitter-grammars.tree-sitter-nix;
      testPlugins = with pkgs.vimPlugins; [
        neotest
        nixParser
        nvim-nio
      ];
    in
    {
      devShells.default = pkgs.mkShell {
        name = "neotest-nix-dev";
        shellHook = ''
          ${config.pre-commit.installationScript}
          ln -fs ${luarcPkgs.luarc-to-json config.pre-commit.settings.hooks.lua-ls.settings.configuration} .luarc.json
          export NEOTEST_NIX_TEST_RTP="${pkgs.lib.makeSearchPathOutput "out" "" testPlugins}"
        '';
        packages =
          config.pre-commit.settings.enabledPackages
          ++ (with pkgs; [
            lua51Packages.vusted
            lua-language-server
            nil
            nix-unit
            nixfmt
          ]);
      };
    };
}
