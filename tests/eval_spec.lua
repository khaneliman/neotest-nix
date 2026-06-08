local Tree = require("neotest.types").Tree

local function get_id(data)
  return data.id
end

local function file_tree()
  return Tree.from_list({
    {
      id = "flake.nix",
      name = "flake.nix",
      path = "/p/flake.nix",
      type = "file",
      range = { 0, 0, 10, 0 },
    },
  }, get_id)
end

local function tree_with_literal_check()
  return Tree.from_list({
    {
      id = "flake.nix",
      name = "flake.nix",
      path = "/p/flake.nix",
      type = "file",
      range = { 0, 0, 10, 0 },
    },
    {
      {
        id = "checks",
        name = "checks",
        path = "/p/flake.nix",
        type = "namespace",
        range = { 1, 0, 5, 0 },
      },
      {
        {
          id = "sys",
          name = "x86_64-linux",
          path = "/p/flake.nix",
          type = "namespace",
          range = { 2, 0, 4, 0 },
        },
        {
          {
            id = "checks.x86_64-linux.unit",
            name = "unit",
            path = "/p/flake.nix",
            type = "test",
            range = { 3, 0, 3, 0 },
            runner = "nix",
            attr_path = "checks.x86_64-linux.unit",
          },
        },
      },
    },
  }, get_id)
end

local function tests_by_attr(tree)
  local found = {}
  for _, position in tree:iter() do
    if position.type == "test" then
      found[position.attr_path or position.name] = position
    end
  end
  return found
end

local function checks(names)
  return { { attr = "checks", names = names } }
end

describe("eval output merge", function()
  local adapter = require("neotest-nix")

  it("adds generated checks as runnable test positions", function()
    local merged =
      adapter._merge_eval_outputs(file_tree(), "x86_64-linux", checks({ "parseLix", "treefmt" }))
    local tests = tests_by_attr(merged)

    local parse = tests["checks.x86_64-linux.parseLix"]
    assert.is_not_nil(parse)
    assert.are.equal("nix", parse.runner)
    assert.are.equal("parseLix", parse.name)
    assert.is_not_nil(tests["checks.x86_64-linux.treefmt"])

    -- positions are keyed by a file-qualified id (so sibling flake.nix files
    -- do not collide) for results/build_spec lookup
    assert.is_not_nil(merged:get_key("/p/flake.nix::neotest-nix:eval:checks.x86_64-linux.parseLix"))
  end)

  it("nests generated checks under checks -> system namespaces", function()
    local merged = adapter._merge_eval_outputs(file_tree(), "x86_64-linux", checks({ "parseLix" }))

    local namespaces = {}
    for _, position in merged:iter() do
      if position.type == "namespace" then
        namespaces[position.name] = true
      end
    end

    assert.is_true(namespaces["checks"])
    assert.is_true(namespaces["x86_64-linux"])
  end)

  it("merges multiple outputs under their own namespaces", function()
    local merged = adapter._merge_eval_outputs(file_tree(), "x86_64-linux", {
      { attr = "checks", names = { "treefmt" } },
      { attr = "legacyPackages", names = { "test-zsh-plugins", "test-bash" } },
    })

    local namespaces = {}
    for _, position in merged:iter() do
      if position.type == "namespace" then
        namespaces[position.name] = true
      end
    end
    assert.is_true(namespaces["checks"])
    assert.is_true(namespaces["legacyPackages"])

    local tests = tests_by_attr(merged)
    assert.is_not_nil(tests["checks.x86_64-linux.treefmt"])
    local pkg = tests["legacyPackages.x86_64-linux.test-zsh-plugins"]
    assert.is_not_nil(pkg)
    assert.are.equal("nix", pkg.runner)
  end)

  it("does not duplicate outputs already present in source", function()
    local merged = adapter._merge_eval_outputs(
      tree_with_literal_check(),
      "x86_64-linux",
      checks({ "unit", "extra" })
    )

    local count = 0
    for _, position in merged:iter() do
      ---@cast position neotest-nix.Position
      if position.attr_path == "checks.x86_64-linux.unit" then
        count = count + 1
      end
    end

    assert.are.equal(1, count)
    assert.is_not_nil(tests_by_attr(merged)["checks.x86_64-linux.extra"])
  end)

  it("nests generated checks under the source namespace without duplicating it", function()
    local merged = adapter._merge_eval_outputs(
      tree_with_literal_check(),
      "x86_64-linux",
      checks({ "unit", "extra" })
    )

    local checks_namespaces = 0
    local system_namespaces = 0
    for _, position in merged:iter() do
      if position.type == "namespace" and position.name == "checks" then
        checks_namespaces = checks_namespaces + 1
      elseif position.type == "namespace" and position.name == "x86_64-linux" then
        system_namespaces = system_namespaces + 1
      end
    end

    assert.are.equal(1, checks_namespaces)
    assert.are.equal(1, system_namespaces)

    local tests = tests_by_attr(merged)
    assert.is_not_nil(tests["checks.x86_64-linux.unit"])
    assert.is_not_nil(tests["checks.x86_64-linux.extra"])
  end)

  it("qualifies injected ids by file so sibling flakes do not collide", function()
    local function file_tree_at(path)
      return Tree.from_list({
        { id = path, name = "flake.nix", path = path, type = "file", range = { 0, 0, 10, 0 } },
      }, get_id)
    end

    local function ids(tree)
      local set = {}
      for _, position in tree:iter() do
        set[position.id] = true
      end
      return set
    end

    local a =
      adapter._merge_eval_outputs(file_tree_at("/a/flake.nix"), "x86_64-linux", checks({ "unit" }))
    local b =
      adapter._merge_eval_outputs(file_tree_at("/b/flake.nix"), "x86_64-linux", checks({ "unit" }))

    local b_ids = ids(b)
    for id in pairs(ids(a)) do
      assert.is_nil(b_ids[id])
    end
  end)

  it("returns the original tree when nothing new is discovered", function()
    local base = tree_with_literal_check()
    local merged = adapter._merge_eval_outputs(base, "x86_64-linux", checks({ "unit" }))

    assert.are.equal(base, merged)
  end)
end)

