# neotest-nix

[![CI](https://github.com/khaneliman/neotest-nix/actions/workflows/ci.yml/badge.svg)](https://github.com/khaneliman/neotest-nix/actions/workflows/ci.yml)
[![LuaRocks](https://img.shields.io/luarocks/v/khaneliman/neotest-nix?logo=lua&color=purple)](https://luarocks.org/modules/khaneliman/neotest-nix)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)

A [Neotest](https://github.com/nvim-neotest/neotest) adapter for running Nix
tests directly from Neovim.

It discovers two kinds of tests in a flake-based project and runs them in place:

- **Flake checks** — `checks.<system>.<name>` derivations, including NixOS VM
  tests with a `testScript`. Run with `nix`.
- **nix-unit tests** — attribute sets shaped `{ expr = ...; expected = ...; }`
  (or `expectedError`). Run with [`nix-unit`](https://github.com/nix-community/nix-unit).

## Requirements

- Neovim >= 0.10
- [Nix](https://nixos.org/) with the `nix-command` and `flakes` features enabled
- [`nix-unit`](https://github.com/nix-community/nix-unit) on `PATH` (only for
  nix-unit tests)
- Plugin dependencies: [`neotest`](https://github.com/nvim-neotest/neotest),
  [`nvim-nio`](https://github.com/nvim-neotest/nvim-nio), and the
  [`tree-sitter-nix`](https://github.com/nvim-treesitter/nvim-treesitter)
  grammar

## Installation

### lazy.nvim

```lua
{
  "nvim-neotest/neotest",
  dependencies = {
    "nvim-neotest/nvim-nio",
    "nvim-treesitter/nvim-treesitter",
    "khaneliman/neotest-nix",
  },
  opts = {
    adapters = {
      ["neotest-nix"] = {},
    },
  },
}
```

If you configure Neotest directly rather than through `opts.adapters`:

```lua
require("neotest").setup({
  adapters = {
    require("neotest-nix"),
  },
})
```

### Nix (flake)

This repo ships an overlay that exposes `vimPlugins.neotest-nix`:

```nix
{
  inputs.neotest-nix.url = "github:khaneliman/neotest-nix";

  # in your nixpkgs config:
  nixpkgs.overlays = [ inputs.neotest-nix.overlays.default ];
}
```

The packaged plugin pulls in `neotest`, `nvim-nio`, and the nix grammar as
runtime dependencies.

## Usage

Open a `flake.nix` (or a `*.nix` file with `test` in its name containing
nix-unit assertions) and use the standard Neotest commands:

```lua
require("neotest").run.run()              -- nearest test
require("neotest").run.run(vim.fn.expand("%")) -- whole file
require("neotest").summary.toggle()       -- test tree
```

## Configuration

All options are optional. Defaults shown:

```lua
require("neotest-nix")({
  -- Extra runtimepath roots containing parser/nix.so, in case the nix
  -- tree-sitter grammar is not already on your runtimepath.
  parser_runtime_paths = nil,

  -- Evaluate the flake to discover generated outputs that are not visible
  -- in the source (e.g. checks produced by a function). Off by default
  -- because it shells out to `nix eval`.
  discover_eval_checks = false,

  -- Which outputs to enumerate when discover_eval_checks is enabled.
  -- Each entry is { attr = <output>, match = <lua pattern, optional> }.
  eval_outputs = { { attr = "checks" } },
})
```

| Option | Type | Default | Description |
| ---------------------- | -------------------------- | -------------------- | ------------------------------------------------------------------------ |
| `parser_runtime_paths` | `string[]?` | `nil` | Extra runtimepath roots containing `parser/nix.so`. |
| `discover_eval_checks` | `boolean?` | `false` | Evaluate the flake to discover outputs not present in the source. |
| `eval_outputs` | `neotest-nix.EvalOutput[]?` | `{ { attr = "checks" } }` | Outputs to enumerate per system when `discover_eval_checks` is on. |

## How discovery works

- `flake.nix` is always treated as a test file.
- Any other `*.nix` file is considered a test file only when its name contains
  `test` **and** it contains a nix-unit assertion (`expr` plus `expected` or
  `expectedError`).
- Positions are parsed from source with tree-sitter. When
  `discover_eval_checks` is enabled, flake outputs are additionally enumerated
  via `nix eval` and merged into the tree, so checks generated at evaluation
  time still show up.

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md). Development happens inside the Nix
dev shell:

```sh
nix develop   # or: direnv allow
```

Run the checks the way CI does:

```sh
nix flake check --print-build-logs
```

## License

[MIT](./LICENSE) © Austin Horstman
