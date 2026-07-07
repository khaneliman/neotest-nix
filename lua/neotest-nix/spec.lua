local discover = require("neotest-nix.discover")
local eval = require("neotest-nix.eval")
local process = require("neotest-nix.process")
local results = require("neotest-nix.results")

local M = {}

local uv = vim.uv

-- Matches a Nix system tuple (e.g. "x86_64-linux") as an attribute name.
-- Shared with the position parser so discovery and run-spec agree on what
-- counts as a per-system namespace. The tree-sitter query keeps its own copy
-- because query predicates cannot reference Lua values.
M.system_pattern = "^[a-z0-9_]+%-[a-z0-9_]+$"

---@class neotest-nix.Position : neotest.Position
---@field attr_path? string
---@field attr_path_parts? string[]
---@field runner? "nix"|"nix-unit"
---@field nix_unit_kind? "flake"|"import"
---@field test_script_range? integer[]
---@field nixpkgs_attr? string Legacy `nix-build -A` attribute for a Nixpkgs test.
---@field nixpkgs_file_build? string Root-relative file built with `nix-build <file>`.
---@field nixpkgs_file_eval? string Root-relative file run with `nix-instantiate --eval`.
---@field nixpkgs_eval_test? string Single `lib.runTests` test name selected from a Nixpkgs eval file.
---@field dynamic_system? boolean True when `attr_path` carries a literal `<system>`
---placeholder resolved to the current system at run time.

local nix_features = {
  "--extra-experimental-features",
  "nix-command flakes",
}

local nix_unit_features = {
  "--extra-experimental-features",
  "flakes",
}

---@param command string[]
---@param extra_args string[]?
---@return string[]
local function with_extra_args(command, extra_args)
  local result = vim.deepcopy(command)
  if extra_args ~= nil then
    vim.list_extend(result, extra_args)
  end
  return result
end

---@param tree neotest.Tree
---@return neotest.Position[]
local function position_path(tree)
  local positions = {}
  ---@type neotest.Tree?
  local current = tree

  while current ~= nil do
    table.insert(positions, 1, current:data())
    current = current:parent()
  end

  return positions
end

---@type fun(tree: neotest.Tree): string[]?
local check_attr_parts

---@param tree neotest.Tree
---@return string[]?
function check_attr_parts(tree)
  local position = tree:data()
  ---@cast position neotest-nix.Position
  if position.attr_path_parts ~= nil then
    return vim.deepcopy(position.attr_path_parts)
  end

  if position.attr_path ~= nil then
    return vim.split(position.attr_path, ".", { plain = true })
  end

  local system
  local test

  for _, ancestor in ipairs(position_path(tree)) do
    if ancestor.type == "namespace" and ancestor.name:match(M.system_pattern) then
      system = ancestor.name
    elseif ancestor.type == "test" then
      test = ancestor.name
    end
  end

  if system == nil then
    return nil
  end

  if test == nil then
    return { "checks", system }
  end

  return { "checks", system, test }
end

---@param value string
---@return string
local function nix_string(value)
  return eval.nix_string_literal(value)
end

-- A bare Nix identifier: safe to splice into an expression unquoted.
local nix_identifier_pattern = "^[%a_][%w_'%-]*$"

---Attribute segment for splicing into a Nix select path: bare identifiers stay
---bare, anything else uses `${"..."}` string-key access.
---@param segment string
---@return string
local function nix_attr_segment(segment)
  if segment:match(nix_identifier_pattern) ~= nil then
    return segment
  end
  return ("${%s}"):format(nix_string(segment))
end

---Attribute segment inside a flake installable (`.#checks."x y"`).
---@param segment string
---@return string
local function installable_attr_segment(segment)
  if segment:match(nix_identifier_pattern) ~= nil then
    return segment
  end
  return nix_string(segment)
end

---@param segments string[]
---@param render_segment fun(segment: string): string
---@return string
local function render_attr_path(segments, render_segment)
  local rendered = {}
  for index, segment in ipairs(segments) do
    rendered[index] = render_segment(segment)
  end
  return table.concat(rendered, ".")
end

