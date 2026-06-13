local discover = require("neotest-nix.discover")

local M = {}

---@param root string
---@return string
local function compact_root(root)
  local parts = {}
  local normalized = vim.fs.normalize(root)

  for part in normalized:gmatch("[^/\\]+") do
    parts[#parts + 1] = part
  end

  local basename = parts[#parts]
  local parent = parts[#parts - 1]
  if basename ~= nil and parent ~= nil then
    return parent .. "/" .. basename
  end

  return basename or normalized
end

---Add root context to file labels shown by Neotest summary.
---Neotest already keeps IDs and paths separately; only `name` is display text.
---@param tree neotest.Tree
---@param file_path string
---@return neotest.Tree
function M.label_tree(tree, file_path)
  if vim.fs.basename(file_path) ~= "flake.nix" then
    return tree
  end

  if type(tree) ~= "table" or type(tree.data) ~= "function" then
    return tree
  end

  local position = tree:data()
  if type(position) ~= "table" or position.type ~= "file" then
    return tree
  end

  local root = discover.root(file_path)
  if root == nil then
    return tree
  end

  position.name = ("flake.nix (%s)"):format(compact_root(root))
  return tree
end

return M
