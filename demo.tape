# Demo recording for neotest-nix, tailored to a home-manager checkout.
# Regenerate the gif with:
#   DEMO_DIR=/path/to/home-manager nix run nixpkgs#vhs -- demo.tape
#
# IMPORTANT: `nvim` on PATH must be your configured editor (e.g. khanelivim),
# not a bare nvim. neotest is lazy-loaded, so the `:Neotest` ex-commands do
# not exist until a <leader>t* keymap triggers it -- this tape drives neotest
# through those keymaps. Leader is assumed to be <Space>; adjust if yours
# differs.
#
# The home-manager `test-*` derivations live under legacyPackages.<system>,
# so they only appear with eval discovery enabled on the adapter:
#
#   require("neotest-nix")({
#     discover_eval_checks = true,
#     eval_outputs = {
#       { attr = "checks" },
#       { attr = "legacyPackages", match = "^test%-" },
#     },
#   })
#
# Pre-warm before recording so the gif isn't an uncached eval/build:
#   ( cd "$DEMO_DIR" && nix eval .#legacyPackages.x86_64-linux --apply builtins.attrNames >/dev/null )
#   ( cd "$DEMO_DIR" && nix build .#legacyPackages.x86_64-linux.test-abaddon-example-config )
# Bump the Sleep after the run if your machine rebuilds it.

Output assets/demo.gif

Set Shell "zsh"
Set FontSize 14
Set Width 1400
Set Height 860
Set Theme "Catppuccin Mocha"
Set Padding 20

Hide
Type "cd ${DEMO_DIR:-.}" Enter
Type "nvim flake.nix" Enter
Sleep 3s
Show

# <leader>tt -> Neotest summary (also lazy-loads neotest). Eval discovery
# enumerates the legacyPackages tests; give it time to populate.
Space
Type "tt"
Sleep 6s

# Focus the summary window to the right (<leader>] in this config), then
# jump to a single test.
Space
Type "]"
Sleep 1s
Type "/test-abaddon-example-config" Enter
Sleep 1s

# Run the highlighted test (neotest summary's built-in mapping), then open
# the output panel right away so the build streams live below.
Type "r"
Sleep 500ms
Space
Type "to"
Sleep 12s

Hide
Type ":qa!" Enter
