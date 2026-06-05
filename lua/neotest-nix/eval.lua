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
    -- --no-write-lock-file: discovery must not mutate the repo by locking the
    -- flake on disk.
    local names_command = { "nix", "eval", "--json", "--no-write-lock-file" }
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

-- Discovered flake installables for wrapped nix-unit suites, keyed by flake
-- root *and* the suite's test names. A single root can expose several wrapped
-- suites in different outputs (e.g. ".#tests" and ".#libTests"), so keying on
-- the root alone would return the first-detected output for every suite. Only
-- successful lookups are cached, so a failed detection (e.g. a transient eval
-- error) is retried on the next run.
---@type table<string, string>
local nix_unit_flake_cache = {}

---Stable cache key from the flake root and the suite's test names. The names
---are sorted into a copy so discovery order does not change the key.
---@param root string
---@param test_names string[]
---@return string
local function flake_cache_key(root, test_names)
  local sorted = vim.deepcopy(test_names)
  table.sort(sorted)
  return root .. "\0" .. table.concat(sorted, "\0")
end

---Nix expression that returns the names of the flake's top-level outputs whose
---candidate output contains every one of `test_names` as nix-unit leaves. The
---applied nix-unit suite (e.g. the `tests` output) can expose tests directly
---or under runtime-generated namespaces, and evaluation errors are swallowed
---per output. Candidate names are intentionally conservative; arbitrary output
---names should use `nix_unit_flakes` config instead of scanning the whole flake.
---@param test_names string[]
---@return string
function M.nix_unit_flake_expr(test_names)
  local json = vim.json.encode(test_names)
  return ([[
let
  flake = builtins.getFlake (toString ./. );
  testNames = builtins.fromJSON ''%s'';
  isTest = v:
    builtins.isAttrs v
    && builtins.hasAttr "expr" v
    && (builtins.hasAttr "expected" v || builtins.hasAttr "expectedError" v);
  isDerivation = v: builtins.isAttrs v && (v.type or null) == "derivation";
  candidateName = name:
    builtins.elem name [ "tests" "libTests" "unitTests" ]
    || builtins.match ".*[Tt]ests?" name != null;
  hasDirect = name: set:
    builtins.hasAttr name set
    && (let r = builtins.tryEval (set.${name}); in r.success && isTest r.value);
  hasDirectAll = v: builtins.isAttrs v && builtins.all (n: hasDirect n v) testNames;
  maxDepth = 8;
  containsName = depth: target: set:
    depth <= maxDepth
    && builtins.isAttrs set
    && !isDerivation set
    && builtins.any (
      name:
      let
        r = builtins.tryEval (set.${name});
      in
      r.success
      && (
        (name == target && isTest r.value)
        || containsName (depth + 1) target r.value
      )
    ) (builtins.attrNames set);
  hasNestedAll = v: builtins.isAttrs v && builtins.all (n: containsName 0 n v) testNames;
  candidateNames = builtins.filter candidateName (builtins.attrNames flake);
in
  builtins.filter
    (
      name:
      let
        r = builtins.tryEval flake.${name};
      in
      r.success && (hasDirectAll r.value || (candidateName name && hasNestedAll r.value))
    )
    (builtins.attrNames flake)
]]):format(json)
end

-- Conventional nix-unit flake output names, preferred when several match.
local nix_unit_flake_preference = { "tests", "libTests", "unitTests" }

---Detect the flake installable that exposes a wrapped nix-unit suite by
---evaluating the flake and matching the suite's test attribute names. Returns
---e.g. ".#tests", or nil when nothing matches.
---@param root string
---@param test_names string[]
---@return string?
function M.detect_nix_unit_flake(root, test_names)
  if test_names == nil or #test_names == 0 then
    return nil
  end

  local cache_key = flake_cache_key(root, test_names)
  if nix_unit_flake_cache[cache_key] ~= nil then
    return nix_unit_flake_cache[cache_key]
  end

  local nio = require("nio")
  -- --impure: getFlake refuses an unlocked local flake reference otherwise.
  -- --no-write-lock-file: discovery must not mutate the repo by locking the
  -- flake on disk.
  local command = { "nix", "eval", "--impure", "--json", "--no-write-lock-file" }
  vim.list_extend(command, nix_command_features)
  vim.list_extend(command, { "--expr", M.nix_unit_flake_expr(test_names) })

  local future = nio.control.future()
  vim.system(command, { cwd = root, text = true }, function(result)
    future.set(result)
  end)
  local result = future.wait()

  if result.code ~= 0 or result.stdout == nil or result.stdout == "" then
    return nil
  end

  local ok, names = pcall(vim.json.decode, result.stdout)
  if not ok or type(names) ~= "table" or #names == 0 then
    return nil
  end

  local chosen
  for _, preferred in ipairs(nix_unit_flake_preference) do
    if vim.tbl_contains(names, preferred) then
      chosen = preferred
      break
    end
  end
  chosen = chosen or names[1]

  local flake = ".#" .. chosen
  nix_unit_flake_cache[cache_key] = flake
  return flake
end

---Find a descendant namespace by name in a `Tree:to_list` structure, where
---each node is `{ data, child_node... }`. Used to nest eval-discovered checks
---under the source-parsed namespace instead of a parallel duplicate.
---@param node table
---@param name string
---@return table?
local function find_namespace(node, name)
  for index = 2, #node do
    local child = node[index]
    if child[1].type == "namespace" and child[1].name == name then
      return child
    end
    local found = find_namespace(child, name)
    if found ~= nil then
      return found
    end
  end
  return nil
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

  -- Injected positions must carry ids unique to this file. neotest applies a
  -- result to every position sharing the result's id across all discovered
  -- trees, so a path-less id (e.g. "neotest-nix:eval:checks") would collide
  -- between sibling flake.nix files and mark the wrong flake's checks. Mirror
  -- neotest's own `path::…` scheme, keeping the `neotest-nix:eval:` marker so
  -- the synthetic nodes stay distinct from same-file source-parsed namespaces.
  ---@param suffix string
  ---@return string
  local function eval_id(suffix)
    return ("%s::neotest-nix:eval:%s"):format(file_path, suffix)
  end

  local list = tree:to_list()
  local added = false

  for _, output in ipairs(outputs) do
    local attr = output.attr

    ---@type table[]
    local leaves = {}
    for _, name in ipairs(output.names) do
      local attr_path = ("%s.%s.%s"):format(attr, system, name)
      if not existing[attr_path] then
        existing[attr_path] = true
        table.insert(leaves, {
          {
            id = eval_id(attr_path),
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
    if #leaves > 0 then
      added = true

      local attr_node = find_namespace(list, attr)
      local system_node = attr_node ~= nil and find_namespace(attr_node, system) or nil

      if system_node ~= nil then
        vim.list_extend(system_node, leaves)
      else
        local system_child = {
          {
            id = eval_id(("%s.%s"):format(attr, system)),
            name = system,
            path = file_path,
            type = "namespace",
            range = { 0, 0, 0, 0 },
          },
        }
        vim.list_extend(system_child, leaves)

        if attr_node ~= nil then
          table.insert(attr_node, system_child)
        else
          table.insert(list, {
            {
              id = eval_id(attr),
              name = attr,
              path = file_path,
              type = "namespace",
              range = { 0, 0, 0, 0 },
            },
            system_child,
          })
        end
      end
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
