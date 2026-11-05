local M = {}
local uv = vim.uv

---@type table<string, { fingerprint: string, content: string }>
local source_cache = {}
local source_cache_head
local source_cache_tail
local source_cache_entries = 0
local source_cache_bytes = 0

local MAX_SOURCE_CACHE_ENTRIES = 32
local MAX_SOURCE_CACHE_BYTES = 2 * 1024 * 1024
-- Bounds transient reads and scanner work as well as each retained cache entry.
local MAX_SOURCE_BYTES = 512 * 1024

local function detach(entry)
  if entry.previous ~= nil then
    entry.previous.next = entry.next
  else
    source_cache_head = entry.next
  end
  if entry.next ~= nil then
    entry.next.previous = entry.previous
  else
    source_cache_tail = entry.previous
  end
end

local function prepend(entry)
  entry.previous = nil
  entry.next = source_cache_head
  if source_cache_head ~= nil then
    source_cache_head.previous = entry
  else
    source_cache_tail = entry
  end
  source_cache_head = entry
end

local function remove(entry)
  detach(entry)
  source_cache[entry.file_path] = nil
  source_cache_entries = source_cache_entries - 1
  source_cache_bytes = source_cache_bytes - #entry.content
end

local function promote(entry)
  if entry ~= source_cache_head then
    detach(entry)
    prepend(entry)
  end
end

local function evict_until_bounded()
  while
    source_cache_tail ~= nil
    and (
      source_cache_entries > MAX_SOURCE_CACHE_ENTRIES
      or source_cache_bytes > MAX_SOURCE_CACHE_BYTES
    )
  do
    remove(source_cache_tail)
  end
end

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
---@param stat table? Metadata snapshot used by the caller's classification cache.
---@return string?
---@return "too_large"? reason
function M.read_source(file_path, stat)
  stat = stat or uv.fs_stat(file_path)
  if stat == nil or stat.type ~= "file" then
    return nil
  end

  local cached = source_cache[file_path]
  if stat.size > MAX_SOURCE_BYTES then
    if cached ~= nil then
      remove(cached)
    end
    return nil, "too_large"
  end

  local fingerprint = M.fingerprint(stat)
  if cached ~= nil and cached.fingerprint == fingerprint then
    promote(cached)
    return cached.content
  end

  local file = io.open(file_path, "r")
  if file == nil then
    return nil
  end
  -- One extra byte detects growth after stat without accepting a truncated
  -- source. A numeric read returns nil at empty-file EOF, unlike `*a`.
  local content, err = file:read(MAX_SOURCE_BYTES + 1)
  file:close()
  if err ~= nil then
    return nil
  end
  content = content or ""
  if #content > MAX_SOURCE_BYTES then
    if cached ~= nil then
      remove(cached)
    end
    return nil, "too_large"
  end

  if cached ~= nil then
    remove(cached)
  end

  local entry = {
    file_path = file_path,
    fingerprint = fingerprint,
    content = content,
  }
  source_cache[file_path] = entry
  prepend(entry)
  source_cache_entries = source_cache_entries + 1
  source_cache_bytes = source_cache_bytes + #content
  evict_until_bounded()
  return content
end

function M.clear_source_cache()
  source_cache = {}
  source_cache_head = nil
  source_cache_tail = nil
  source_cache_entries = 0
  source_cache_bytes = 0
end

return M
