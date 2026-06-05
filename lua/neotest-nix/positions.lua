local spec = require("neotest-nix.spec")

local M = {}

local system_pattern = spec.system_pattern

---@type string?
local cached_query

---Load and cache the tree-sitter query. Deferred until first discovery so a
---bare `require("neotest-nix")` performs no file IO at module load.
---@return string
function M.query()
  if cached_query ~= nil then
    return cached_query
  end

  local query_path = vim.api.nvim_get_runtime_file("queries/nix/neotest-nix.scm", false)[1]
  assert(query_path, "neotest-nix: missing queries/nix/neotest-nix.scm")

  local file = assert(io.open(query_path, "r"))
  local query = file:read("*a")
  file:close()
  cached_query = query
  return cached_query
end

---@param node TSNode
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

---@param node TSNode
---@return TSNode?
local function containing_binding(node)
  ---@type TSNode?
  local current = node
  while current ~= nil do
    if current:type() == "binding" then
      return current
    end
    current = current:parent()
  end

  return nil
end

---@param binding TSNode
---@return TSNode?
local function binding_attrpath(binding)
  local attrpaths = binding:field("attrpath")
  return attrpaths and attrpaths[1] or nil
end

---@param node TSNode
---@return TSNode?
local function binding_expression(node)
  local expressions = node:field("expression")
  return expressions and expressions[1] or nil
end

---@param binding TSNode
---@param source string
---@return string[]
local function binding_attrpath_parts(binding, source)
  local attrpath = binding_attrpath(binding)
  return attrpath ~= nil and attrpath_parts(attrpath, source) or {}
end

---@param binding TSNode
---@param source string
---@return string[]
local function full_attrpath_parts(binding, source)
  local attrpaths = {}
  ---@type TSNode?
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
  return #parts >= 1 and parts[1] ~= "checks" and parts[#parts] ~= "tests"
end

---@param binding TSNode
---@param source string
---@return boolean
local function is_nix_unit_value(binding, source)
  local expression = binding_expression(binding)
  if expression == nil or expression:type() ~= "attrset_expression" then
    return false
  end

  local has_expr = false
  local has_expected = false

  -- tree-sitter-nix wraps an attrset's bindings in a binding_set node, so
  -- the bindings are not direct children of the attrset_expression.
  ---@param node TSNode
  local function inspect(node)
    for child in node:iter_children() do
      local kind = child:type()
      if kind == "binding" then
        local parts = binding_attrpath_parts(child, source)
        if parts[1] == "expr" then
          has_expr = true
        elseif parts[1] == "expected" or parts[1] == "expectedError" then
          has_expected = true
        end
      elseif kind == "binding_set" then
        inspect(child)
      end
    end
  end

  inspect(expression)

  return has_expr and has_expected
end

---Classify how a nix-unit suite can be evaluated for a run.
---  "flake"  -> reachable as a flake output (file is flake.nix)
---  "import" -> file's top-level expression is an attrset and the suite is
---              reached by plain attr indexing, so `import ./file` works
---  nil      -> wrapped in a function/let; not individually runnable
---@param binding TSNode
---@param file_path string
---@return "flake"|"import"|nil
local function nix_unit_kind(binding, file_path)
  if vim.fs.basename(file_path) == "flake.nix" then
    return "flake"
  end

  local blocked = false
  local top = binding
  local current = binding
  while current ~= nil do
    local kind = current:type()
    if kind == "let_expression" or kind == "function_expression" then
      blocked = true
    end

    local parent = current:parent()
    if parent == nil or parent:type() == "source_code" then
      top = current
      break
    end
    current = parent
  end

  if not blocked then
    local top_type = top:type()
    if top_type == "attrset_expression" or top_type == "rec_attrset_expression" then
      return "import"
    end
  end

  return nil
end

---@param binding TSNode
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

---@param node TSNode
---@param callback fun(node: TSNode): TSNode?
---@return TSNode?
local function find_descendant(node, callback)
  local found = callback(node)
  if found ~= nil then
    return found
  end

  for child in node:iter_children() do
    local descendant = find_descendant(child, callback)
    if descendant ~= nil then
      return descendant
    end
  end

  return nil
end

---@param binding TSNode
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
---@param captured_nodes table<string, TSNode>
---@return neotest.Position?
function M.build_position(file_path, source, captured_nodes)
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
      -- neotest assigns `id` after build_position returns, so the partial
      -- position legitimately omits it.
      ---@diagnostic disable-next-line: return-type-mismatch
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
  local is_nix_unit = is_nix_unit_test(parts) and is_nix_unit_value(binding, source)
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
  elseif is_nix_unit then
    position.nix_unit_kind = nix_unit_kind(binding, file_path)
  end

  ---@diagnostic disable-next-line: return-type-mismatch
  return position
end

return M
