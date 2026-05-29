local M = {}

local parser_runtimepath_roots = {}

---@param runtime_file string
---@return string?
local function runtime_root(runtime_file)
  local parser_dir = vim.fs.dirname(runtime_file)
  if parser_dir == nil then
    return nil
  end

  return vim.fs.dirname(parser_dir)
end

---@param roots string[]
local function prepend_runtime_roots(roots)
  local current = vim.opt.runtimepath:get()
  local seen = {}

  for _, path in ipairs(current) do
    seen[vim.fs.normalize(path)] = true
  end

  for i = #roots, 1, -1 do
    local root = vim.fs.normalize(roots[i])
    if not seen[root] then
      vim.opt.runtimepath:prepend(root)
      seen[root] = true
    end
  end
end

---@param roots string[]
local function add_subprocess_runtime_roots(roots)
  local ok, subprocess = pcall(function()
    local lib = require("neotest.lib")
    local subprocess = lib.subprocess
    if subprocess == nil or subprocess.enabled == nil or not subprocess.enabled() then
      return nil
    end

    return subprocess
  end)

  if not ok or subprocess == nil then
    return
  end

  pcall(subprocess.add_paths_to_rtp, roots)
end

---@param extra_roots string[]?
function M.ensure_nix_parser(extra_roots)
  local roots = {}

  if extra_roots ~= nil then
    vim.list_extend(roots, extra_roots)
  end

  if #parser_runtimepath_roots == 0 then
    for _, parser in ipairs(vim.api.nvim_get_runtime_file("parser/nix.so", true)) do
      local root = runtime_root(parser)
      if root ~= nil then
        table.insert(parser_runtimepath_roots, root)
      end
    end
  end

  vim.list_extend(roots, parser_runtimepath_roots)
  prepend_runtime_roots(roots)
  add_subprocess_runtime_roots(roots)
end

return M
