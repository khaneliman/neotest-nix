local M = {}

local uv = vim.uv
local COMPARE_CHUNK_SIZE = 64 * 1024

---@param file file*
---@return string?
---@return boolean ok
local function read_chunk(file)
  local ok, chunk, err = pcall(file.read, file, COMPARE_CHUNK_SIZE)
  return ok and err == nil and chunk or nil, ok and err == nil
end

---@param left_path string
---@param right_path string
---@return boolean
local function same_regular_file_contents(left_path, right_path)
  local left_stat = uv.fs_lstat(left_path)
  local right_stat = uv.fs_lstat(right_path)
  if
    left_stat == nil
    or right_stat == nil
    or left_stat.type ~= "file"
    or right_stat.type ~= "file"
    or left_stat.size ~= right_stat.size
  then
    return false
  end

  local left = io.open(left_path, "rb")
  if left == nil then
    return false
  end

  local right = io.open(right_path, "rb")
  if right == nil then
    left:close()
    return false
  end

  local equal = true
  while true do
    local left_chunk, left_ok = read_chunk(left)
    local right_chunk, right_ok = read_chunk(right)
    if not left_ok or not right_ok or left_chunk ~= right_chunk then
      equal = false
      break
    end
    if left_chunk == nil then
      break
    end
  end

  left:close()
  right:close()
  return equal
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
  return store_path:match("^/nix/store/[^/]+/(.+)$")
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
  if same_regular_file_contents(path, translated) then
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
  local quoted_location = unwrapped:match("([\"']:%d+:%d+)$")
  if quoted_location ~= nil then
    unwrapped = unwrapped:sub(1, #unwrapped - #quoted_location)
    suffix = quoted_location .. (suffix or "")
  else
    local location = unwrapped:match("(:%d+:%d+)$")
    if location ~= nil then
      unwrapped = unwrapped:sub(1, #unwrapped - #location)
      suffix = location .. (suffix or "")
    end
  end

  return unwrapped, prefix or "", suffix or ""
end

---@param value string
---@param root string
---@return string
function M.translate_string(value, root)
  local translated = value:gsub("/nix/store/[^%s]+", function(store_path)
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
