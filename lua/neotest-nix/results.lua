local paths = require("neotest-nix.paths")

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
      message = parsed
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
---@return string
local function result_id_for_error(tree, spec, error)
  local context = spec.context or {}
  if context.pos_id ~= nil and tree:get_key(context.pos_id) ~= nil then
    return context.pos_id
  end

  for _, position in ipairs(test_positions(tree)) do
    if contains_error(position, error) then
      return position.id
    end
  end

  return tree:data().id
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

---@param spec neotest.RunSpec
---@param result neotest.StrategyResult
---@param tree neotest.Tree
---@return table<string, neotest.Result>
function M.results(spec, result, tree)
  local root = spec.cwd or vim.loop.cwd() or "."
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

  for _, parsed in ipairs(parsed_errors) do
    add_error(results, result_id_for_error(tree, spec, parsed), parsed)
  end

  if vim.tbl_isempty(results) then
    results[tree:data().id] = {
      status = "failed",
      short = error_message(output),
      errors = {},
    }
  end

  return paths.translate_result_paths(results, root)
end

return M
