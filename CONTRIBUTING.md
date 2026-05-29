# Contributing

## Welcome to the Project

Thank you for your interest in contributing. This document defines the technical and operational expectations for repository layout, code quality standards, and the automated release lifecycle. Contributors should be comfortable with basic Git and GitHub workflows; GitHub's quickstart is a good starting point: <https://docs.github.com/en/get-started/quickstart/hello-world>.

## First-Time Contributors

Issues labeled `good-first-issue` are intended to be approachable entry points. If an issue is unclear, ask before opening a large pull request so the scope can be confirmed early.

## Repository Topography

The codebase strictly separates initialization routines from core business logic to minimize impact on Neovim startup latency:

- `lua/<plugin-name>/`: Core business logic, utility functions, and state management. Code here should be parsed and compiled only when explicitly invoked by a `require()` call.
- `plugin/`: Unconditional editor entry points, including user commands and core autocommands. Keep this layer strictly lightweight.
- `ftplugin/`: Logic and configuration bound to specific language filetypes.
- `tests/` or `spec/`: Unit and integration tests, isolated from distributable plugin code.

## Local Development Environment

All development must take place within the declarative Nix flake environment to avoid local environment drift.

Run:

```sh
nix develop
```

You may also rely on `direnv` for automatic shell activation:

```sh
direnv allow
```

The development shell provisions the required Lua interpreter, Neovim builds for stable and nightly testing, and linting tools such as StyLua, Luacheck, markdownlint, and nixfmt when those checks are available.

### Language Server Support

When the shell initializes, a `shellHook` uses the Nix derivation to dynamically generate and symlink `.luarc.json`. This configures `lua-language-server` to recognize Neovim internal APIs and external plugin dependencies. Do not manually edit `.luarc.json`.

## API Standards and LuaCATS Type Safety

Use modern Neovim Lua APIs:

- Configure editor options with `vim.opt`.
- Establish mappings with `vim.keymap.set`.
- Register autocommands with `vim.api.nvim_create_autocmd`.

Avoid legacy Vimscript wrappers such as `vim.cmd` for configuration.

Do not create many granular global user commands. Consolidate user-facing actions behind one primary root command with hierarchical subcommands and completion.

Although Lua is dynamically typed, this project uses Lua Custom Annotations for Type System (LuaCATS) to keep module boundaries clear. Annotate configuration objects, module APIs, and parameter definitions with `---@class`, `---@type`, and `---@param` metadata.

## Pull Request Anatomy and Testing

All modifications must pass the project’s CI checks before merge.

When pre-commit hooks are available, prefer the umbrella command:

```sh
pre-commit run --all
```

Otherwise, run formatting and linting directly:

```sh
stylua .
luacheck lua/ tests/
markdownlint .
nixfmt .
```

Run behavioral tests with Busted through Neovim:

```sh
vusted tests/
```

CI-style Neovim tests are managed with `neorocksTest` inside the Nix matrix to verify compatibility across Neovim stable and nightly. Avoid `plenary.nvim`; prefer Neovim built-ins such as `vim.system`, `vim.fs`, and `vim.uv`, with focused test tooling through `vusted` or `neorocksTest`.

For CI parity, use the Nix checks when available:

```sh
nix build .#checks..ci --print-build-logs
nix build .#checks..formatting --print-build-logs
nix build .#checks.<system>.nvim-stable-test --print-build-logs
nix build .#checks.<system>.nvim-nightly-test --print-build-logs
nix flake check --print-build-logs
```

Pull requests should include:

- A concise summary of the change.
- Commands run locally.
- Known gaps or follow-up work.
- Linked issues when applicable.
- A Conventional Commit PR title, including an appropriate prefix and scope when useful.

## Vimdoc and Tags

If help documentation is generated from LuaCATS annotations, configuration API changes may require regenerating vimdoc or tags. Prefer `pre-commit run --all` from inside the Nix dev shell when CI reports generated documentation drift.

## Commit Conventions

Use Conventional Commit syntax for all commits, such as `feat:`, `fix:`, `test:`, and `chore:`. Include scopes when they clarify the affected area, for example `feat(discovery): add flake query`. Keep the subject under 50 characters and include a message body on every commit so rationale, verification, and follow-up context do not get crammed into the subject. Keep commits atomic so each change is easy to review, test, bisect, or revert. Commit metadata is used as the foundation for automated GitHub releases, semantic versioning, and LuaRocks artifact publishing.