describe("eval_outputs", function()
  local eval = require("neotest-nix.eval")

  ---Stub vim.system so the system probe and the attrNames eval return canned
  ---output; the callback fires synchronously so the nio future resolves at once.
  ---@param system string
  ---@param names_json string
  local function stub_system(system, names_json)
    local original = vim.system
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.system = function(command, _, callback)
      local joined = table.concat(command, " ")
      if joined:find("builtins.currentSystem", 1, true) then
        callback({ code = 0, stdout = system, stderr = "" })
      else
        callback({ code = 0, stdout = names_json, stderr = "" })
      end
      return {}
    end
    finally(function()
      vim.system = original
    end)
  end

  it("enumerates output names per system", function()
    stub_system("x86_64-linux\n", '["unit","integration"]')

    local result = eval.eval_outputs(vim.fn.tempname(), { { attr = "checks" } })
    if result == nil then
      error("eval_outputs returned nil")
    end

    assert.are.equal("x86_64-linux", result.system)
    assert.are.equal(1, #result.outputs)
    assert.are.equal("checks", result.outputs[1].attr)
    assert.are.same({ "unit", "integration" }, result.outputs[1].names)
  end)

  it("applies the match filter to output names", function()
    stub_system("x86_64-linux", '["testFoo","integration","testBar"]')

    local result = eval.eval_outputs(vim.fn.tempname(), { { attr = "checks", match = "^test" } })
    if result == nil then
      error("eval_outputs returned nil")
    end

    assert.are.same({ "testFoo", "testBar" }, result.outputs[1].names)
  end)

  it("returns nil when the current system cannot be determined", function()
    local original = vim.system
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.system = function(_, _, callback)
      callback({ code = 1, stdout = "", stderr = "boom" })
      return {}
    end
    finally(function()
      vim.system = original
    end)

    assert.is_nil(eval.eval_outputs(vim.fn.tempname()))
  end)

  it("returns nil when the system probe cannot be spawned", function()
    local original = vim.system
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.system = function()
      error("ENOENT: nix")
    end
    finally(function()
      vim.system = original
    end)

    assert.is_nil(eval.eval_outputs(vim.fn.tempname()))
  end)
end)

describe("nix-unit flake detection", function()
  local eval = require("neotest-nix.eval")

  it("builds an expression that filters outputs by the suite's test names", function()
    local expr = eval.nix_unit_flake_expr({ "testFoo", "testBar" })

    -- names are embedded as JSON so nix-unit attribute names need no escaping
    assert.is_truthy(expr:find('["testFoo","testBar"]', 1, true))
    -- only outputs containing every nix-unit test attribute qualify, including
    -- outputs that nest tests under generated runtime namespaces.
    assert.is_truthy(expr:find("builtins.all", 1, true))
    assert.is_truthy(expr:find("containsName", 1, true))
    assert.is_truthy(expr:find("candidateName", 1, true))
    assert.is_truthy(expr:find('"tests" "libTests" "unitTests"', 1, true))
    assert.is_truthy(expr:find('builtins.match ".*[Tt]ests?"', 1, true))
    assert.is_truthy(expr:find("hasDirectAll", 1, true))
    assert.is_truthy(expr:find("hasNestedAll", 1, true))
    assert.is_truthy(expr:find('builtins.hasAttr "expectedError"', 1, true))
    assert.is_truthy(expr:find("isDerivation", 1, true))
    assert.is_truthy(expr:find("builtins.getFlake", 1, true))
    assert.is_nil(expr:find("ignoredOutputs", 1, true))
  end)

  it("caches detected outputs by root and suite names", function()
    local original_system = vim.system
    local calls = 0
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.system = function(_, _, callback)
      calls = calls + 1
      callback({ code = 0, stdout = '["tests"]', stderr = "" })
      return {}
    end

    local root = vim.fn.tempname()
    local names = { "testCacheHit" }
    local first = eval.detect_nix_unit_flake(root, names)
    local second = eval.detect_nix_unit_flake(root, names)

    vim.system = original_system

    assert.are.equal(".#tests", first)
    assert.are.equal(".#tests", second)
    assert.are.equal(1, calls)
  end)

  it("returns nil when flake detection cannot spawn nix", function()
    local original_system = vim.system
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.system = function()
      error("ENOENT: nix")
    end
    finally(function()
      vim.system = original_system
    end)

    assert.is_nil(eval.detect_nix_unit_flake(vim.fn.tempname(), { "testMissingNix" }))
  end)
end)
