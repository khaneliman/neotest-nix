local M = {}

local uv = vim.uv

---@param path string
---@return boolean
local function exists(path)
  return uv.fs_stat(path) ~= nil
end

---@param root string
---@param relative_path string
---@return string
local function local_path(root, relative_path)
  return vim.fs.normalize(vim.fs.joinpath(root, relative_path))
end

---@param store_path string
---@return string?
local function source_relative_path(store_path)
  return store_path:match("^/nix/store/[^/]+%-source/(.+)$")
end

---@param path string
---@param root string
---@return string
function M.translate_store_path(path, root)
  local relative_path = source_relative_path(path)
  if relative_path == nil then
    return path
  end

  local translated = local_path(root, relative_path)
  if exists(translated) then
    return translated
  end

  return path
end

---@param value string
---@return string unwrapped
---@return string prefix
---@return string suffix
local function strip_store_path_wrappers(value)
  local prefix = value:match("^[%(\"'`]+")
  local suffix = value:match("[%)%]}\"'`.,;:]+$")
  local unwrapped = value

  if prefix ~= nil then
    unwrapped = unwrapped:sub(#prefix + 1)
  end
  if suffix ~= nil then
    unwrapped = unwrapped:sub(1, #unwrapped - #suffix)
  end

  return unwrapped, prefix or "", suffix or ""
end

---@param value string
---@param root string
---@return string
function M.translate_string(value, root)
  local translated = value:gsub("/nix/store/[^%s:]+%-source/[^%s:]+", function(store_path)
    local unwrapped_path, prefix, suffix = strip_store_path_wrappers(store_path)
    local translated_path = M.translate_store_path(unwrapped_path, root)
    if translated_path == unwrapped_path then
      return prefix .. unwrapped_path .. suffix
    end

    return prefix .. translated_path .. suffix
  end)
  return translated
end

---@param value any
---@param root string
---@return any
function M.translate_result_paths(value, root)
  if type(value) == "string" then
    return M.translate_string(value, root)
  end

  if type(value) ~= "table" then
    return value
  end

  for key, child in pairs(value) do
    value[key] = M.translate_result_paths(child, root)
  end

  return value
end

return M
