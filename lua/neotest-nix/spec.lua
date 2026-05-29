local discover = require("neotest-nix.discover")
local process = require("neotest-nix.process")
local results = require("neotest-nix.results")

local M = {}

local uv = vim.uv or vim.loop

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
    if ancestor.type == "namespace" and ancestor.name:match("^[a-z0-9_]+%-[a-z0-9_]+$") then
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

---@param path string
---@return string
local function cwd_for(path)
  return discover.root(path) or uv.cwd() or "."
end

---@param args neotest.RunArgs
---@return neotest.RunSpec?
function M.build_spec(args)
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

  if attr == nil then
    command = {
      "nix",
      "flake",
      "check",
    }
    vim.list_extend(command, nix_features)
    table.insert(command, "--keep-going")
  elseif position.runner == "nix-unit" then
    if position.nix_unit_kind == nil then
      vim.notify(
        ("neotest-nix: nix-unit tests in %s are not reachable from the flake root; run their wrapping check instead (e.g. nix build .#checks.<system>.<name>)"):format(
          position.path
        ),
        vim.log.levels.WARN
      )
      return nil
    end

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
      attr = attr,
      path = position.path,
      pos_id = position.id,
      runner = position.runner or "nix",
      type = position.type,
    },
  }
  run_spec.stream = results.stream(run_spec, tree)

  return run_spec
end

return M
