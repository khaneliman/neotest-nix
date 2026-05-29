local discover = require("neotest-nix.discover")

local M = {}

local nix_features = {
  "--extra-experimental-features",
  "nix-command flakes",
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
  local system
  local test

  for _, position in ipairs(position_path(tree)) do
    if position.type == "namespace" and position.name:match("^[a-z0-9_]+%-[a-z0-9_]+$") then
      system = position.name
    elseif position.type == "test" then
      test = position.name
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
      type = position.type,
    },
  }
end

return M
