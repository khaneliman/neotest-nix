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
      "--no-write-lock-file",
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
      "--no-write-lock-file",
      ".#checks.aarch64-darwin.unit",
      "--print-build-logs",
    }, run.command)
    assert.are.equal("checks.aarch64-darwin.unit", run.context.attr)
  end)

  it("lets neotest break system namespaces down into child checks", function()
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
      name = "x86_64-linux",
      path = file:data().path,
      type = "namespace",
    }, checks)

    ---@type any
    local run_args = { tree = system }

    assert.is_nil(spec.build_spec(run_args))
  end)

  it("builds a targeted nix-unit expression for flake nix-unit tests", function()
    local root = project()
    local test = node({
      attr_path = "tests.testPass",
      id = "testPass",
      name = "testPass",
      nix_unit_kind = "flake",
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

  it("builds an import expression for bare-attrset nix-unit files", function()
    local root = project()
    local path = vim.fs.joinpath(root, "tests.nix")
    local test = node({
      attr_path = "nested.testNested",
      id = "testNested",
      name = "testNested",
      nix_unit_kind = "import",
      path = path,
      runner = "nix-unit",
      type = "test",
    })

    local run = build_spec({ tree = test })

    assert.same({
      "nix-unit",
      "--extra-experimental-features",
      "flakes",
      "--expr",
      ("{ testNested = (import %s).nested.testNested; }"):format(path),
    }, run.command)
    assert.are.equal("nested.testNested", run.context.attr)
  end)

  it("runs wrapped nix-unit tests via the configured flake installable", function()
    local root = project()
    local path = vim.fs.joinpath(root, "lib", "tests", "default.nix")
    local opts = { nix_unit_flakes = { { path = "lib/tests", flake = ".#tests" } } }
    ---@type any
    local run_args = {
      tree = node({
        attr_path = "testWrapped",
        id = "testWrapped",
        name = "testWrapped",
        nix_unit_kind = nil,
        path = path,
        runner = "nix-unit",
        type = "test",
      }),
    }

    ---@type any
    local run = spec.build_spec(run_args, opts)

    assert.is_not_nil(run)
    assert.same({
      "nix-unit",
      "--extra-experimental-features",
      "flakes",
      "--flake",
      ".#tests",
    }, run.command)
    assert.are.equal(".#tests", run.context.attr)
    assert.are.equal("nix-unit", run.context.runner)
    -- nix-unit results are parsed in full at the end, so no incremental stream.
    assert.is_nil(run.stream)
  end)

  it("runs a wrapped nix-unit file position via its flake installable", function()
    local root = project()
    local path = vim.fs.joinpath(root, "lib", "tests", "default.nix")
    local opts = { nix_unit_flakes = { { path = "lib/tests", flake = ".#tests" } } }
    ---@type any
    local run_args = {
      tree = node({
        id = "file",
        name = "default.nix",
        path = path,
        type = "file",
      }),
    }

    ---@type any
    local run = spec.build_spec(run_args, opts)

    assert.is_not_nil(run)
    assert.same({
      "nix-unit",
      "--extra-experimental-features",
      "flakes",
      "--flake",
      ".#tests",
    }, run.command)
    assert.are.equal("nix-unit", run.context.runner)
  end)

  it("warns when no flake output can be resolved for wrapped nix-unit tests", function()
    local root = project()
    local notify = vim.notify
    local notified = false
    vim.notify = function()
      notified = true
    end

    -- No config and auto-detect finds nothing: the suite is unrunnable.
    local eval_module = package.loaded["neotest-nix.eval"]
    package.loaded["neotest-nix.eval"] = {
      detect_nix_unit_flake = function()
        return nil
      end,
    }

    local ok, run = pcall(function()
      ---@type any
      local run_args = {
        tree = node({
          attr_path = "results.testWrapped",
          id = "testWrapped",
          name = "testWrapped",
          nix_unit_kind = nil,
          path = vim.fs.joinpath(root, "lib-tests.nix"),
          runner = "nix-unit",
          type = "test",
        }),
      }
      return spec.build_spec(run_args)
    end)

    package.loaded["neotest-nix.eval"] = eval_module
    vim.notify = notify

    assert.is_true(ok)
    assert.is_nil(run)
    assert.is_true(notified)
  end)

  it("auto-detects the flake output for wrapped nix-unit tests without config", function()
    local root = project()
    local eval_module = package.loaded["neotest-nix.eval"]
    local seen_names
    package.loaded["neotest-nix.eval"] = {
      detect_nix_unit_flake = function(_, names)
        seen_names = names
        return ".#tests"
      end,
    }

    ---@type any
    local run_args = {
      tree = node({
        attr_path = "testWrapped",
        id = "testWrapped",
        name = "testWrapped",
        nix_unit_kind = nil,
        path = vim.fs.joinpath(root, "lib", "tests", "default.nix"),
        runner = "nix-unit",
        type = "test",
      }),
    }
    ---@type any
    local run = spec.build_spec(run_args)

    package.loaded["neotest-nix.eval"] = eval_module

    assert.is_not_nil(run)
    assert.same({
      "nix-unit",
      "--extra-experimental-features",
      "flakes",
      "--flake",
      ".#tests",
    }, run.command)
    assert.are.equal(".#tests", run.context.attr)
    assert.are.same({ "testWrapped" }, seen_names)
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
