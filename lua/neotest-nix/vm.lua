local M = {}

---@class neotest-nix.PythonTraceback
---@field line integer
---@field message string

---@param output string
---@return neotest-nix.PythonTraceback[]
function M.parse_python_tracebacks(output)
  local tracebacks = {}
  local pending_line

  for line in output:gmatch("[^\r\n]+") do
    local parsed_line = line:match('^%s*File%s+"[^"]+",%s+line%s+(%d+),')
    if parsed_line ~= nil then
      pending_line = tonumber(parsed_line)
    elseif pending_line ~= nil then
      local message = line:match("^%s*([%w_%.]+:%s*.*)$") or line:match("^%s*([%w_%.]+)%s*$")
      if message ~= nil then
        table.insert(tracebacks, {
          line = pending_line,
          message = message,
        })
        pending_line = nil
      end
    end
  end

  return tracebacks
end

---@param position neotest-nix.Position
---@param traceback_line integer
---@return integer?
function M.test_script_line(position, traceback_line)
  if position.test_script_range == nil or traceback_line < 1 then
    return nil
  end

  return position.test_script_range[1] + traceback_line
end

return M