---@param attr string
---@param attr_parts string[]?
---@param kind "flake"|"import"
---@param path string
---@return string
local function nix_unit_expr(attr, attr_parts, kind, path)
  local segments = attr_parts or vim.split(attr, ".", { plain = true })
  local name = segments[#segments] or "test"
  local root = kind == "import"
      and ("(import (builtins.path { path = %s; }))"):format(nix_string(path))
    or "(builtins.getFlake (toString ./. ))"
  local key = name:match(nix_identifier_pattern) ~= nil and name or nix_string(name)
  return ("{ %s = %s.%s; }"):format(key, root, render_attr_path(segments, nix_attr_segment))
end

---Expression that runs a single test out of a wrapped flake suite. The suite's
---runtime path (e.g. `tests.systems.<system>.system-agnostic.<name>`) differs
---from the source position, so the leaf is located by name within the output
---rather than indexed directly.
---@param flake string installable such as ".#tests"
---@param leaf string test attribute name
---@return string
local function nix_unit_select_expr(flake, leaf)
  local output = flake:gsub("^%.#", "")
  local path = eval.nix_string_literal(vim.json.encode(vim.split(output, ".", { plain = true })))
  local name = eval.nix_string_literal(vim.json.encode(leaf))
  return ([[
let
  flake = builtins.getFlake (toString ./. );
  root = builtins.foldl' (acc: seg: acc.${seg}) flake (builtins.fromJSON %s);
  name = builtins.fromJSON %s;
  pathName = path: builtins.concatStringsSep "." path;
  find = path: set:
    builtins.concatMap (
      n:
      let
        valuePath = path ++ [ n ];
        r = builtins.tryEval (set.${n});
      in
      if !r.success then
        [ ]
      else if builtins.isAttrs r.value && builtins.hasAttr "expr" r.value then
        (if n == name then [ { name = pathName valuePath; value = r.value; } ] else [ ])
      else if builtins.isAttrs r.value then
        find valuePath r.value
      else
        [ ]
    ) (builtins.attrNames set);
  matches = find [ ] root;
in
if matches == [ ] then
  throw "neotest-nix: no nix-unit test named ${name}"
else
  builtins.listToAttrs matches
]]):format(path, name)
end

---Find the configured flake installable for a nix-unit file that cannot be
---evaluated standalone (function/let-wrapped). Config paths may be absolute or
---relative to the flake root, and match the file itself or any directory
---containing it.
---@param opts neotest-nix.Config
---@param file_path string
---@param root string
---@return neotest-nix.NixUnitFlake?
local function matching_flake(opts, file_path, root)
  local flakes = opts and opts.nix_unit_flakes
  if flakes == nil then
    return nil
  end

  local target = vim.fs.normalize(file_path)
  for _, entry in ipairs(flakes) do
    local base = entry.path
    if base:sub(1, 1) ~= "/" then
      base = vim.fs.joinpath(root, base)
    end
    base = vim.fs.normalize(base)
    if target == base or target:sub(1, #base + 1) == base .. "/" then
      return entry
    end
  end

  return nil
end

---Run nix-unit directly against a flake installable. Unlike building the
---wrapping check, this prints per-attribute results to stdout so individual
---test attributes can pass or fail independently.
---@param flake string
---@return string[]
local function nix_unit_flake_command(flake)
  local command = { "nix-unit" }
  vim.list_extend(command, nix_unit_features)
  table.insert(command, "--flake")
  table.insert(command, flake)
  return command
end

---Collect the nix-unit test attribute names reachable from a run tree. Used to
---auto-detect the flake output that exposes a wrapped suite.
---@param tree neotest.Tree
---@return string[]
local function suite_test_names(tree)
  local names = {}
  local seen = {}

  local function add(position)
    if position.type == "test" and position.name ~= nil and not seen[position.name] then
      seen[position.name] = true
      table.insert(names, position.name)
    end
  end

  add(tree:data())
  if type(tree.iter) == "function" then
    for _, position in tree:iter() do
      add(position)
    end
  end

  return names
end

---Resolve the flake installable for a wrapped nix-unit suite: an explicit
---`nix_unit_flakes` mapping wins, otherwise fall back to evaluating the flake
---to auto-detect the matching output.
---@param opts neotest-nix.Config
---@param position neotest-nix.Position
---@param tree neotest.Tree
---@param root string
---@return string?
local function resolve_flake(opts, position, tree, root)
  local configured = matching_flake(opts, position.path, root)
  if configured ~= nil then
    return configured.flake
  end

  return require("neotest-nix.eval").detect_nix_unit_flake(root, suite_test_names(tree))
end

---@param path string
local function warn_unresolved_flake(path)
  vim.notify(
    (
      "neotest-nix: could not resolve a flake output for the nix-unit tests in %s; "
      .. "expose them as a flake output, or map it with the `nix_unit_flakes` "
      .. "option (e.g. { path = ..., flake = '.#tests' })"
    ):format(path),
    vim.log.levels.WARN
  )
end

---Whether a file position holds a nix-unit suite that is only reachable through
---the flake (every nix-unit test is function/let-wrapped). flake.nix and
---files with standalone-runnable tests are excluded.
---@param tree neotest.Tree
---@param file_path string
---@return boolean
local function wrapped_nix_unit_file(tree, file_path)
  if vim.fs.basename(file_path) == "flake.nix" or type(tree.iter) ~= "function" then
    return false
  end

  local has_nix_unit = false
  for _, position in tree:iter() do
    ---@cast position neotest-nix.Position
    if position.type == "test" and position.runner == "nix-unit" then
      if position.nix_unit_kind ~= nil then
        return false
      end
      has_nix_unit = true
    end
  end

  return has_nix_unit
end

---The flake installable for a namespace whose subtree is entirely flake-level
---nix-unit tests sharing one output (e.g. the `tests` namespace -> ".#tests").
---Returns nil for mixed or non-nix-unit subtrees, which fall back to a broad
---`nix flake check`.
---@param tree neotest.Tree
---@return string?
local function namespace_nix_unit_flake(tree)
  if type(tree.iter) ~= "function" then
    return nil
  end

  local output
  local count = 0
  for _, position in tree:iter() do
    ---@cast position neotest-nix.Position
    if position.type == "test" then
      if position.runner ~= "nix-unit" or position.nix_unit_kind ~= "flake" then
        return nil
      end
      local segment = position.attr_path ~= nil and position.attr_path:match("^([^.]+)") or nil
      if segment == nil then
        return nil
      end
      if output == nil then
        output = segment
      elseif output ~= segment then
        return nil
      end
      count = count + 1
    end
  end

  if count == 0 then
    return nil
  end

  return ".#" .. output
end

---@param path string
---@return string
local function cwd_for(path)
  return discover.root(path) or uv.cwd() or "."
end

---This adapter's custom streaming strategy should only back a run's *default*
---strategy, not silently replace one a caller names explicitly. Neotest fills
---`args.strategy` with the project's `default_strategy` (`"integrated"` unless
---configured otherwise) *before* `build_spec` ever runs
---(`neotest.client.runner.TestRunner:run_tree`), so plain `nil` never reaches
---here for an ordinary run; treat it the same as the `"integrated"` default.
---For any other value (e.g. `"dap"`, set via
---`require("neotest").run.run({ strategy = "dap" })`) this must return nil:
---`neotest.client.runner.TestRunner:_run_spec` treats a function `spec.strategy`
---as a hard override and keeps it over `args.strategy` unconditionally
---(`vim.tbl_extend("keep", { strategy = spec.strategy }, args)`), so attaching it
---unconditionally would make every named strategy a no-op.
---@param args_strategy string|table|neotest.Strategy|nil
---@return neotest.Strategy?
local function run_strategy(args_strategy)
  if args_strategy == nil or args_strategy == "integrated" then
    return process.strategy
  end
  return nil
end

-- POSIX single-quote escaping: close the quote, emit an escaped literal quote,
-- reopen it. Safe for any byte string, including embedded newlines.
---@param value string
---@return string
local function shell_quote(value)
  return "'" .. value:gsub("'", "'\\''") .. "'"
end

---@param command string[]
---@return string
local function shell_join(command)
  local quoted = {}
  for index, part in ipairs(command) do
    quoted[index] = shell_quote(part)
  end
  return table.concat(quoted, " ")
end

---Two-step shell command for interactive NixOS VM debugging: build
---`build_command`'s `driverInteractive` derivation, then exec the resulting
---`bin/nixos-test-driver` so it inherits the terminal. Wrapped in `sh -c` since
---neotest's `RunSpec.command` is a single argv, not a pipeline; `&&` keeps a
---build failure's exit code and output (rather than execing into a missing
---path) instead of masking it.
---@param build_command string[] Command that builds the `.driverInteractive` attribute
---and prints its store path (e.g. `nix build --print-out-paths ...`).
---@return string[]
local function driver_interactive_command(build_command)
  local script = ('out=$(%s) && exec "$out/bin/nixos-test-driver"'):format(
    shell_join(build_command)
  )
  return { "sh", "-c", script }
