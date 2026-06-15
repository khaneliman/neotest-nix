#!/usr/bin/env bash
# Run the neotest-nix discovery benchmark headless, inside the dev shell so the
# nix tree-sitter grammar, neotest, and nio are available (the dev shell exports
# NEOTEST_NIX_TEST_RTP, which tests/minimal_init.lua puts on the runtimepath).
#
#   scripts/bench.sh ~/Documents/github/nixpkgs [--profile] [--eval] [--json]
set -euo pipefail
cd "$(dirname "$0")/.."
exec nix develop --command \
  nvim --headless -u tests/minimal_init.lua -l scripts/bench.lua "$@"
