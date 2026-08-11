local M = {}
local uv = vim.uv

---@type table<string, { fingerprint: string, content: string }>
local source_cache = {}

---@param stat table?
---@return string
function M.fingerprint(stat)
  local mtime = stat and stat.mtime or nil
  return ("%d:%d:%d"):format(
    mtime and mtime.sec or 0,
    mtime and mtime.nsec or 0,
    stat and stat.size or 0
  )
end

---@param file_path string
---@return string?
function M.read_source(file_path)
  local stat = uv.fs_stat(file_path)
  if stat == nil or stat.type ~= "file" then
    return nil
  end

  local fingerprint = M.fingerprint(stat)
  local cached = source_cache[file_path]
  if cached ~= nil and cached.fingerprint == fingerprint then
    return cached.content
  end

  local file = io.open(file_path, "r")
  if file == nil then
    return nil
  end
  local content = file:read("*a")
  file:close()
  if content == nil then
    return nil
  end

  source_cache[file_path] = { fingerprint = fingerprint, content = content }
  return content
end

function M.clear_source_cache()
  source_cache = {}
end

return M
