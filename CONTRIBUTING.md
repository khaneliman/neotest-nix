# Contributing

Thanks for your interest in improving `neotest-nix`. This guide covers the
repository layout, the Nix-based development environment, and the checks your
change needs to pass before it can be merged.

Contributions of all sizes are welcome — bug reports, failing-test
reproductions, documentation fixes, and features. If you are unsure whether an
idea fits, open an issue first so the scope can be agreed before you invest time
in a pull request.

## Repository Layout

This is a [Neotest](https://github.com/nvim-neotest/neotest) adapter, so it is a
pure Lua plugin with a tree-sitter query and a Nix packaging layer. There is no
`plugin/` or `ftplugin/` directory — the adapter is loaded by Neotest, not by
Neovim's runtime, and it exposes no user commands.

| Path | Contents |
| ------------------------ | ------------------------------------------------------------------- |
| `lua/neotest-nix/` | Adapter implementation, one module per responsibility. |
| `queries/nix/` | Tree-sitter query that drives position discovery. |
| `tests/` | Busted specs plus `minimal_init.lua` and fixtures. |
| `flake.nix` | Consumer-facing outputs: the `neotest-nix` package and overlay. |
| `flake/dev/` | Development-only flake: dev shell, formatter, and CI checks. |
| `neotest-nix-scm-1.rockspec` | LuaRocks rockspec used for local testing and packaging. |

The Lua modules are deliberately small and single-purpose:

- `init.lua` — adapter entry point; wires the modules together and exposes the
  Neotest hooks (`root`, `is_test_file`, `build_spec`, `results`, …) plus
  `setup`.
- `positions.lua` — tree-sitter query loading and position building.
- `eval.lua` — optional `nix eval` discovery of generated flake outputs.
- `discover.lua` — root detection and "is this a test file?" rules.
- `spec.lua` — turns a position into a `nix` / `nix build` / `nix-unit` run
  command.
- `process.lua` — the run strategy (streams `vim.system` output to Neotest).
- `results.lua` — parses command output into pass/fail results and diagnostics.
- `parser.lua` — ensures the `nix` tree-sitter grammar is on the runtimepath.
- `paths.lua` — translates `/nix/store/...-source` paths back to the worktree.
- `vm.lua` — parses NixOS VM test (Python) tracebacks.
- `types.lua` — annotation-only module: LuaCATS for the public config types and
  the user manual; the single source `vimcats` compiles into `doc/`.

## Development Environment

All development happens inside the project's Nix flake so everyone shares the
same tool versions. From the repository root:

```sh
nix develop
```

Or, with [`direnv`](https://direnv.net/) for automatic activation:

```sh
direnv allow
```

The shell provides Neovim, the Lua test runner (`vusted`),
`lua-language-server`, `nix-unit`, `vimcats` (Vimdoc generation), the
formatters, and the linters.

### Language Server Setup

On entry, the shell's `shellHook` writes and symlinks `.luarc.json` so that
`lua-language-server` understands Neovim's APIs and the `neotest` / `nvim-nio`
dependencies. This file is generated and git-ignored — do not edit it by hand.
The shell also exports `NEOTEST_NIX_TEST_RTP`, which points the test harness at
the `nix` tree-sitter grammar.

## Coding Standards

- Target **Neovim >= 0.11** and prefer built-ins over external libraries:
  `vim.system`, `vim.fs`, `vim.uv`, and `vim.treesitter`. The adapter does not
  depend on `plenary.nvim`.
- Annotate module APIs, parameters, and configuration objects with
  [LuaCATS](https://luals.github.io/wiki/annotations/) (`---@class`, `---@param`,
  `---@return`, `---@type`). The type annotations keep module boundaries clear
  and power the language-server diagnostics that CI runs.
- Keep modules focused; match the existing style (enforced by StyLua and
  Luacheck, so let the formatter make those decisions).

## Testing

Behavioral tests run with Busted through Neovim via `vusted`:

```sh
vusted tests/
```

Tests live in `tests/`, share `tests/minimal_init.lua`, and use the fixtures in
`tests/fixtures/`. Please add or update a spec for any behavior change — the
suite is the contract for discovery, run-spec building, and result parsing.

## Documentation

The Vimdoc at `doc/neotest-nix.txt` is generated from the LuaCATS annotations in
`lua/neotest-nix/types.lua` with [`vimcats`](https://github.com/mrcjkb/vimcats);
do not edit it by hand. Regenerate it from the repository root with:

```sh
nix run .#docgen
```

A `docgen` pre-commit hook runs the same generation and stages the result, so
the Vimdoc lands in the same commit as the change that prompted it. The hook
also runs in CI (via the pre-commit checks), where it fails if the committed
`doc/neotest-nix.txt` is out of date.

## Checks

Before every commit, confirm all of the following pass:

- `nix fmt` — tree is formatted.
- `pre-commit run --all-files` — formatters, linters, and `lua-ls` type checks.
- `vusted tests/` — the Busted suite.

A green Busted suite is not enough on its own; `lua-ls` type diagnostics fail CI
even when tests pass. CI runs these same checks and rejects commits that skip
them.

Every pull request must pass the same checks CI runs. Run the formatter and
linters through the pre-commit umbrella (the config is generated by the dev
shell):

```sh
pre-commit run --all-files
```

Formatting is handled by [`treefmt`](https://github.com/numtide/treefmt)
(StyLua, nixfmt, statix, taplo, and mdformat). You can format the tree directly
with:

```sh
nix fmt
```

For full CI parity, build the flake checks. `nix flake check` runs all of them;
the individual checks (substitute your system, e.g. `x86_64-linux`) are:

```sh
nix flake check --print-build-logs

nix build .#checks.<system>.treefmt --print-build-logs
nix build .#checks.<system>.pre-commit-hooks --print-build-logs
nix build .#checks.<system>.nvim-stable-test --print-build-logs
nix build .#checks.<system>.nvim-nightly-test --print-build-logs
```

The `nvim-stable-test` and `nvim-nightly-test` checks run the Busted suite
against Neovim stable and nightly so adapter changes stay compatible with both.

## Pull Requests

Please include:

- A concise summary of what changed and why.
- The commands you ran locally to verify it (e.g. `vusted tests/`,
  `nix flake check`).
- Any known gaps or follow-up work.
- Linked issues, when applicable.
- A [Conventional Commit](https://www.conventionalcommits.org/) PR title.

## Commits and Releases

Use Conventional Commit syntax for every commit: `feat:`, `fix:`, `test:`,
`docs:`, `refactor:`, `chore:`, and so on. Add a scope when it clarifies the
affected area, for example `feat(discovery): enumerate eval checks`. Keep the
subject under 50 characters and put rationale, verification, and follow-up
context in the body. Keep commits atomic so each change is easy to review, test,
bisect, and revert.

Commit history is the source of truth for automation:
[release-please](https://github.com/googleapis/release-please) opens release
PRs and tags versions from the commit log, and tagged releases are published to
[LuaRocks](https://luarocks.org/modules/khaneliman/neotest-nix) automatically.
</content>
</invoke>
