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

    -- positions are keyed by id for results/build_spec lookup
    assert.is_not_nil(merged:get_key("checks.x86_64-linux.parseLix"))
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
      if position.attr_path == "checks.x86_64-linux.unit" then
        count = count + 1
      end
    end

    assert.are.equal(1, count)
    assert.is_not_nil(tests_by_attr(merged)["checks.x86_64-linux.extra"])
  end)

  it("returns the original tree when nothing new is discovered", function()
    local base = tree_with_literal_check()
    local merged = adapter._merge_eval_outputs(base, "x86_64-linux", checks({ "unit" }))

    assert.are.equal(base, merged)
  end)
end)
