local nio = require("nio")

local M = {}

---@async
---@param spec neotest.RunSpec
---@return neotest.Process
function M.strategy(spec)
  local output_path = nio.fn.tempname()
  ---@type file*?
  local output_file = assert(io.open(output_path, "w"))

  local finish = nio.control.future()
  local output_finish = nio.control.future()
  local output_queue = nio.control.queue()
  local result_code

  -- Hold a single handle for the process lifetime; flush per chunk so the
  -- output file stays live-readable while avoiding an open/close per chunk.
  local function on_output(_, data)
    if data == nil or data == "" then
      return
    end

    if output_file ~= nil then
      output_file:write(data)
      output_file:flush()
    end
    output_queue.put_nowait(data)
  end

  local process = vim.system(spec.command, {
    cwd = spec.cwd,
    env = spec.env,
    stderr = on_output,
    stdout = on_output,
  }, function(result)
    result_code = result.code
    if output_file ~= nil then
      output_file:close()
      output_file = nil
    end
    if not output_finish.is_set() then
      output_finish.set()
    end
    finish.set()
  end)

  return {
    attach = function() end,
    is_complete = function()
      return result_code ~= nil
    end,
    output = function()
      return output_path
    end,
    output_stream = function()
      return function()
        local data = nio.first({ output_queue.get, output_finish.wait })
        if data ~= nil then
          return data
        end

        if output_queue.size() ~= 0 then
          return output_queue.get()
        end
      end
    end,
    result = function()
      finish.wait()
      return result_code or 1
    end,
    stop = function()
      process:kill(15)
    end,
  }
end

return M
