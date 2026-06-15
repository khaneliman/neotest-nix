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

local function multi_vm_tree(root)
  local file_path = vim.fs.joinpath(root, "flake.nix")
  return Tree:new({
    id = file_path,
    name = "flake.nix",
    path = file_path,
    type = "file",
  }, {
    Tree:new({
      attr_path = "checks.aarch64-linux.vmA",
      id = "vmA",
      name = "vmA",
      path = file_path,
      range = { 0, 0, 8, 0 },
      test_script_range = { 4, 19, 7, 6 },
      type = "test",
    }),
    Tree:new({
      attr_path = "checks.aarch64-linux.vmB",
      id = "vmB",
      name = "vmB",
      path = file_path,
      range = { 10, 0, 18, 0 },
      test_script_range = { 14, 19, 17, 6 },
      type = "test",
    }),
  })
end

local function multi_test_tree(root)
  local file_path = vim.fs.joinpath(root, "checks", "unit.nix")
  return Tree:new({
    id = vim.fs.joinpath(root, "flake.nix"),
    name = "flake.nix",
    path = vim.fs.joinpath(root, "flake.nix"),
    type = "file",
  }, {
    Tree:new({
      id = "first",
      name = "first",
      path = file_path,
      range = { 0, 0, 1, 0 },
      type = "test",
    }),
    Tree:new({
      id = "second",
      name = "second",
      path = file_path,
      range = { 2, 0, 3, 0 },
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

  it("marks a nix-eval run with an empty failure list as passed", function()
    local root = project()
    local position_tree = tree(root)
    local parsed = results.results(
      run_spec(root, { runner = "nix-eval" }),
      { code = 0, output = output_file({ "[ ]" }) },
      position_tree
    )

    assert.are.equal("passed", parsed[position_tree:data().id].status)
  end)

  it("ignores eval warnings before the result list", function()
    local root = project()
    local position_tree = tree(root)
    local parsed = results.results(run_spec(root, { runner = "nix-eval" }), {
      code = 0,
      output = output_file({
        "evaluation warning: lib.foo is deprecated",
        "[ ]",
      }),
    }, position_tree)

    assert.are.equal("passed", parsed[position_tree:data().id].status)
  end)

  it("marks a nix-eval run with failures as failed and names them", function()
    local root = project()
    local position_tree = tree(root)
    local parsed = results.results(
      run_spec(root, { runner = "nix-eval" }),
      { code = 0, output = output_file({ '[{"name":"testFoo","expected":1,"result":2}]' }) },
      position_tree
    )

    local result = parsed[position_tree:data().id]
    assert.are.equal("failed", result.status)
    assert.is_truthy(result.short:find("testFoo", 1, true))
  end)

  it("maps nix-eval failure lists onto child test positions", function()
    local root = project()
    local path = vim.fs.joinpath(root, "lib", "tests", "misc.nix")
    local position_tree = Tree:new({
      id = path,
      name = "misc.nix",
      path = path,
      type = "file",
    }, {
      Tree:new({
        id = path .. "::tests::testPass",
        name = "testPass",
        path = path,
        type = "test",
      }),
      Tree:new({
        id = path .. "::tests::testFail",
        name = "testFail",
        path = path,
        type = "test",
      }),
    })
    local parsed = results.results(
      run_spec(root, { runner = "nix-eval" }),
      { code = 0, output = output_file({ '[{"name":"testFail","expected":1,"result":2}]' }) },
      position_tree
    )

    -- A passing test gets an explicit message rather than the bare `[]` output.
    assert.are.equal("passed", parsed[path .. "::tests::testPass"].status)
    assert.are.equal("testPass: passed", parsed[path .. "::tests::testPass"].short)
    assert.are.equal("failed", parsed[path .. "::tests::testFail"].status)
    -- The failure detail carries the expected/got values from lib.runTests.
    assert.are.equal(
      "testFail: expected 1, got 2",
      parsed[path .. "::tests::testFail"].errors[1].message
    )
    assert.are.equal("failed", parsed[path].status)
  end)

  it("summarizes an all-passing nix-eval file run instead of the bare list", function()
    local root = project()
    local path = vim.fs.joinpath(root, "lib", "tests", "fetchers.nix")
    local position_tree = Tree:new({
      id = path,
      name = "fetchers.nix",
      path = path,
      type = "file",
    }, {
      Tree:new({
        id = path .. "::tests::testOne",
        name = "testOne",
        path = path,
        type = "test",
      }),
      Tree:new({
        id = path .. "::tests::testTwo",
        name = "testTwo",
        path = path,
        type = "test",
      }),
    })
    -- lib.runTests emits `[]` on success; the file node should say so plainly.
    local parsed = results.results(
      run_spec(root, { runner = "nix-eval" }),
      { code = 0, output = output_file({ "[ ]" }) },
      position_tree
    )

    assert.are.equal("passed", parsed[path].status)
    assert.are.equal("all 2 tests passed", parsed[path].short)
    assert.are.equal("testOne: passed", parsed[path .. "::tests::testOne"].short)
  end)

  it("trims the nix-eval output so the result is the last visible line", function()
    local root = project()
    local position_tree = tree(root)
    local parsed = results.results(run_spec(root, { runner = "nix-eval" }), {
      code = 0,
      -- nix-instantiate prints warnings, the list, then a trailing newline.
      output = output_file({
        "evaluation warning: lib.foo is deprecated",
        "[ ]",
        "",
        "",
      }),
    }, position_tree)

    local result = parsed[position_tree:data().id]
    assert.is_truthy(result.output)
    local body = table.concat(vim.fn.readfile(result.output), "\n")
    -- No trailing blank line; the box's last line carries the eval result.
    assert.are.equal("[ ]", body:match("([^\n]*)$"))
    assert.is_nil(body:match("\n%s*$"))
  end)

  it("keeps nix-eval failure detail for a targeted test run", function()
    local root = project()
    local path = vim.fs.joinpath(root, "lib", "tests", "misc.nix")
    local position_tree = Tree:new({
      id = path .. "::tests::testFail",
      name = "testFail",
      path = path,
      type = "test",
    })
    local parsed = results.results(
      run_spec(root, { runner = "nix-eval", pos_id = path .. "::tests::testFail", type = "test" }),
      { code = 0, output = output_file({ '[{"name":"testFail","expected":1,"result":2}]' }) },
      position_tree
    )

    local result = parsed[path .. "::tests::testFail"]
    assert.are.equal("failed", result.status)
    assert.are.equal("testFail: expected 1, got 2", result.errors[1].message)
  end)

  it("marks a nix-eval run that errored as failed", function()
    local root = project()
    local position_tree = tree(root)
    local parsed = results.results(
      run_spec(root, { runner = "nix-eval" }),
      { code = 1, output = output_file({ "error: attribute 'tests' missing" }) },
      position_tree
    )

    assert.are.equal("failed", parsed[position_tree:data().id].status)
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

  it("distributes errors across tests on a whole-file run", function()
    local root = project()
    local position_tree = multi_test_tree(root)
    local parsed = results.results(
      run_spec(root, {
        pos_id = position_tree:data().id,
        type = "file",
      }),
      {
        code = 1,
        output = output_file({
          "error: assertion failed",
          "       at /nix/store/abc123-source/checks/unit.nix:1:1:",
          "       at /nix/store/abc123-source/checks/unit.nix:3:1:",
        }),
      },
      position_tree
    )

    assert.are.equal("failed", parsed.first.status)
    assert.are.equal(0, parsed.first.errors[1].line)
    assert.are.equal("failed", parsed.second.status)
    assert.are.equal(2, parsed.second.errors[1].line)
    assert.is_nil(parsed[position_tree:data().id])
  end)

  it("attributes each distinct error to its own location", function()
    local root = project()
    local position_tree = multi_test_tree(root)
    local parsed = results.results(
      run_spec(root, {
        pos_id = position_tree:data().id,
        type = "file",
      }),
      {
        code = 1,
        output = output_file({
          "error: first assertion failed",
          "       at /nix/store/abc123-source/checks/unit.nix:1:1:",
          "error: second assertion failed",
          "       at /nix/store/abc123-source/checks/unit.nix:3:1:",
        }),
      },
      position_tree
    )

    assert.are.equal("first assertion failed", parsed.first.errors[1].message)
    assert.are.equal(0, parsed.first.errors[1].line)
    assert.are.equal("second assertion failed", parsed.second.errors[1].message)
    assert.are.equal(2, parsed.second.errors[1].line)
  end)

  it("uses targeted run context when assigning errors", function()
    local root = project()
    local position_tree = tree(root)
    local parsed = results.results(
      run_spec(root, {
        pos_id = "unit",
        type = "test",
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

  it("falls back to a root failure on empty output", function()
    local root = project()
    local position_tree = tree(root)
    local parsed = results.results(run_spec(root), {
      code = 1,
      output = output_file({}),
    }, position_tree)

    assert.are.equal("failed", parsed[position_tree:data().id].status)
    assert.are.equal("Nix command failed", parsed[position_tree:data().id].short)
  end)

  it("does not treat a missing output path as command output", function()
    local root = project()
    local position_tree = tree(root)
    local missing_path = vim.fs.joinpath(root, "missing-output")
    local parsed = results.results(run_spec(root), {
      code = 1,
      output = missing_path,
    }, position_tree)

    assert.are.equal("failed", parsed[position_tree:data().id].status)
    assert.are.equal("Nix command failed", parsed[position_tree:data().id].short)
  end)

  it("skips whitespace-only error lines when choosing a message", function()
    local root = project()
    local position_tree = tree(root)
    local parsed = results.results(run_spec(root), {
      code = 1,
      output = output_file({
        "error:   ",
        "error: the real cause",
      }),
    }, position_tree)

    assert.are.equal("the real cause", parsed[position_tree:data().id].short)
  end)

  it("skips empty error lines and trims messages when assigning locations", function()
    local root = project()
    local errors = results.parse_errors(
      table.concat({
        "error:   ",
        "error:   assertion failed   ",
        "       at /nix/store/abc123-source/checks/unit.nix:2:3:",
      }, "\n"),
      root
    )

    assert.are.equal("assertion failed", errors[1].message)
  end)

  it("ignores malformed error frames without a usable location", function()
    local root = project()
    local errors = results.parse_errors(
      table.concat({
        "error: boom",
        "       at not-a-real-frame",
        "       at /tmp:::",
      }, "\n"),
      root
    )

    assert.are.same({}, errors)
  end)

  it("drops store frames that do not reconstruct to a local file", function()
    local root = project()
    local errors = results.parse_errors(
      table.concat({
        "error: boom",
        "       at /nix/store/abc123-source/checks/missing.nix:1:1:",
      }, "\n"),
      root
    )

    assert.are.same({}, errors)
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

  it("attributes a VM traceback only to the targeted test", function()
    local root = project()
    local position_tree = multi_vm_tree(root)
    local parsed = results.results(run_spec(root, { pos_id = "vmB" }), {
      code = 1,
      output = output_file({
        "Traceback (most recent call last):",
        '  File "/nix/store/hash-source/test-script.py", line 2, in <module>',
        '    machine.succeed("false")',
        "AssertionError: command failed",
      }),
    }, position_tree)

    assert.is_nil(parsed.vmA)
    assert.are.equal("failed", parsed.vmB.status)
    assert.are.equal("AssertionError: command failed", parsed.vmB.errors[1].message)
  end)

  it("does not blame every VM test for an unattributable traceback", function()
    local root = project()
    local position_tree = multi_vm_tree(root)
    local parsed = results.results(run_spec(root), {
      code = 1,
      output = output_file({
        "Traceback (most recent call last):",
        '  File "/nix/store/hash-source/test-script.py", line 2, in <module>',
        '    machine.succeed("false")',
        "AssertionError: command failed",
      }),
    }, position_tree)

    assert.is_nil(parsed.vmA)
    assert.is_nil(parsed.vmB)
    assert.are.equal("failed", parsed[position_tree:data().id].status)
  end)

  it("streams Nix diagnostics as soon as source locations are available", function()
    local root = project()
    local position_tree = tree(root)
    local chunks = {
      "error: assertion failed\n       at /nix/store/abc123-source/checks/",
      "unit.nix:2:3:",
    }
    local index = 0
    local stream = results.stream(run_spec(root), position_tree)(function()
      index = index + 1
      return chunks[index]
    end)

    local parsed = stream()

    if parsed == nil or parsed.unit == nil or parsed.unit.errors == nil then
      error("missing streamed unit result")
    end

    local unit = parsed.unit
    assert.are.equal("failed", unit.status)
    assert.are.equal(
      "error: assertion failed\n       at "
        .. vim.fs.joinpath(root, "checks", "unit.nix")
        .. ":2:3:",
      unit.short
    )
    assert.are.same({
      message = "assertion failed",
      line = 1,
      column = 2,
      severity = vim.diagnostic.severity.ERROR,
    }, unit.errors[1])
    assert.is_nil(stream())
  end)

  it("streams VM traceback diagnostics as soon as tracebacks are available", function()
    local root = project()
    local position_tree = vm_tree(root)
    local lines = {
      "Traceback (most recent call last):",
      '  File "/nix/store/hash-source/test-script.py", line 2, in <module>',
      '    machine.succeed("false")',
      "AssertionError: command failed",
    }
    local index = 0
    local stream = results.stream(run_spec(root), position_tree)(function()
      index = index + 1
      return index == 1 and table.concat(lines, "\n") or nil
    end)

    local parsed = stream()

    if parsed == nil or parsed.vm == nil or parsed.vm.errors == nil then
      error("missing streamed vm result")
    end

    local vm_result = parsed.vm
    assert.are.equal("failed", vm_result.status)
    assert.are.equal(table.concat(lines, "\n"), vm_result.short)
    assert.are.same({
      message = "AssertionError: command failed",
      line = 6,
      column = 0,
      severity = vim.diagnostic.severity.ERROR,
    }, vm_result.errors[1])
    assert.is_nil(stream())
  end)
end)

describe("nix-unit results", function()
  local function unit_tree(root)
    local file_path = vim.fs.joinpath(root, "lib", "tests", "default.nix")
    local function leaf(name)
      return Tree:new({
        id = name,
        name = name,
        path = file_path,
        range = { 0, 0, 3, 0 },
        type = "test",
      })
    end

    return Tree:new({
      id = file_path,
      name = "default.nix",
      path = file_path,
      type = "file",
    }, { leaf("testPass"), leaf("testFail"), leaf("testFailEval") })
  end

  -- Mirrors the per-attribute output documented by nix-unit.
  local sample = {
    "\226\157\140 testFail",
    "{ x = 1; } != { y = 1; }",
    "",
    "\226\152\162\239\184\143 testFailEval",
    "error:",
    "       … while calling the 'throw' builtin",
    "",
    "       error: NO U",
    "",
    "\226\156\133 testPass",
    "",
    "\240\159\152\162 1/3 successful",
    "error: Tests failed",
  }

  it("parses each attribute's status and detail", function()
    local entries = results.parse_nix_unit(table.concat(sample, "\n"))

    local by_name = {}
    for _, entry in ipairs(entries) do
      by_name[entry.name] = entry
    end

    assert.are.equal("passed", by_name.testPass.status)
    assert.are.equal("failed", by_name.testFail.status)
    assert.are.equal("failed", by_name.testFailEval.status)
    assert.are.equal("{ x = 1; } != { y = 1; }", by_name.testFail.message)
    -- the eval-error block is captured whole, blank lines and all
    assert.is_truthy(by_name.testFailEval.message:match("error: NO U"))
  end)

  it("strips ANSI escapes before parsing markers and summaries", function()
    local entries = results.parse_nix_unit(table.concat({
      "\27[32m\226\156\133 testPass\27[0m",
      "\226\157\140 \27[31mtestFail\27[0m",
      "\27[31m1 != 2\27[0m",
      "\27[31m\240\159\152\162 1/2 successful\27[0m",
    }, "\n"))

    assert.are.equal(2, #entries)
    assert.are.equal("testPass", entries[1].name)
    assert.are.equal("passed", entries[1].status)
    assert.are.equal("testFail", entries[2].name)
    assert.are.equal("failed", entries[2].status)
    assert.are.equal("1 != 2", entries[2].message)
  end)

  it("keeps full nix-unit marker names with runtime separators", function()
    local entries = results.parse_nix_unit(table.concat({
      "\226\157\140 systems:x/test+name with space",
      "boom",
      "\240\159\152\162 0/1 successful",
    }, "\n"))

    assert.are.equal(1, #entries)
    assert.are.equal("systems:x/test+name with space", entries[1].name)
  end)

  it("treats a summary line with spacing drift as a summary, not detail", function()
    local entries = results.parse_nix_unit(table.concat({
      "\226\156\133 testA",
      "\240\159\142\137 2/2  successful",
    }, "\n"))

    assert.are.equal(1, #entries)
    assert.are.equal("testA", entries[1].name)
    -- The summary line must flush, not append to testA's message.
    assert.are.equal("", entries[1].message)
  end)

  it("skips a status marker that carries no attribute name", function()
    local entries = results.parse_nix_unit(table.concat({
      "\226\157\140",
      "  orphan detail",
      "\226\156\133 testPass",
      "\240\159\152\162 1/2 successful",
    }, "\n"))

    assert.are.equal(1, #entries)
    assert.are.equal("testPass", entries[1].name)
    assert.are.equal("passed", entries[1].status)
  end)

  it("keeps embedded summary-looking text inside attribute detail", function()
    local entries = results.parse_nix_unit(table.concat({
      "\226\157\140 testA",
      "nested error: Tests failed downstream",
      "\240\159\152\162 0/1 successful",
    }, "\n"))

    assert.are.equal("nested error: Tests failed downstream", entries[1].message)
  end)

  it("keeps ratio-like detail lines inside attribute output", function()
    local entries = results.parse_nix_unit(table.concat({
      "\226\157\140 testA",
      "retry batch 2/3 successful",
      "",
      "\240\159\152\162 3/3 successful",
    }, "\n"))

    assert.are.equal(1, #entries)
    assert.are.equal("retry batch 2/3 successful", entries[1].message)
  end)

  it("maps per-attribute results onto their positions", function()
    local root = project()
    local position_tree = unit_tree(root)
    local parsed = results.results(
      run_spec(root, { runner = "nix-unit" }),
      { code = 1, output = output_file(sample) },
      position_tree
    )

    assert.are.equal("passed", parsed.testPass.status)
    assert.are.equal("failed", parsed.testFail.status)
    assert.are.equal("failed", parsed.testFailEval.status)
    assert.are.equal("{ x = 1; } != { y = 1; }", parsed.testFail.errors[1].message)
    -- the suite node reflects the overall failure
    assert.are.equal("failed", parsed[position_tree:data().id].status)
  end)

  it("marks markerless successful nix-unit output at the root", function()
    local root = project()
    local position_tree = unit_tree(root)
    local parsed = results.results(run_spec(root, { runner = "nix-unit" }), {
      code = 0,
      output = output_file({ "no test markers emitted" }),
    }, position_tree)

    assert.are.equal("passed", parsed[position_tree:data().id].status)
    assert.are.equal("no test markers emitted", vim.trim(parsed[position_tree:data().id].short))
  end)

  it("preserves markerless nix-unit failures and local diagnostics", function()
    local root = project()
    local position_tree = tree(root)
    local parsed = results.results(run_spec(root, { runner = "nix-unit" }), {
      code = 1,
      output = output_file({
        "error: attribute 'foo' missing",
        "       at /nix/store/abc123-source/checks/unit.nix:2:3:",
        "          1| first",
        "          2| second",
        "           |   ^",
      }),
    }, position_tree)

    local root_result = parsed[position_tree:data().id]
    assert.are.equal("failed", root_result.status)
    assert.is_truthy(root_result.short:find("attribute 'foo' missing", 1, true))
    assert.is_truthy(root_result.short:find(vim.fs.joinpath(root, "checks", "unit.nix"), 1, true))
    assert.is_truthy(root_result.short:find("2| second", 1, true))
    assert.are.equal("failed", parsed.unit.status)
    assert.are.same({
      message = "attribute 'foo' missing",
      line = 1,
      column = 2,
      severity = vim.diagnostic.severity.ERROR,
    }, parsed.unit.errors[1])
  end)

  it("maps dotted nix-unit names onto nested positions by attr_path", function()
    local root = project()
    local file_path = vim.fs.joinpath(root, "flake.nix")
    local position_tree = Tree:new({
      id = file_path,
      name = "tests",
      path = file_path,
      type = "namespace",
    }, {
      Tree:new({
        attr_path = "tests.testTop",
        id = "tests.testTop",
        name = "testTop",
        path = file_path,
        range = { 0, 0, 0, 0 },
        type = "test",
      }),
      Tree:new({
        attr_path = "tests.nested.testInner",
        id = "tests.nested.testInner",
        name = "testInner",
        path = file_path,
        range = { 0, 0, 0, 0 },
        type = "test",
      }),
    })

    local parsed = results.results(run_spec(root, { runner = "nix-unit" }), {
      code = 1,
      output = output_file({
        "\226\157\140 nested.testInner",
        "1 != 2",
        "",
        "\226\156\133 testTop",
        "",
        "\240\159\152\162 1/2 successful",
      }),
    }, position_tree)

    assert.are.equal("passed", parsed["tests.testTop"].status)
    assert.are.equal("failed", parsed["tests.nested.testInner"].status)
  end)

  it("maps runtime-prefixed nix-unit names onto leaf positions", function()
    local root = project()
    local file_path = vim.fs.joinpath(root, "lib", "tests", "default.nix")
    local function leaf(name)
      return Tree:new({
        attr_path = "system-agnostic." .. name,
        id = name,
        name = name,
        path = file_path,
        range = { 0, 0, 0, 0 },
        type = "test",
      })
    end
    local position_tree = Tree:new({
      id = file_path,
      name = "default.nix",
      path = file_path,
      type = "file",
    }, { leaf("testDecodeHello"), leaf("testCapitalize") })

    -- nix-unit emits each leaf once per system; a failure under any system wins.
    local parsed = results.results(run_spec(root, { runner = "nix-unit" }), {
      code = 1,
      output = output_file({
        "\226\156\133 systems.aarch64-darwin.system-agnostic.testDecodeHello",
        "\226\156\133 systems.x86_64-linux.system-agnostic.testDecodeHello",
        "\226\156\133 systems.aarch64-darwin.system-agnostic.testCapitalize",
        "\226\157\140 systems.x86_64-linux.system-agnostic.testCapitalize",
        "1 != 2",
        "",
        "\240\159\152\162 3/4 successful",
      }),
    }, position_tree)

    assert.are.equal("passed", parsed.testDecodeHello.status)
    assert.are.equal("failed", parsed.testCapitalize.status)
  end)

  it("marks every attribute passed when the suite succeeds", function()
    local root = project()
    local position_tree = unit_tree(root)
    local parsed = results.results(run_spec(root, { runner = "nix-unit" }), {
      code = 0,
      output = output_file({
        "\226\156\133 testPass",
        "\226\156\133 testFail",
        "\226\156\133 testFailEval",
        "",
        "\240\159\142\137 3/3 successful",
      }),
    }, position_tree)

    assert.are.equal("passed", parsed.testPass.status)
    assert.are.equal("passed", parsed.testFail.status)
    assert.are.equal("passed", parsed[position_tree:data().id].status)
  end)
end)
