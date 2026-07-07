# neotest-nix

[![CI](https://github.com/khaneliman/neotest-nix/actions/workflows/ci.yml/badge.svg)](https://github.com/khaneliman/neotest-nix/actions/workflows/ci.yml)
[![LuaRocks](https://img.shields.io/luarocks/v/khaneliman/neotest-nix?logo=lua&color=purple)](https://luarocks.org/modules/khaneliman/neotest-nix)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)

A [Neotest](https://github.com/nvim-neotest/neotest) adapter for running Nix
tests directly from Neovim.

It discovers four kinds of tests and runs them in place:

- **Flake checks** — `checks.<system>.<name>` derivations, including NixOS VM
  tests with a `testScript`. Run with `nix`.
- **nix-unit tests** — attribute sets shaped `{ expr = ...; expected = ...; }`
  (or `expectedError`). Run with [`nix-unit`](https://github.com/nix-community/nix-unit).
- **Namaka snapshot tests** — `namaka.toml` projects and `tests/**/expr.nix`
  files. Run with [`namaka`](https://github.com/nix-community/namaka).
- **Nixpkgs checkouts** — `pkgs/by-name` `passthru.tests`, `lib/tests`
  eval and build tests, and `nixos/tests` VM tests. Run with legacy commands
  (`nix-build`/`nix-instantiate`) that evaluate the working tree in place.

## Demo

![neotest-nix running flake checks and nix-unit tests from Neovim](./assets/demo.gif)

<!-- Regenerate with: nix run nixpkgs#vhs -- demo.tape -->

## Features

- Discovers flake `checks` and `nix-unit` suites straight from tree-sitter, so
  the test tree appears without evaluating the flake.
- Runs the right tool per test — `nix build`/`nix flake check` for checks,
  `nix-unit` for unit suites, and legacy `nix-build`/`nix-instantiate` for
  Nixpkgs checkout tests.
- Streams command output live and reports pass/fail per position.
- Turns Nix evaluation/build errors into diagnostics at the originating source
  line, translating `/nix/store/...-source` paths back to your worktree.
- Attributes NixOS VM test failures to the line in the failing `testScript`.
- Optionally evaluates the flake to surface generated checks that are not
  visible in the source (off by default).

## Requirements

- Neovim >= 0.11
- [Nix](https://nixos.org/) on `PATH`. The adapter passes
  `--extra-experimental-features` for its own `nix` calls, so these features do
  not need to be enabled globally in your Nix config.
- [`nix-unit`](https://github.com/nix-community/nix-unit) on `PATH` (only for
  nix-unit tests)
- [`namaka`](https://github.com/nix-community/namaka) on `PATH` (only for
  Namaka snapshot tests)
- Plugin dependencies: [`neotest`](https://github.com/nvim-neotest/neotest)
  and [`nvim-nio`](https://github.com/nvim-neotest/nvim-nio)
- The `nix` tree-sitter grammar on your runtimepath (a `parser/nix.so`).
  Positions are parsed through Neovim's built-in `vim.treesitter`, so any
  source of the grammar works — `nvim-treesitter`, a manually built parser, or
  the `parser_runtime_paths` option below

Run `:checkhealth neotest-nix` to verify the requirements above are met.

## Installation

### lazy.nvim

```lua
{
  "nvim-neotest/neotest",
  dependencies = {
    "nvim-neotest/nvim-nio",
    -- Only needed to install the `nix` grammar; the adapter itself uses
    -- Neovim's built-in vim.treesitter. Any grammar source works.
    "nvim-treesitter/nvim-treesitter",
    "khaneliman/neotest-nix",
  },
  opts = function()
    return {
      adapters = {
        require("neotest-nix"),
      },
    }
  end,
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

The packaged plugin pulls in `neotest`, `nvim-nio`, and a grammar-only plugin
built straight from the upstream `tree-sitter-nix` grammar (no `nvim-treesitter`
dependency) as runtime dependencies.

## Usage

The adapter discovers tests like these straight from the source:

```nix
{
  outputs =
    { self, nixpkgs }:
    {
      # A flake check — run with `nix build`.
      checks.x86_64-linux.hello =
        nixpkgs.legacyPackages.x86_64-linux.runCommand "hello" { } "touch $out";

      # nix-unit assertions — run with `nix-unit`.
      tests = {
        testAddition = {
          expr = 1 + 1;
          expected = 2;
        };
      };
    };
}
```

Open a `flake.nix`, recognized non-flake `*.nix` test file, or Namaka
project/file and use the standard Neotest commands:

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

  -- Map function/`let`-wrapped nix-unit files (not evaluable standalone) to the
  -- flake installable that exposes them, run with `nix-unit --flake <flake>`.
  -- The output is auto-detected by evaluating the flake, so this is usually
  -- unnecessary; set it only to override detection. `path` may be absolute or
  -- relative to the flake root and matches the file or any directory above it.
  -- nix_unit_flakes = { { path = "lib/tests", flake = ".#tests" } },
  nix_unit_flakes = nil,

  -- Auto-detect Nixpkgs checkouts and expose pkgs/by-name passthru.tests,
  -- lib/tests, and nixos/tests through legacy commands. Set true to force or
  -- false to disable.
  nixpkgs_mode = nil,

  -- If a by-name package has computed passthru.tests and no static names,
  -- evaluate the package lazily to enumerate individual test attrs.
  discover_nixpkgs_eval_tests = false,

  -- Enable first-class roots for recognized non-flake files. Set false to
  -- restore flake-only behavior outside Nixpkgs.
  non_flake_roots = true,

  -- Override external executables and extra args.
  nix_bin = "nix",
  nix_unit_bin = "nix-unit",
  namaka_bin = "namaka",
  nix_extra_args = nil,
  nix_unit_extra_args = nil,
  namaka_extra_args = nil,
})
```

| Option | Type | Default | Description |
| ------------------------------- | -------------------------- | -------------------- | ------------------------------------------------------------------------ |
| `parser_runtime_paths` | `string[]?` | `nil` | Extra runtimepath roots containing `parser/nix.so`. |
| `discover_eval_checks` | `boolean?` | `false` | Evaluate the flake to discover outputs not present in the source. |
| `eval_outputs` | `neotest-nix.EvalOutput[]?` | `{ { attr = "checks" } }` | Outputs to enumerate per system when `discover_eval_checks` is on. |
| `nix_unit_flakes` | `neotest-nix.NixUnitFlake[]?` | `nil` | Map wrapped nix-unit files to a flake installable, overriding auto-detection. |
| `nixpkgs_mode` | `boolean?` | `nil` | Auto-detect, force, or disable Nixpkgs-style legacy discovery. |
| `discover_nixpkgs_eval_tests` | `boolean?` | `false` | Lazily evaluate computed by-name `passthru.tests` when static parsing finds none. |
| `non_flake_roots` | `boolean?` | `true` | Enable recognized non-flake roots; set false for flake-only behavior. |
| `nix_bin` | `string?` | `"nix"` | Executable for nix CLI invocations. |
| `nix_unit_bin` | `string?` | `"nix-unit"` | Executable for nix-unit invocations. |
| `namaka_bin` | `string?` | `"namaka"` | Executable for Namaka invocations. |
| `nix_extra_args` | `string[]?` | `nil` | Extra args for nix-family commands. |
| `nix_unit_extra_args` | `string[]?` | `nil` | Extra args for nix-unit commands. |
| `namaka_extra_args` | `string[]?` | `nil` | Extra global args before Namaka's command. |

## How discovery works

- `flake.nix` is treated as a test file outside Nixpkgs checkouts.
- Any other `*.nix` file is considered a test file only when its name **or its
  immediate parent directory** contains `test` **and** it contains a nix-unit
  assertion (`expr` plus `expected` or `expectedError`). This covers both
  `foo_test.nix` and the common `tests/default.nix` layout. A `lib.nix` holding
  nix-unit tests outside a `test`-named file or directory is not discovered.
- Namaka projects expose `namaka.toml` and `tests/**/expr.nix` under the
  Namaka root. `_snapshots` directories are skipped. Namaka runs at file/project
  granularity; individual snapshot cases are not parsed.
- nix-unit assertions are surfaced as individual positions when their value has
  nix-unit shape (`expr` plus `expected` or `expectedError`). Attribute names do
  not need a `test` prefix; `addition` and `testAddition` both appear.
- Positions are parsed from source with tree-sitter. When
  `discover_eval_checks` is enabled, flake outputs are additionally enumerated
  via `nix eval` and merged into the tree, so checks generated at evaluation
  time still show up.
- Nixpkgs mode is auto-detected for trees shaped like Nixpkgs (`pkgs/by-name`,
  `lib`, and `nixos` or `pkgs/top-level/all-packages.nix`). Set
  `nixpkgs_mode = true` to force legacy discovery in a fork, or `false` to keep
  plain flake behavior.
- In Nixpkgs mode, `pkgs/by-name/<shard>/<name>/package.nix` exposes static
  `passthru.tests` entries as child nodes and runs them with
  `nix-build -A <name>.tests.<test>`. Computed test sets stay as a file node
  unless `discover_nixpkgs_eval_tests` is enabled; that eval is lazy and cached.
- `lib/tests` and `nixos/tests` files in a Nixpkgs checkout run through legacy
  commands so they evaluate the working tree in place.

## Limitations

- Raw non-flake NixOS VM test files are not supported. Standalone
  `testers.runNixOSTest` discovery applies to flake outputs and runs
  `nix build .#<attr>`.
- nix-unit runners evaluate the flake with `builtins.getFlake`, which sees only
  git-tracked files. A brand-new, untracked `flake.nix` or test file is
  invisible until it is staged or committed.
- Running a nix-unit suite (a `tests`-style namespace, or a function/`let`-wrapped
  file) runs the whole suite via `nix-unit --flake`, since it has no
  single-attribute filter — every attribute in that output reports a result.
- Running a whole `flake.nix` that mixes checks and nix-unit tests runs
  `nix flake check`, which does not execute nix-unit suites. Run the nix-unit
  namespace (or an individual test) to exercise them.
- Whole-suite runs use `nix-unit --flake`, which evaluates in pure mode and so
  needs a committed `flake.lock` with every input locked; otherwise the run
  fails with `cannot update unlocked flake input`. Individual tests run via
  `--expr` and are unaffected.
- Nixpkgs checkout discovery intentionally prunes most of `pkgs/`, `lib/`, and
  `nixos/` outside supported test subtrees to keep the Neotest tree responsive.

## Troubleshooting

Run `:checkhealth neotest-nix` first; it checks the parser and external tools.

For discovery or run-spec debugging, enable the adapter log before loading
Neotest:

```lua
vim.g.neotest_nix_debug = true
```

Or from the shell:

```sh
NEOTEST_NIX_DEBUG=1 nvim
```

The log is written to:

```lua
vim.fn.stdpath("log") .. "/neotest-nix.log"
```

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

## Acknowledgements

- [mrcjkb/neotest-haskell](https://github.com/mrcjkb/neotest-haskell) — used as
  a reference for the overall Neotest adapter shape, module boundaries, and
  integration patterns.
- [nvim-neotest/neotest](https://github.com/nvim-neotest/neotest) — the test
  framework this adapter plugs into.

## License

[MIT](./LICENSE) © Austin Horstman
