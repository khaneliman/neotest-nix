local M = {}

local uv = vim.uv

---@param path string
---@return boolean
local function is_file(path)
  local stat = uv.fs_stat(path)
  return stat ~= nil and stat.type == "file"
end

---@param file_path string
---@return string?
function M.root(file_path)
  local marker = vim.fs.find("namaka.toml", {
    path = file_path,
    upward = true,
    type = "file",
  })[1]

  return marker ~= nil and vim.fs.dirname(marker) or nil
end

---@param opts neotest-nix.Config?
---@return string
function M.bin(opts)
  return (opts and opts.namaka_bin) or "namaka"
end

---@param command string[]
---@param opts neotest-nix.Config?
function M.append_extra_args(command, opts)
  if opts and opts.namaka_extra_args ~= nil then
    vim.list_extend(command, opts.namaka_extra_args)
  end
end

---@param file_path string
---@param root string?
---@return boolean
function M.is_test_file(file_path, root)
  local basename = vim.fs.basename(file_path)
  if basename == "namaka.toml" then
    return is_file(file_path)
  end

  if basename ~= "expr.nix" then
    return false
  end

  root = root or M.root(file_path)
  if root == nil then
    return false
  end

  local normalized = vim.fs.normalize(file_path)
  local prefix = vim.fs.normalize(root) .. "/"
  if normalized:sub(1, #prefix) ~= prefix then
    return false
  end

  return normalized:find("/_snapshots/", 1, true) == nil
end

---@param file_path string
---@param root string
---@return neotest.Tree
function M.discover_positions(file_path, root)
  local Tree = require("neotest.types").Tree
  local name = vim.fs.basename(file_path)
  return Tree.from_list({
    {
      id = file_path,
      name = name,
      path = file_path,
      range = { 0, 0, 0, 0 },
      runner = "namaka",
      type = "file",
      namaka_root = root,
    },
  }, function(position)
    return position.id
  end)
end

return M
