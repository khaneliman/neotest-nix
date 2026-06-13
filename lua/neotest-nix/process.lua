local nio = require("nio")

local M = {}

---@param message string
---@return neotest.Process
local function completed_failure(message)
  return {
    attach = function() end,
    is_complete = function()
      return true
    end,
    output = function()
      return message
    end,
    output_stream = function()
      local sent = false
      return function()
        if sent then
          return nil
        end
        sent = true
        return message
      end
    end,
    result = function()
      return 1
    end,
    stop = function() end,
  }
end

---@param command string[]
---@param err any
---@return string
local function spawn_error_message(command, err)
  local executable = command[1] or "<unknown>"
  local message = tostring(err)
  if message:match("ENOENT") ~= nil then
    return ("neotest-nix: failed to start `%s`: executable not found on PATH"):format(executable)
  end

  return ("neotest-nix: failed to start `%s`: %s"):format(executable, message)
end

---@async
---@param spec neotest.RunSpec
---@return neotest.Process
function M.strategy(spec)
  local output_path = nio.fn.tempname()
  ---@type file*?
  local output_file, open_err = io.open(output_path, "w")
  if output_file == nil then
    return completed_failure(
      ("neotest-nix: failed to open output file `%s`: %s"):format(output_path, tostring(open_err))
    )
  end

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

  local function complete(code)
    result_code = code
    if output_file ~= nil then
      output_file:close()
      output_file = nil
    end
    if not output_finish.is_set() then
      output_finish.set()
    end
    finish.set()
  end

  ---@type vim.SystemObj?
  local process
  local ok, system = pcall(vim.system, spec.command, {
    cwd = spec.cwd,
    env = spec.env,
    stderr = on_output,
    stdout = on_output,
  }, function(result)
    complete(result.code)
  end)
  if ok then
    process = system
  else
    on_output(nil, spawn_error_message(spec.command, system))
    complete(1)
  end

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
      if process ~= nil then
        process:kill(15)
      end
    end,
  }
end

return M
