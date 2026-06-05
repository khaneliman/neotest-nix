local discover = require("neotest-nix.discover")
local process = require("neotest-nix.process")
local results = require("neotest-nix.results")

local M = {}

local uv = vim.uv or vim.loop

-- Matches a Nix system tuple (e.g. "x86_64-linux") as an attribute name.
-- Shared with the position parser so discovery and run-spec agree on what
-- counts as a per-system namespace. The tree-sitter query keeps its own copy
-- because query predicates cannot reference Lua values.
M.system_pattern = "^[a-z0-9_]+%-[a-z0-9_]+$"

---@class neotest-nix.Position : neotest.Position
---@field attr_path? string
---@field runner? "nix"|"nix-unit"
---@field nix_unit_kind? "flake"|"import"
---@field test_script_range? integer[]

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

---@param tree neotest.Tree
---@return string?
local function check_attr(tree)
  local position = tree:data()
  ---@cast position neotest-nix.Position
  if position.attr_path ~= nil then
    return position.attr_path
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
    return ("checks.%s"):format(system)
  end

  return ("checks.%s.%s"):format(system, test)
end

---@param value string
---@return string
local function nix_string(value)
  return vim.json.encode(value)
end

---@param attr string
---@param kind "flake"|"import"
---@param path string
---@return string
local function nix_unit_expr(attr, kind, path)
  local name = attr:match("([^.]+)$") or "test"
  local root = kind == "import"
      and ("(import (builtins.path { path = %s; }))"):format(nix_string(path))
    or "(builtins.getFlake (toString ./. ))"
  return ("{ %s = %s.%s; }"):format(name, root, attr)
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
  local path = vim.json.encode(vim.split(output, ".", { plain = true }))
  local name = vim.json.encode(leaf)
  return ([[
let
  flake = builtins.getFlake (toString ./. );
  root = builtins.foldl' (acc: seg: acc.${seg}) flake (builtins.fromJSON ''%s'');
  name = builtins.fromJSON ''%s'';
  find = set:
    builtins.concatMap (n:
      let r = builtins.tryEval (set.${n}); in
      if !r.success then []
      else let v = r.value; in
        if builtins.isAttrs v then
          (if n == name && builtins.hasAttr "expr" v then [ v ]
           else if builtins.hasAttr "expr" v then []
           else find v)
        else []) (builtins.attrNames set);
  matches = find root;
in
  if matches == [ ] then throw "neotest-nix: no nix-unit test named ${name}"
  else { ${name} = builtins.head matches; }
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
  if position.type == "namespace" and position.name:match(M.system_pattern) ~= nil then
    return nil
  end

  local cwd = cwd_for(position.path)
  local attr = check_attr(tree)
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
    table.insert(command, nix_unit_expr(attr, position.nix_unit_kind, position.path))
  else
    command = {
      "nix",
      "build",
    }
    vim.list_extend(command, nix_features)
    table.insert(command, "--keep-going")
    -- Do not lock the flake on disk just to run tests.
    table.insert(command, "--no-write-lock-file")
    table.insert(command, ".#" .. attr)
  end

  local run_spec = {
    command = with_extra_args(command, args.extra_args),
    cwd = cwd,
    strategy = process.strategy,
    context = {
      attr = context_attr,
      path = position.path,
      pos_id = position.id,
      runner = runner,
      type = position.type,
    },
  }
  -- nix-unit reports per-attribute results that the final pass parses in full;
  -- the streaming nix-error scanner only applies to plain `nix` runs.
  if runner ~= "nix-unit" then
    run_spec.stream = results.stream(run_spec, tree)
  end

  return run_spec
end

return M
