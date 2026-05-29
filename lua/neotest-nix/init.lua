---@diagnostic disable: undefined-field

local discover = require("neotest-nix.discover")
local parser = require("neotest-nix.parser")
local results = require("neotest-nix.results")
local spec = require("neotest-nix.spec")

local M = {}

local system_pattern = "^[a-z0-9_]+-[a-z0-9_]+$"
local nix_unit_test_pattern = "^test"

---@return string
local function load_query()
  local query_path = vim.api.nvim_get_runtime_file("queries/nix/neotest-nix.scm", false)[1]
  assert(query_path, "neotest-nix: missing queries/nix/neotest-nix.scm")

  local file = assert(io.open(query_path, "r"))
  local query = file:read("*a")
  file:close()
  return query
end

---@param node userdata
---@param source string
---@return string[]
local function attrpath_parts(node, source)
  local parts = {}

  for child in node:iter_children() do
    if child:type() == "identifier" then
      table.insert(parts, vim.treesitter.get_node_text(child, source))
    end
  end

  return parts
end

---@param node userdata
---@return userdata?
local function containing_binding(node)
  local current = node
  while current ~= nil do
    if current:type() == "binding" then
      return current
    end
    current = current:parent()
  end

  return nil
end

---@param binding userdata
---@return userdata?
local function binding_attrpath(binding)
  local attrpaths = binding:field("attrpath")
  return attrpaths and attrpaths[1] or nil
end

---@param node userdata
---@return userdata?
local function binding_expression(node)
  local expressions = node:field("expression")
  return expressions and expressions[1] or nil
end

---@param binding userdata
---@param source string
---@return string[]
local function binding_attrpath_parts(binding, source)
  local attrpath = binding_attrpath(binding)
  return attrpath ~= nil and attrpath_parts(attrpath, source) or {}
end

---@param binding userdata
---@param source string
---@return string[]
local function full_attrpath_parts(binding, source)
  local attrpaths = {}
  local current = binding

  while current ~= nil do
    if current:type() == "binding" then
      local parts = binding_attrpath_parts(current, source)
      if parts[1] ~= nil and parts[1] ~= "outputs" then
        table.insert(attrpaths, 1, parts)
      end
    end

    current = current:parent()
  end

  local full_parts = {}
  for _, parts in ipairs(attrpaths) do
    vim.list_extend(full_parts, parts)
  end

  return full_parts
end

---@param parts string[]
---@return boolean
local function is_dotted_check(parts)
  return #parts == 3 and parts[1] == "checks" and parts[2]:match(system_pattern) ~= nil
end

---@param parts string[]
---@return boolean
local function is_nix_unit_test(parts)
  return #parts >= 2 and parts[1] == "tests" and parts[#parts]:match(nix_unit_test_pattern) ~= nil
end

---@param binding userdata
---@param source string
---@return boolean
local function has_checks_ancestor(binding, source)
  local current = binding:parent()

  while current ~= nil do
    if current:type() == "binding" then
      local attrpath = binding_attrpath(current)
      if attrpath ~= nil then
        local parts = attrpath_parts(attrpath, source)
        if parts[1] == "checks" then
          return true
        end
      end
    end

    current = current:parent()
  end

  return false
end

---@param node userdata
---@param callback fun(node: userdata): userdata?
---@return userdata?
local function find_descendant(node, callback)
  local found = callback(node)
  if found ~= nil then
    return found
  end

  for child in node:iter_children() do
    found = find_descendant(child, callback)
    if found ~= nil then
      return found
    end
  end

  return nil
end

---@param binding userdata
---@param source string
---@return integer[]?
local function test_script_range(binding, source)
  local expression = find_descendant(binding, function(node)
    if node:type() ~= "binding" then
      return nil
    end

    local parts = binding_attrpath_parts(node, source)
    if parts[1] ~= "testScript" then
      return nil
    end

    local value = binding_expression(node)
    if value ~= nil and value:type() == "indented_string_expression" then
      return value
    end

    return nil
  end)

  return expression ~= nil and { expression:range() } or nil
end

---@param file_path string
---@param source string
---@param captured_nodes table<string, userdata>
---@return neotest.Position?
function M._build_position(file_path, source, captured_nodes)
  local namespace_name = captured_nodes["namespace.name"]
  if namespace_name ~= nil then
    local name = vim.treesitter.get_node_text(namespace_name, source)
    local binding = containing_binding(namespace_name)
    local parts = binding ~= nil and binding_attrpath_parts(binding, source) or {}
    local is_outputs = name == "outputs" and parts[1] == "outputs"
    local is_checks = name == "checks" and parts[1] == "checks" and #parts == 1
    local is_tests = name == "tests" and parts[1] == "tests" and #parts == 1
    local is_system = name:match(system_pattern) ~= nil
      and binding ~= nil
      and has_checks_ancestor(binding, source)

    if is_outputs or is_checks or is_tests or is_system then
      local definition = captured_nodes["namespace.definition"]
      return {
        type = "namespace",
        path = file_path,
        name = name,
        range = { definition:range() },
      }
    end
  end

  local test_name = captured_nodes["test.name"]
  if test_name == nil then
    return nil
  end

  local binding = containing_binding(test_name)
  if binding == nil then
    return nil
  end

  local attrpath = binding_attrpath(binding)
  if attrpath == nil then
    return nil
  end

  local parts = full_attrpath_parts(binding, source)
  local is_check = is_dotted_check(parts)
  local is_nix_unit = is_nix_unit_test(parts)
  if not is_check and not is_nix_unit then
    return nil
  end

  local definition = captured_nodes["test.definition"]
  local position = {
    attr_path = table.concat(parts, "."),
    type = "test",
    path = file_path,
    name = parts[#parts],
    runner = is_nix_unit and "nix-unit" or "nix",
    range = { definition:range() },
  }

  if is_check then
    position.test_script_range = test_script_range(binding, source)
  end

  return position
end

---@class neotest-nix.Config
---@field parser_runtime_paths? string[] Extra runtimepath roots containing parser/nix.so.

---@param opts neotest-nix.Config?
---@return neotest.Adapter
function M.setup(opts)
  opts = opts or {}
  local query = load_query()

  return {
    name = "neotest-nix",

    root = discover.root,
    is_test_file = discover.is_test_file,
    filter_dir = discover.filter_dir,
    build_spec = spec.build_spec,
    results = results.results,

    ---@param file_path string
    discover_positions = function(file_path)
      parser.ensure_nix_parser(opts.parser_runtime_paths)

      local lib = require("neotest.lib")
      ---@type any
      local parse_options = {
        build_position = 'require("neotest-nix")._build_position',
      }
      local ok, positions = pcall(lib.treesitter.parse_positions, file_path, query, parse_options)
      if not ok then
        vim.notify(
          ("neotest-nix: failed to parse %s: %s"):format(file_path, positions),
          vim.log.levels.WARN
        )
        return nil
      end

      return positions
    end,
  }
end

return setmetatable(M, {
  __call = function(_, opts)
    return M.setup(opts)
  end,
})
