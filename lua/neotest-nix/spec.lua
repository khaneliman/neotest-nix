local discover = require("neotest-nix.discover")

local M = {}

---@class neotest-nix.Position : neotest.Position
---@field attr_path? string
---@field runner? "nix"|"nix-unit"

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
---@return string
local function nix_unit_expr(attr)
  local name = attr:match("([^.]+)$") or "test"
  return ("{ %s = (builtins.getFlake (toString ./. )).%s; }"):format(name, attr)
end

---@param path string
---@return string
local function cwd_for(path)
  return discover.root(path) or vim.loop.cwd() or "."
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
    command = {
      "nix-unit",
    }
    vim.list_extend(command, nix_unit_features)
    table.insert(command, "--expr")
    table.insert(command, nix_unit_expr(attr))
  else
    command = {
      "nix",
      "build",
    }
    vim.list_extend(command, nix_features)
    table.insert(command, "--keep-going")
    table.insert(command, ".#" .. attr)
  end

  return {
    command = with_extra_args(command, args.extra_args),
    cwd = cwd,
    context = {
      attr = attr,
      path = position.path,
      pos_id = position.id,
      runner = position.runner or "nix",
      type = position.type,
    },
  }
end

return M
