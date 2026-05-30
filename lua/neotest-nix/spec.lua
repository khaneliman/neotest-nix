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

---@param attr string
---@param kind "flake"|"import"
---@param path string
---@return string
local function nix_unit_expr(attr, kind, path)
  local name = attr:match("([^.]+)$") or "test"
  local root = kind == "import" and ("(import %s)"):format(path)
    or "(builtins.getFlake (toString ./. ))"
  return ("{ %s = %s.%s; }"):format(name, root, attr)
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

  local cwd = cwd_for(position.path)
  local attr = check_attr(tree)
  local command
  local context_attr = attr
  -- Set when the run delegates to `nix-unit --flake`, so results parse the
  -- whole suite's per-attribute output regardless of which node was run.
  local runner = position.runner or "nix"

  if position.runner == "nix-unit" and position.nix_unit_kind == nil then
    -- Function/let-wrapped nix-unit suite: not evaluable standalone. Run it via
    -- the configured flake installable when mapped; otherwise warn.
    local flake = matching_flake(opts, position.path, cwd)
    if flake == nil then
      vim.notify(
        (
          "neotest-nix: nix-unit tests in %s are not reachable from the flake root; "
          .. "expose them as a flake output and map it with the `nix_unit_flakes` "
          .. "option (e.g. { path = ..., flake = '.#tests' })"
        ):format(position.path),
        vim.log.levels.WARN
      )
      return nil
    end

    command = nix_unit_flake_command(flake.flake)
    context_attr = flake.flake
  elseif attr == nil then
    -- File position. A mapped flake runs only this suite via nix-unit;
    -- otherwise fall back to a full `nix flake check`.
    local flake = matching_flake(opts, position.path, cwd)
    if flake ~= nil then
      command = nix_unit_flake_command(flake.flake)
      context_attr = flake.flake
      runner = "nix-unit"
    else
      command = {
        "nix",
        "flake",
        "check",
      }
      vim.list_extend(command, nix_features)
      table.insert(command, "--keep-going")
    end
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
