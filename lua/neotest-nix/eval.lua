local M = {}

local nix_command_features = {
  "--extra-experimental-features",
  "nix-command flakes",
}

local default_eval_outputs = {
  { attr = "checks" },
}

---@param names string[]
---@param pattern string?
---@return string[]
local function filter_names(names, pattern)
  if pattern == nil then
    return names
  end

  local filtered = {}
  for _, name in ipairs(names) do
    if name:match(pattern) ~= nil then
      table.insert(filtered, name)
    end
  end
  return filtered
end

---Enumerate flake outputs per system by evaluating the flake.
---@param root string
---@param specs neotest-nix.EvalOutput[]?
---@return { system: string, outputs: { attr: string, names: string[] }[] }?
function M.eval_outputs(root, specs)
  specs = specs or default_eval_outputs

  local nio = require("nio")

  ---@param command string[]
  local function run(command)
    local future = nio.control.future()
    vim.system(command, { cwd = root, text = true }, function(result)
      future.set(result)
    end)
    return future.wait()
  end

  -- Current system: cheap impure builtin, does not evaluate the flake.
  local system_command = { "nix", "eval", "--impure", "--raw" }
  vim.list_extend(system_command, nix_command_features)
  vim.list_extend(system_command, { "--expr", "builtins.currentSystem" })

  local system_result = run(system_command)
  if system_result.code ~= 0 or system_result.stdout == nil or system_result.stdout == "" then
    return nil
  end
  local system = vim.trim(system_result.stdout)

  local outputs = {}
  for _, output_spec in ipairs(specs) do
    -- No --impure so the flake eval cache applies; a missing
    -- <attr>.<system> simply exits non-zero and is skipped.
    local names_command = { "nix", "eval", "--json" }
    vim.list_extend(names_command, nix_command_features)
    vim.list_extend(
      names_command,
      { "--apply", "builtins.attrNames", (".#%s.%s"):format(output_spec.attr, system) }
    )

    local names_result = run(names_command)
    if names_result.code == 0 and names_result.stdout ~= nil and names_result.stdout ~= "" then
      local ok, names = pcall(vim.json.decode, names_result.stdout)
      if ok and type(names) == "table" then
        names = filter_names(names, output_spec.match)
        if #names > 0 then
          table.insert(outputs, { attr = output_spec.attr, names = names })
        end
      end
    end
  end

  return { system = system, outputs = outputs }
end

---Merge eval-discovered flake outputs into a source-parsed position tree.
---@param tree neotest.Tree
---@param system string
---@param outputs { attr: string, names: string[] }[]
---@return neotest.Tree
function M.merge_outputs(tree, system, outputs)
  local existing = {}
  for _, position in tree:iter() do
    ---@cast position neotest-nix.Position
    if position.attr_path ~= nil then
      existing[position.attr_path] = true
    end
  end

  local file_path = tree:data().path
  local list = tree:to_list()
  local added = false

  for _, output in ipairs(outputs) do
    local attr = output.attr

    ---@type table[]
    local system_child = {
      {
        id = ("neotest-nix:eval:%s.%s"):format(attr, system),
        name = system,
        path = file_path,
        type = "namespace",
        range = { 0, 0, 0, 0 },
      },
    }

    for _, name in ipairs(output.names) do
      local attr_path = ("%s.%s.%s"):format(attr, system, name)
      if not existing[attr_path] then
        existing[attr_path] = true
        table.insert(system_child, {
          {
            id = attr_path,
            name = name,
            path = file_path,
            type = "test",
            range = { 0, 0, 0, 0 },
            runner = "nix",
            attr_path = attr_path,
          },
        })
      end
    end

    -- Only add the output when it has names the source didn't already declare.
    if #system_child > 1 then
      added = true
      table.insert(list, {
        {
          id = ("neotest-nix:eval:%s"):format(attr),
          name = attr,
          path = file_path,
          type = "namespace",
          range = { 0, 0, 0, 0 },
        },
        system_child,
      })
    end
  end

  if not added then
    return tree
  end

  local Tree = require("neotest.types").Tree
  return Tree.from_list(list, function(data)
    return data.id
  end)
end

return M