end

---@param args neotest.RunArgs
---@param opts neotest-nix.Config?
---@return neotest.RunSpec?
function M.build_spec(args, opts)
  opts = opts or {}
  local tree = args and args.tree
  if tree == nil then
    return nil
  end

  local position = tree:data()
  ---@cast position neotest-nix.Position
  if position.type == "dir" then
    return nil
  end
  -- Source-parsed system namespaces are broken down into their child checks by
  -- neotest; eval-discovered ones carry an attr_path and build that directly.
  if
    position.type == "namespace"
    and position.attr_path == nil
    and position.name:match(M.system_pattern) ~= nil
  then
    return nil
  end

  local cwd = cwd_for(position.path)

  -- `test_script_range` marks a single VM-test check (a flake check or a
  -- nixpkgs `nixosTests.<name>` file whose `testScript` was found by source
  -- parse; see positions.lua / nixpkgs.lua). `build_spec` runs for exactly the
  -- given position, so this position carrying it *is* "the run position is a
  -- single VM-test check" -- no broader-run disambiguation is needed here
  -- (unlike results.lua's `vm_target`, which attributes tracebacks across runs
  -- that can cover several VM tests at once).
  local vm_interactive = opts.vm_interactive == true and position.test_script_range ~= nil

  -- Nixpkgs positions run with legacy commands (nix-build / nix-instantiate)
  -- that evaluate the working tree in place, no flake copy-to-store. The runner
  -- selects result parsing: "nix" parses like a flake build; "nix-eval" parses
  -- a lib.runTests failure list.
  local nixpkgs_target = position.nixpkgs_attr
    or position.nixpkgs_file_build
    or position.nixpkgs_file_eval
  if nixpkgs_target ~= nil then
    local nixpkgs = require("neotest-nix.nixpkgs")
    local command, runner = nixpkgs.build_command(position)
    -- Only a nixpkgs_attr target (nixosTests.<name>) can carry
    -- test_script_range; nixpkgs_file_build/eval positions never do.
    if vm_interactive and position.nixpkgs_attr ~= nil then
      command = driver_interactive_command({
        "nix-build",
        "-A",
        position.nixpkgs_attr .. ".driverInteractive",
        "--no-out-link",
      })
    end
    -- Not `vm_interactive and nil or run_strategy(...)`: with a nil middle
    -- term, `and`/`or` chaining falls through to the right-hand side, which
    -- would reattach the custom strategy exactly when it must be omitted.
    local strategy = not vm_interactive and run_strategy(args.strategy) or nil
    local run_spec = {
      command = vm_interactive and command or with_extra_args(command, args.extra_args),
      cwd = cwd,
      strategy = strategy,
      context = {
        attr = nixpkgs_target,
        path = position.path,
        pos_id = position.id,
        runner = runner,
        type = position.type,
      },
    }
    -- nix-eval output is a single value parsed at the end; only the streaming
    -- nix-error scanner applies to plain nix-build runs. The interactive
    -- driver session is a live REPL, not build output to scan for errors.
    if runner == "nix" and not vm_interactive then
      run_spec.stream = results.stream(run_spec, tree)
    end
    return run_spec
  end

  -- Generic `lib.runTests` file outside a Nixpkgs checkout: try its own
  -- eval command before the nix-unit paths below, which need `nix-unit` or a
  -- flake mapping that a plain runTests file may not have.
  local runtests = require("neotest-nix.runtests")
  if vim.fs.basename(position.path) ~= "flake.nix" and runtests.is_runtests_file(position.path) then
    local runtests_spec = runtests.build_spec(position, cwd, args.extra_args, opts, args.strategy)
    if runtests_spec ~= nil then
      return runtests_spec
    end
  end

  local attr_parts = check_attr_parts(tree)
  local attr = attr_parts ~= nil and table.concat(attr_parts, ".") or nil
  if
    attr_parts ~= nil
    and attr ~= nil
    and position.dynamic_system
    and attr:find("<system>", 1, true) ~= nil
  then
    -- Positions under a runtime-generated per-system attrset carry a literal
    -- `<system>` placeholder; substitute the current system at run time.
    local system = eval.current_system(cwd)
    if system == nil then
      vim.notify(
        ("neotest-nix: could not determine the current system to run %s"):format(attr),
        vim.log.levels.WARN
      )
      return nil
    end
    for index, segment in ipairs(attr_parts) do
      if segment == "<system>" then
        attr_parts[index] = system
      end
    end
    attr = table.concat(attr_parts, ".")
  end
  local command
  local context_attr = attr
  -- Set when the run delegates to `nix-unit --flake`, so results parse the
  -- whole suite's per-attribute output regardless of which node was run.
  local runner = position.runner or "nix"
  local namespace_flake = (attr == nil and position.type == "namespace")
      and namespace_nix_unit_flake(tree)
    or nil

  if position.runner == "nix-unit" and position.nix_unit_kind == nil then
    -- Function/let-wrapped nix-unit test: not evaluable standalone. Resolve the
    -- flake installable (explicit mapping, else auto-detect); otherwise warn.
    -- `nix-unit --flake` has no per-attribute filter, so a single test is run
    -- by selecting just its leaf out of the suite via `--expr`.
    local flake = resolve_flake(opts, position, tree, cwd)
    if flake == nil then
      warn_unresolved_flake(position.path)
      return nil
    end

    command = {
      "nix-unit",
    }
    vim.list_extend(command, nix_unit_features)
    table.insert(command, "--expr")
    table.insert(command, nix_unit_select_expr(flake, position.name))
    context_attr = flake
  elseif
    attr == nil
    and (
      matching_flake(opts, position.path, cwd) ~= nil or wrapped_nix_unit_file(tree, position.path)
    )
  then
    -- File holding a wrapped nix-unit suite: run the whole suite via its flake
    -- output so every attribute reports independently. An explicit mapping is
    -- honoured even when the tree can't be introspected for wrapped children.
    local flake = resolve_flake(opts, position, tree, cwd)
    if flake == nil then
      warn_unresolved_flake(position.path)
      return nil
    end

    command = nix_unit_flake_command(flake)
    context_attr = flake
    runner = "nix-unit"
  elseif namespace_flake ~= nil then
    command = nix_unit_flake_command(namespace_flake)
    context_attr = namespace_flake
    runner = "nix-unit"
  elseif attr == nil then
    command = {
      "nix",
      "flake",
      "check",
    }
    vim.list_extend(command, nix_features)
    table.insert(command, "--keep-going")
    -- Do not lock the flake on disk just to run tests.
    table.insert(command, "--no-write-lock-file")
  elseif position.runner == "nix-unit" then
    command = {
      "nix-unit",
    }
    vim.list_extend(command, nix_unit_features)
    table.insert(command, "--expr")
    table.insert(command, nix_unit_expr(attr, attr_parts, position.nix_unit_kind, position.path))
  elseif vm_interactive then
    ---@cast attr_parts string[]
    local build_command = { "nix", "build" }
    vim.list_extend(build_command, nix_features)
    vim.list_extend(build_command, { "--no-link", "--print-out-paths", "--no-write-lock-file" })
    table.insert(
      build_command,
      ".#" .. render_attr_path(attr_parts, installable_attr_segment) .. ".driverInteractive"
    )
    command = driver_interactive_command(build_command)
  else
    ---@cast attr_parts string[]
    command = {
      "nix",
      "build",
    }
    vim.list_extend(command, nix_features)
    table.insert(command, "--keep-going")
    -- Do not lock the flake on disk just to run tests.
    table.insert(command, "--no-write-lock-file")
    table.insert(command, ".#" .. render_attr_path(attr_parts, installable_attr_segment))
  end

  -- Not `vm_interactive and nil or run_strategy(...)`: with a nil middle term,
  -- `and`/`or` chaining falls through to the right-hand side, which would
  -- reattach the custom strategy exactly when it must be omitted.
  local strategy = not vm_interactive and run_strategy(args.strategy) or nil
  local run_spec = {
    command = vm_interactive and command or with_extra_args(command, args.extra_args),
    cwd = cwd,
    strategy = strategy,
    context = {
      attr = context_attr,
      path = position.path,
      pos_id = position.id,
      runner = runner,
      type = position.type,
    },
  }
  -- nix-unit reports per-attribute results that the final pass parses in full;
  -- the streaming nix-error scanner only applies to plain `nix` runs. The
  -- interactive driver session is a live REPL, not build output to scan.
  if runner ~= "nix-unit" and not vm_interactive then
    run_spec.stream = results.stream(run_spec, tree)
  end

  return run_spec
end

return M
