#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
exec nix develop --command \
  nvim --headless -u tests/minimal_init.lua -l scripts/bench-results.lua "$@"
