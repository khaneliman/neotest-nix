local spec = require("neotest-nix.spec")
local eval = require("neotest-nix.eval")

local Tree = {}
Tree.__index = Tree

function Tree:new(data, parent, children)
  return setmetatable({
    _data = data,
    _parent = parent,
    _children = children or {},
  }, self)
end

function Tree:data()
  return self._data
end

function Tree:parent()
  return self._parent
end

function Tree:iter()
  local nodes = { self._data }
  for _, child in ipairs(self._children) do
    table.insert(nodes, child._data)
  end

  local index = 0
  return function()
    index = index + 1
    if nodes[index] == nil then
      return nil
    end
    return index, nodes[index]
  end
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

  it("keeps flake.nix file runs on flake check when the flake mentions runTests", function()
    local root = project()
    local path = vim.fs.joinpath(root, "flake.nix")
    vim.fn.writefile({
      "{ outputs = { self }: { tests = lib.runTests { }; }; }",
    }, path)
    local tree = node({
      id = "file",
      name = "flake.nix",
      path = path,
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

  it("runs a flake nix-unit namespace via nix-unit --flake", function()
    local root = project()
    local file = node({
      id = "file",
      name = "flake.nix",
      path = vim.fs.joinpath(root, "flake.nix"),
      type = "file",
    })
    local tests = Tree:new(
      {
        id = "tests",
        name = "tests",
        path = file:data().path,
        type = "namespace",
      },
      file,
      {
        Tree:new({
          attr_path = "tests.testPass",
          id = "tests.testPass",
          name = "testPass",
          nix_unit_kind = "flake",
          path = file:data().path,
          runner = "nix-unit",
          type = "test",
        }),
        Tree:new({
          attr_path = "tests.testOther",
          id = "tests.testOther",
          name = "testOther",
          nix_unit_kind = "flake",
          path = file:data().path,
          runner = "nix-unit",
          type = "test",
        }),
      }
    )

    local run = build_spec({ tree = tests })

    assert.same({
      "nix-unit",
      "--extra-experimental-features",
      "flakes",
      "--flake",
      ".#tests",
    }, run.command)
    assert.are.equal(".#tests", run.context.attr)
    assert.are.equal("nix-unit", run.context.runner)
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

  it("quotes nix-unit attr segments that are not identifiers", function()
    local root = project()
    local test = node({
      attr_path = "tests.test with spaces",
      attr_path_parts = { "tests", "test with spaces" },
      id = "test with spaces",
      name = "test with spaces",
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
      '{ "test with spaces" = (builtins.getFlake (toString ./. )).tests.${"test with spaces"}; }',
    }, run.command)
  end)

  it("preserves dots inside structured nix-unit attr segments", function()
    local root = project()
    local test = node({
      attr_path = "tests.1.0",
      attr_path_parts = { "tests", "1.0" },
      id = "1.0",
      name = "1.0",
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
      '{ "1.0" = (builtins.getFlake (toString ./. )).tests.${"1.0"}; }',
    }, run.command)
  end)

  it("quotes flake check installable attr segments", function()
    local root = project()
    local test = node({
      attr_path = "checks.x86_64-linux.integration test",
      attr_path_parts = { "checks", "x86_64-linux", "integration test" },
      id = "integration test",
      name = "integration test",
      path = vim.fs.joinpath(root, "flake.nix"),
      runner = "nix",
      type = "test",
    })

    local run = build_spec({ tree = test })

    assert.same({
      "nix",
      "build",
      "--extra-experimental-features",
      "nix-command flakes",
      "--keep-going",
      "--no-write-lock-file",
      '.#checks.x86_64-linux."integration test"',
    }, run.command)
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
      ("{ testNested = (import (builtins.path { path = %s; })).nested.testNested; }"):format(
        vim.json.encode(path)
      ),
    }, run.command)
    assert.are.equal("nested.testNested", run.context.attr)
  end)

  it("quotes bare-attrset nix-unit paths with spaces", function()
    local root = project()
    local dir = vim.fs.joinpath(root, "path with spaces")
    vim.fn.mkdir(dir, "p")
    local path = vim.fs.joinpath(dir, "tests.nix")
    local test = node({
      attr_path = "testSpacedPath",
      id = "testSpacedPath",
      name = "testSpacedPath",
      nix_unit_kind = "import",
      path = path,
      runner = "nix-unit",
      type = "test",
    })

    local run = build_spec({ tree = test })

    assert.are.equal(
      ("{ testSpacedPath = (import (builtins.path { path = %s; })).testSpacedPath; }"):format(
        vim.json.encode(path)
      ),
      run.command[5]
    )
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
    -- A single wrapped test selects just its leaf out of the suite via --expr,
    -- since nix-unit --flake cannot filter to one attribute.
    assert.are.equal("nix-unit", run.command[1])
    assert.are.equal("--expr", run.command[4])
    local expr = run.command[5]
    assert.is_truthy(expr:find("builtins.getFlake", 1, true))
    assert.is_truthy(expr:find([=[[\"tests\"]]=], 1, true))
    assert.is_truthy(expr:find([[\"testWrapped\"]], 1, true))
    assert.is_truthy(expr:find("builtins.listToAttrs matches", 1, true))
    assert.is_nil(expr:find("builtins.head", 1, true))
    assert.are.equal(".#tests", run.context.attr)
    assert.are.equal("nix-unit", run.context.runner)
    -- nix-unit results are parsed in full at the end, so no incremental stream.
    assert.is_nil(run.stream)
  end)

  it("escapes nix string syntax in single-test select expressions", function()
    local root = project()
    local path = vim.fs.joinpath(root, "lib", "tests", "default.nix")
    local opts = { nix_unit_flakes = { { path = "lib/tests", flake = ".#tests" } } }
    ---@type any
    local run_args = {
      tree = node({
        id = "test''${evil}",
        name = "test''${evil}",
        nix_unit_kind = nil,
        path = path,
        runner = "nix-unit",
        type = "test",
      }),
    }

    ---@type any
    local run = spec.build_spec(run_args, opts)

    assert.is_not_nil(run)
    -- The leaf name is spliced as an escaped Nix string literal: `${` must not
    -- interpolate and `''` must not terminate the expression's strings.
    assert.is_truthy(
      run.command[5]:find([[name = builtins.fromJSON "\"test''\${evil}\"";]], 1, true)
    )
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
    assert.are.equal("--expr", run.command[4])
    assert.is_truthy(run.command[5]:find([[\"testWrapped\"]], 1, true))
    assert.are.equal(".#tests", run.context.attr)
    assert.are.same({ "testWrapped" }, seen_names)
  end)

  it("runs nixpkgs passthru tests via legacy nix-build", function()
    local root = project()
    local path = vim.fs.joinpath(root, "pkgs", "by-name", "he", "hello", "package.nix")
    local test = node({
      id = path .. "::tests::simple",
      name = "simple",
      path = path,
      type = "test",
      runner = "nix",
      nixpkgs_attr = "hello.tests.simple",
    })

    local run = build_spec({ tree = test })

    assert.same({ "nix-build", "-A", "hello.tests.simple", "--no-out-link" }, run.command)
    assert.are.equal("hello.tests.simple", run.context.attr)
    assert.are.equal("nix", run.context.runner)
    assert.are.equal(root, run.cwd)
    -- nix-build output streams through the shared nix error scanner.
    assert.is_function(run.stream)
  end)

  it("resolves dynamic system placeholders when building checks", function()
    local current_system = eval.current_system
    eval.current_system = function()
      return "x86_64-linux"
    end

    local root = project()
    local test = node({
      attr_path = "checks.<system>.unit",
      dynamic_system = true,
      id = "unit",
      name = "unit",
      path = vim.fs.joinpath(root, "flake.nix"),
      runner = "nix",
      type = "test",
    })

    local ok, run = pcall(function()
      return build_spec({ tree = test })
    end)
    eval.current_system = current_system
    if not ok then
      error(run)
    end

    assert.same({
      "nix",
      "build",
      "--extra-experimental-features",
      "nix-command flakes",
      "--keep-going",
      "--no-write-lock-file",
      ".#checks.x86_64-linux.unit",
    }, run.command)
    assert.are.equal("checks.x86_64-linux.unit", run.context.attr)
  end)

  it("builds nix-build for a lib release file position", function()
    local root = project()
    local path = vim.fs.joinpath(root, "lib", "tests", "release.nix")
    local run = build_spec({
      tree = node({
        id = path,
        name = "release.nix",
        path = path,
        type = "file",
        runner = "nix",
        nixpkgs_file_build = "lib/tests/release.nix",
      }),
    })

    assert.same({ "nix-build", "lib/tests/release.nix", "--no-out-link" }, run.command)
    assert.are.equal("nix", run.context.runner)
    assert.is_function(run.stream)
  end)

  it("builds nix-instantiate for a lib misc eval position", function()
    local root = project()
    local path = vim.fs.joinpath(root, "lib", "tests", "misc.nix")
    local run = build_spec({
      tree = node({
        id = path,
        name = "misc.nix",
        path = path,
        type = "file",
        runner = "nix-eval",
        nixpkgs_file_eval = "lib/tests/misc.nix",
      }),
    })

    assert.same(
      { "nix-instantiate", "--eval", "--strict", "--json", "lib/tests/misc.nix" },
      run.command
    )
    assert.are.equal("nix-eval", run.context.runner)
    -- eval output is parsed in full at the end, so no incremental stream.
    assert.is_nil(run.stream)
  end)

  it("builds filtered nix-instantiate for a lib eval test position", function()
    local root = project()
    local path = vim.fs.joinpath(root, "lib", "tests", "misc.nix")
    local run = build_spec({
      tree = node({
        id = path .. "::tests::testAlpha",
        name = "testAlpha",
        path = path,
        type = "test",
        runner = "nix-eval",
        nixpkgs_file_eval = "lib/tests/misc.nix",
        nixpkgs_eval_test = "testAlpha",
      }),
    })

    assert.are.equal("nix-instantiate", run.command[1])
    assert.are.equal("--expr", run.command[5])
    assert.is_truthy(run.command[6]:find("import ./lib/tests/misc.nix", 1, true))
    assert.is_truthy(run.command[6]:find("builtins.filter", 1, true))
    assert.is_truthy(run.command[6]:find("testAlpha", 1, true))
    assert.are.equal("lib/tests/misc.nix", run.context.attr)
    assert.are.equal("nix-eval", run.context.runner)
    assert.are.equal(path .. "::tests::testAlpha", run.context.pos_id)
    assert.is_nil(run.stream)
  end)

  it("builds nix-build -A nixosTests for a nixos test position", function()
    local root = project()
    local path = vim.fs.joinpath(root, "nixos", "tests", "login.nix")
    local run = build_spec({
      tree = node({
        id = path,
        name = "login.nix",
        path = path,
        type = "file",
        runner = "nix",
        nixpkgs_attr = "nixosTests.login",
      }),
    })

    assert.same({ "nix-build", "-A", "nixosTests.login", "--no-out-link" }, run.command)
    assert.are.equal("nixosTests.login", run.context.attr)
    assert.are.equal("nix", run.context.runner)
  end)

  it("honours a named strategy by omitting the custom one", function()
    local root = project()
    local test = node({
      attr_path = "checks.x86_64-linux.unit",
      attr_path_parts = { "checks", "x86_64-linux", "unit" },
      id = "unit",
      name = "unit",
      path = vim.fs.joinpath(root, "flake.nix"),
      runner = "nix",
      type = "test",
    })

    ---@type any
    local run_args = { tree = test, strategy = "dap" }
    local run = spec.build_spec(run_args)

    assert.is_not_nil(run)
    ---@cast run neotest.RunSpec
    assert.is_nil(run.strategy)
    -- Everything else about the spec (command, streaming) is unaffected by
    -- which strategy will actually run it.
    assert.is_function(run.stream)
  end)

  it("attaches the custom strategy when no strategy is named", function()
    local root = project()
    local test = node({
      attr_path = "checks.x86_64-linux.unit",
      attr_path_parts = { "checks", "x86_64-linux", "unit" },
      id = "unit",
      name = "unit",
      path = vim.fs.joinpath(root, "flake.nix"),
      runner = "nix",
      type = "test",
    })

    local run = build_spec({ tree = test })

    assert.is_function(run.strategy)
  end)

  it(
    "builds the driverInteractive command for a VM-test check when vm_interactive is enabled",
    function()
      local root = project()
      local test = node({
        attr_path = "checks.x86_64-linux.vmTest",
        attr_path_parts = { "checks", "x86_64-linux", "vmTest" },
        id = "vmTest",
        name = "vmTest",
        path = vim.fs.joinpath(root, "flake.nix"),
        runner = "nix",
        test_script_range = { 1, 0, 5, 0 },
        type = "test",
      })

      ---@type any
      local run_args = { tree = test }
      local run = spec.build_spec(run_args, { vm_interactive = true })

      assert.is_not_nil(run)
      ---@cast run neotest.RunSpec
      assert.are.equal("sh", run.command[1])
      assert.are.equal("-c", run.command[2])
      local script = run.command[3]
      assert.is_truthy(script:find("nix", 1, true))
      assert.is_truthy(script:find("build", 1, true))
      assert.is_truthy(script:find(".#checks.x86_64-linux.vmTest.driverInteractive", 1, true))
      assert.is_truthy(script:find('exec "$out/bin/nixos-test-driver"', 1, true))
      -- The interactive session needs a real terminal, so no custom strategy
      -- (or streaming, which is for scanning build output) is attached.
      assert.is_nil(run.strategy)
      assert.is_nil(run.stream)
    end
  )

  it(
    "builds the driverInteractive command for a nixpkgs nixosTests position when vm_interactive is enabled",
    function()
      local root = project()
      local path = vim.fs.joinpath(root, "nixos", "tests", "login.nix")
      local test = node({
        id = path,
        name = "login.nix",
        path = path,
        runner = "nix",
        nixpkgs_attr = "nixosTests.login",
        test_script_range = { 1, 0, 5, 0 },
        type = "file",
      })

      ---@type any
      local run_args = { tree = test }
      local run = spec.build_spec(run_args, { vm_interactive = true })

      assert.is_not_nil(run)
      ---@cast run neotest.RunSpec
      assert.same({
        "sh",
        "-c",
        "out=$('nix-build' '-A' 'nixosTests.login.driverInteractive' '--no-out-link')"
          .. ' && exec "$out/bin/nixos-test-driver"',
      }, run.command)
      assert.is_nil(run.strategy)
      assert.is_nil(run.stream)
    end
  )

  it(
    "builds the normal command for a non-VM position even when vm_interactive is enabled",
    function()
      local root = project()
      local test = node({
        attr_path = "checks.x86_64-linux.unit",
        attr_path_parts = { "checks", "x86_64-linux", "unit" },
        id = "unit",
        name = "unit",
        path = vim.fs.joinpath(root, "flake.nix"),
        runner = "nix",
        type = "test",
      })

      ---@type any
      local run_args = { tree = test }
      local run = spec.build_spec(run_args, { vm_interactive = true })

      assert.is_not_nil(run)
      ---@cast run neotest.RunSpec
      assert.same({
        "nix",
        "build",
        "--extra-experimental-features",
        "nix-command flakes",
        "--keep-going",
        "--no-write-lock-file",
        ".#checks.x86_64-linux.unit",
      }, run.command)
      assert.is_function(run.strategy)
      assert.is_function(run.stream)
    end
  )

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
