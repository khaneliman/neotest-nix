local M = {}

---@class neotest-nix.PythonTraceback
---@field filename string
---@field line integer
---@field message string

---@param output string
---@return neotest-nix.PythonTraceback[]
function M.parse_python_tracebacks(output)
  local tracebacks = {}
  local pending_frame
  local pending_test_frame

  for line in output:gmatch("[^\r\n]+") do
    local parsed_filename, parsed_line = line:match('^%s*File%s+"([^"]+)",%s+line%s+(%d+),')
    if parsed_line ~= nil then
      pending_frame = { filename = parsed_filename, line = tonumber(parsed_line) }
      if M.is_test_script_filename(parsed_filename) then
        pending_test_frame = pending_frame
      end
    elseif pending_frame ~= nil then
      local message = line:match("^%s*([%w_%.]+:%s*.*)$") or line:match("^%s*([%w_%.]+)%s*$")
      if message ~= nil then
        local frame = pending_test_frame or pending_frame
        table.insert(tracebacks, {
          filename = frame.filename,
          line = frame.line,
          message = message,
        })
        pending_frame = nil
        pending_test_frame = nil
      end
    end
  end

  return tracebacks
end

---@param filename string
---@return boolean
function M.is_test_script_filename(filename)
  return filename:match("[^/]+$") == "test-script.py"
end

---@param position neotest-nix.Position
---@param traceback_line integer
---@return integer?
function M.test_script_line(position, traceback_line)
  if position.test_script_range == nil or traceback_line < 1 then
    return nil
  end

  local line = position.test_script_range[1] + traceback_line
  if line > position.test_script_range[3] then
    return nil
  end

  return line
end

return M
