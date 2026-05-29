local results = require("neotest-nix.results")

local Tree = {}
Tree.__index = Tree

function Tree:new(data, children)
  local tree = setmetatable({
    _data = data,
    _children = children or {},
    _nodes = {},
  }, self)

  tree._nodes[data.id] = tree
  for _, child in ipairs(tree._children) do
    child._parent = tree
    for id, node in pairs(child._nodes) do
      tree._nodes[id] = node
    end
  end

  return tree
end

function Tree:data()
  return self._data
end

function Tree:parent()
  return self._parent
end

function Tree:get_key(key)
  return self._nodes[key]
end

function Tree:iter()
  local nodes = {}

  local function collect(node)
    table.insert(nodes, node)
    for _, child in ipairs(node._children) do
      collect(child)
    end
  end

  collect(self)

  local index = 0
  return function()
    index = index + 1
    local node = nodes[index]
    if node == nil then
      return nil
    end

    return index, node:data()
  end
end

local function project()
  local root = vim.fn.tempname()
  vim.fn.mkdir(vim.fs.joinpath(root, "checks"), "p")
  vim.fn.writefile(
    { "first", "second", "third", "fourth" },
    vim.fs.joinpath(root, "checks", "unit.nix")
  )
  vim.fn.writefile({ "{}" }, vim.fs.joinpath(root, "flake.nix"))
  return root
end

local function tree(root)
  local file_path = vim.fs.joinpath(root, "checks", "unit.nix")
  return Tree:new({
    id = vim.fs.joinpath(root, "flake.nix"),
    name = "flake.nix",
    path = vim.fs.joinpath(root, "flake.nix"),
    type = "file",
  }, {
    Tree:new({
      id = "unit",
      name = "unit",
      path = file_path,
      range = { 0, 0, 3, 0 },
      type = "test",
    }),
  })
end

local function vm_tree(root)
  local file_path = vim.fs.joinpath(root, "flake.nix")
  return Tree:new({
    id = file_path,
    name = "flake.nix",
    path = file_path,
    type = "file",
  }, {
    Tree:new({
      attr_path = "checks.aarch64-linux.vm",
      id = "vm",
      name = "vm",
      path = file_path,
      range = { 0, 0, 8, 0 },
      test_script_range = { 4, 19, 7, 6 },
      type = "test",
    }),
  })
end

local function output_file(lines)
  local path = vim.fn.tempname()
  vim.fn.writefile(lines, path)
  return path
end

local function run_spec(root, context)
  return {
    command = { "nix", "flake", "check" },
    context = context or {},
    cwd = root,
  }
end

describe("results", function()
  it("marks successful runs as passed", function()
    local root = project()
    local position_tree = tree(root)
    local parsed =
      results.results(run_spec(root), { code = 0, output = output_file({ "ok" }) }, position_tree)

    assert.are.equal("passed", parsed[position_tree:data().id].status)
  end)

  it("parses nix errors with translated local diagnostics", function()
    local root = project()
    local position_tree = tree(root)
    local parsed = results.results(run_spec(root), {
      code = 1,
      output = output_file({
        "error: assertion failed",
        "       at /nix/store/abc123-source/checks/unit.nix:2:3:",
        "          1| first",
        "          2| second",
        "           |   ^",
      }),
    }, position_tree)

    assert.are.equal("failed", parsed.unit.status)
    assert.are.same({
      message = "assertion failed",
      line = 1,
      column = 2,
      severity = vim.diagnostic.severity.ERROR,
    }, parsed.unit.errors[1])
  end)

  it("uses targeted run context when assigning errors", function()
    local root = project()
    local position_tree = tree(root)
    local parsed = results.results(
      run_spec(root, {
        pos_id = "unit",
      }),
      {
        code = 1,
        output = output_file({
          "error: assertion failed",
          "       at /nix/store/abc123-source/checks/unit.nix:4:1:",
        }),
      },
      position_tree
    )

    assert.are.equal("failed", parsed.unit.status)
    assert.are.equal(3, parsed.unit.errors[1].line)
  end)

  it("ignores internal nix store frames that do not map to local files", function()
    local root = project()
    local position_tree = tree(root)
    local parsed = results.results(run_spec(root), {
      code = 1,
      output = output_file({
        "error: assertion failed",
        "       at /nix/store/abc123-source/checks/unit.nix:2:3:",
        "       at /nix/store/hash-nixpkgs/lib/modules.nix:10:5:",
      }),
    }, position_tree)

    assert.are.equal(1, #parsed.unit.errors)
    assert.are.equal(1, parsed.unit.errors[1].line)
  end)

  it("returns a root failure when no diagnostic location is available", function()
    local root = project()
    local position_tree = tree(root)
    local parsed = results.results(run_spec(root), {
      code = 1,
      output = output_file({
        "error: command failed without source location",
      }),
    }, position_tree)

    assert.are.equal("failed", parsed[position_tree:data().id].status)
    assert.are.equal(
      "command failed without source location",
      parsed[position_tree:data().id].short
    )
  end)

  it("maps Python tracebacks into NixOS VM test scripts", function()
    local root = project()
    local position_tree = vm_tree(root)
    local parsed = results.results(run_spec(root), {
      code = 1,
      output = output_file({
        "machine: booted",
        "Traceback (most recent call last):",
        '  File "/nix/store/hash-source/test-script.py", line 2, in <module>',
        '    machine.succeed("false")',
        "AssertionError: command failed",
      }),
    }, position_tree)

    assert.are.equal("failed", parsed.vm.status)
    assert.are.same({
      message = "AssertionError: command failed",
      line = 6,
      column = 0,
      severity = vim.diagnostic.severity.ERROR,
    }, parsed.vm.errors[1])
  end)
end)
