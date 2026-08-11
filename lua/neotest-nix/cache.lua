local M = {}

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

return M
