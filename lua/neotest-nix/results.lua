local paths = require("neotest-nix.paths")
local vm = require("neotest-nix.vm")

local M = {}

local uv = vim.uv or vim.loop

---@param path string
---@return string?
local function read_file(path)
  if type(path) ~= "string" or uv.fs_stat(path) == nil then
    return nil
  end

  local file = io.open(path, "r")
  if file == nil then
    return nil
  end

  local content = file:read("*a")
  file:close()
  return content
end

---@param output string
---@return string
local function error_message(output)
  local message

  for line in output:gmatch("[^\r\n]+") do
    local parsed = line:match("^%s*error:%s*(.+)$")
    if parsed ~= nil and parsed ~= "" then
      -- The first `error:` line is the underlying cause; later lines are
      -- usually the generic "build of '...' failed" wrapper.
      message = parsed
      break
    end
  end

  return message or "Nix command failed"
end

---@param path string
---@param root string
---@return string?
local function local_error_path(path, root)
  local translated = paths.translate_store_path(path, root)
  if uv.fs_stat(translated) == nil then
    return nil
  end

  local normalized_root = vim.fs.normalize(root)
  local normalized_path = vim.fs.normalize(translated)
  if
    normalized_path == normalized_root
    or normalized_path:sub(1, #normalized_root + 1) == normalized_root .. "/"
  then
    return normalized_path
  end

  return nil
end

---@class neotest-nix.ParsedError
---@field message string
---@field path string
---@field line integer
---@field column integer
---@field severity integer?

---@param output string
---@param root string
---@return neotest-nix.ParsedError[]
function M.parse_errors(output, root)
  local errors = {}
  local message = error_message(output)

  for line in output:gmatch("[^\r\n]+") do
    local path, row, column = line:match("^%s*at%s+([^:\n]+):(%d+):(%d+):")
    if path ~= nil then
      local translated = local_error_path(path, root)
      if translated ~= nil then
        table.insert(errors, {
          message = message,
          path = translated,
          line = tonumber(row) - 1,
          column = tonumber(column) - 1,
          severity = vim.diagnostic.severity.ERROR,
        })
      end
    end
  end

  return errors
end

---@param tree neotest.Tree
---@return neotest.Position[]
local function test_positions(tree)
  local positions = {}

  for _, position in tree:iter() do
    if position.type == "test" then
      table.insert(positions, position)
    end
  end

  return positions
end

---@param tree neotest.Tree
---@return neotest-nix.Position[]
local function vm_positions(tree)
  local positions = {}

  for _, position in tree:iter() do
    ---@cast position neotest-nix.Position
    if position.type == "test" and position.test_script_range ~= nil then
      table.insert(positions, position)
    end
  end

  return positions
end

---@param position neotest.Position
---@param error neotest-nix.ParsedError
---@return boolean
local function contains_error(position, error)
  if vim.fs.normalize(position.path) ~= error.path then
    return false
  end

  local range = position.total_range or position.range
  if range == nil then
    return false
  end

  return error.line >= range[1] and error.line <= range[3]
end

---@param tree neotest.Tree
---@param spec neotest.RunSpec
---@param error neotest-nix.ParsedError
---@param positions neotest.Position[]
---@return string
local function result_id_for_error(tree, spec, error, positions)
  local context = spec.context or {}
  if context.pos_id ~= nil and tree:get_key(context.pos_id) ~= nil then
    return context.pos_id
  end

  for _, position in ipairs(positions) do
    if contains_error(position, error) then
      return position.id
    end
  end

  return tree:data().id
end

---Select the single VM test a traceback can be attributed to.
---A NixOS VM failure prints a Python traceback whose line numbers are
---relative to that test's generated script; line numbers reset per test,
---so they cannot tell sibling VM tests apart. Only attribute when the run
---unambiguously targets one VM test: either there is a single VM position,
---or the run context names one. A broader run (e.g. `nix flake check` over
---several VM tests) returns nil rather than blaming every VM test.
---@param tree neotest.Tree
---@param spec neotest.RunSpec
---@return neotest-nix.Position?
local function vm_target(tree, spec)
  local positions = vm_positions(tree)
  if #positions <= 1 then
    return positions[1]
  end

  local context = spec.context or {}
  if context.pos_id ~= nil then
    for _, position in ipairs(positions) do
      if position.id == context.pos_id then
        return position
      end
    end
  end

  return nil
end

---@param results table<string, neotest.Result>
---@param id string
---@param error neotest-nix.ParsedError
local function add_error(results, id, error)
  results[id] = results[id] or {
    status = "failed",
    errors = {},
  }

  table.insert(results[id].errors, {
    message = error.message,
    line = error.line,
    column = error.column,
    severity = error.severity,
  })
end

---@param results table<string, neotest.Result>
---@param target neotest-nix.Position?
---@param output string
---@param start_at integer?
---@return integer
local function add_vm_tracebacks(results, target, output, start_at)
  local tracebacks = vm.parse_python_tracebacks(output)
  start_at = start_at or 1
  if target == nil or #tracebacks < start_at then
    return #tracebacks
  end

  for index = start_at, #tracebacks do
    local traceback = tracebacks[index]
    local line = vm.test_script_line(target, traceback.line)
    if line ~= nil then
      add_error(results, target.id, {
        message = traceback.message,
        path = target.path,
        line = line,
        column = 0,
        severity = vim.diagnostic.severity.ERROR,
      })
    end
  end

  return #tracebacks
end

---@param spec neotest.RunSpec
---@param result neotest.StrategyResult
---@param tree neotest.Tree
---@return table<string, neotest.Result>
function M.results(spec, result, tree)
  local root = spec.cwd or uv.cwd() or "."
  local output = read_file(result.output) or result.output or ""
  output = paths.translate_string(output, root)

  if result.code == 0 then
    return {
      [tree:data().id] = {
        status = "passed",
        short = output,
      },
    }
  end

  local parsed_errors = M.parse_errors(output, root)
  local results = {}
  local positions = test_positions(tree)

  for _, parsed in ipairs(parsed_errors) do
    add_error(results, result_id_for_error(tree, spec, parsed, positions), parsed)
  end
  add_vm_tracebacks(results, vm_target(tree, spec), output)

  if vim.tbl_isempty(results) then
    results[tree:data().id] = {
      status = "failed",
      short = error_message(output),
      errors = {},
    }
  end

  return paths.translate_result_paths(results, root)
end

---@param spec neotest.RunSpec
---@param tree neotest.Tree
---@return fun(output_stream: fun(): string): fun(): table<string, neotest.Result>?
function M.stream(spec, tree)
  return function(output_stream)
    local output = {}
    local parsed_error_count = 0
    local traceback_count = 0
    local positions = test_positions(tree)
    local target = vm_target(tree, spec)

    return function()
      while true do
        local line = output_stream()
        if line == nil then
          return nil
        end

        table.insert(output, line)
        local text = table.concat(output, "\n")
        local root = spec.cwd or uv.cwd() or "."
        local parsed_errors = M.parse_errors(text, root)
        local stream_results = {}

        for index = parsed_error_count + 1, #parsed_errors do
          local parsed = parsed_errors[index]
          add_error(stream_results, result_id_for_error(tree, spec, parsed, positions), parsed)
        end
        parsed_error_count = #parsed_errors

        traceback_count = add_vm_tracebacks(stream_results, target, text, traceback_count + 1)

        if not vim.tbl_isempty(stream_results) then
          for _, result in pairs(stream_results) do
            result.short = text
          end
          return paths.translate_result_paths(stream_results, root)
        end
      end
    end
  end
end

return M
