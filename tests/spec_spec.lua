local spec = require("neotest-nix.spec")

local Tree = {}
Tree.__index = Tree

function Tree:new(data, parent)
  return setmetatable({
    _data = data,
    _parent = parent,
  }, self)
end

function Tree:data()
  return self._data
end

function Tree:parent()
  return self._parent
end

local function project()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  vim.fn.writefile({ "{}" }, vim.fs.joinpath(root, "flake.nix"))
  return root
end

local function node(data, parent)
  return Tree:new(data, parent)
end

local function build_spec(args)
  ---@type any
  local run_args = args
  local run = spec.build_spec(run_args)
  assert.is_not_nil(run)
  return run
end

describe("spec", function()
  it("builds a full flake check for file positions", function()
    local root = project()
    local tree = node({
      id = "file",
      name = "flake.nix",
      path = vim.fs.joinpath(root, "flake.nix"),
      type = "file",
    })

    local run = build_spec({ tree = tree })

    assert.same({
      "nix",
      "flake",
      "check",
      "--extra-experimental-features",
      "nix-command flakes",
      "--keep-going",
    }, run.command)
    assert.are.equal(root, run.cwd)
    assert.is_nil(run.context.attr)
    assert.is_function(run.strategy)
    assert.is_function(run.stream)
  end)

  it("builds a targeted check derivation for test positions", function()
    local root = project()
    local file = node({
      id = "file",
      name = "flake.nix",
      path = vim.fs.joinpath(root, "flake.nix"),
      type = "file",
    })
    local checks =
      node({ id = "checks", name = "checks", path = file:data().path, type = "namespace" }, file)
    local system = node({
      id = "system",
      name = "aarch64-darwin",
      path = file:data().path,
      type = "namespace",
    }, checks)
    local test =
      node({ id = "unit", name = "unit", path = file:data().path, type = "test" }, system)

    local run = build_spec({ tree = test, extra_args = { "--print-build-logs" } })

    assert.same({
      "nix",
      "build",
      "--extra-experimental-features",
      "nix-command flakes",
      "--keep-going",
      ".#checks.aarch64-darwin.unit",
      "--print-build-logs",
    }, run.command)
    assert.are.equal("checks.aarch64-darwin.unit", run.context.attr)
  end)

  it("builds a targeted nix-unit expression for nix-unit tests", function()
    local root = project()
    local test = node({
      attr_path = "tests.testPass",
      id = "testPass",
      name = "testPass",
      path = vim.fs.joinpath(root, "flake.nix"),
      runner = "nix-unit",
      type = "test",
    })

    local run = build_spec({ tree = test })

    assert.same({
      "nix-unit",
      "--extra-experimental-features",
      "flakes",
      "--expr",
      "{ testPass = (builtins.getFlake (toString ./. )).tests.testPass; }",
    }, run.command)
    assert.are.equal(root, run.cwd)
    assert.are.equal("tests.testPass", run.context.attr)
    assert.are.equal("nix-unit", run.context.runner)
  end)

  it("does not build specs for directory positions", function()
    ---@type any
    local run_args = {
      tree = node({
        id = "dir",
        name = "project",
        path = "/tmp/project",
        type = "dir",
      }),
    }
    assert.is_nil(spec.build_spec(run_args))
  end)
end)
