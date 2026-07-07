local runtests = require("neotest-nix.runtests")
local eval = require("neotest-nix.eval")
local results = require("neotest-nix.results")

local fixtures = vim.fs.joinpath(vim.fn.getcwd(), "tests", "fixtures")
local zero_arg_fixture = vim.fs.joinpath(fixtures, "runtests", "default.nix")
local function_fixture = vim.fs.joinpath(fixtures, "runtests-fn", "default.nix")

-- Minimal Tree double mirroring the one used by results_spec.lua / spec_spec.lua,
-- just enough for results.results()'s tree:data()/tree:iter() usage.
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

local function output_file(lines)
  local path = vim.fn.tempname()
  vim.fn.writefile(lines, path)
  return path
end

describe("runtests", function()
  describe("is_runtests_file", function()
    it("detects a bare runTests call", function()
      assert.is_true(
        runtests.is_runtests_file("runTests { testFoo = { expr = 1; expected = 1; }; }")
      )
    end)

    it("detects a qualified lib.runTests call", function()
      assert.is_true(runtests.is_runtests_file("lib.runTests (mkCases [ 1 2 3 ])"))
    end)

    it("reads content from a file path", function()
      assert.is_true(runtests.is_runtests_file(zero_arg_fixture))
      assert.is_true(runtests.is_runtests_file(function_fixture))
    end)

    it("respects word boundaries", function()
      assert.is_false(runtests.is_runtests_file("xrunTests { }"))
      assert.is_false(runtests.is_runtests_file("runTestsx { }"))
    end)

    it("ignores runTests mentioned in a comment or a string", function()
      assert.is_false(runtests.is_runtests_file("# lib.runTests { }"))
      assert.is_false(runtests.is_runtests_file('"lib.runTests { }"'))
      assert.is_false(runtests.is_runtests_file("/* lib.runTests { } */"))
    end)

    it("returns false for non-string input", function()
      -- Exercises the defensive non-string guard directly; real callers
      -- always pass a string, so this violates the declared param type on
      -- purpose.
      ---@diagnostic disable-next-line: param-type-mismatch
      assert.is_false(runtests.is_runtests_file(nil))
    end)
  end)

  describe("build_spec", function()
    it("builds a nix-instantiate command for a zero-arg file", function()
      -- build_spec only reads id/path/type; range/total_range are always set
      -- by real tree-sitter discovery but aren't needed by the code under test.
      ---@diagnostic disable-next-line: missing-fields
      local run = runtests.build_spec({
        id = zero_arg_fixture,
        name = "default.nix",
        path = zero_arg_fixture,
        type = "file",
      }, fixtures)

      assert.is_not_nil(run)
      ---@cast run neotest.RunSpec
      assert.same(
        { "nix-instantiate", "--eval", "--strict", "--json", zero_arg_fixture },
        run.command
      )
      assert.are.equal(fixtures, run.cwd)
      assert.is_function(run.strategy)
      assert.is_nil(run.stream)
      assert.are.equal("nix-eval", run.context.runner)
      assert.are.equal(zero_arg_fixture, run.context.path)
      assert.are.equal(zero_arg_fixture, run.context.pos_id)
      assert.are.equal("file", run.context.type)
    end)

    it("builds an impure nix eval command applying a defaulted function file", function()
      -- build_spec only reads id/path/type; range/total_range are always set
      -- by real tree-sitter discovery but aren't needed by the code under test.
      ---@diagnostic disable-next-line: missing-fields
      local run = runtests.build_spec({
        id = function_fixture,
        name = "default.nix",
        path = function_fixture,
        type = "file",
      }, fixtures)

      assert.is_not_nil(run)
      ---@cast run neotest.RunSpec
      assert.are.equal(8, #run.command)
      assert.same({
        "nix",
        "eval",
        "--impure",
        "--json",
        "--extra-experimental-features",
        "nix-command flakes",
        "--expr",
      }, {
        run.command[1],
        run.command[2],
        run.command[3],
        run.command[4],
        run.command[5],
        run.command[6],
        run.command[7],
      })

      local expr = run.command[8]
      assert.is_truthy(expr:find("builtins.path", 1, true))
      assert.is_truthy(expr:find(eval.nix_string_literal(function_fixture), 1, true))
      assert.is_truthy(expr:find("{ }", 1, true))
      assert.are.equal("nix-eval", run.context.runner)
    end)

    it("honours named neotest strategies by omitting the custom strategy", function()
      -- build_spec only reads id/path/type; range/total_range are always set
      -- by real tree-sitter discovery but aren't needed by the code under test.
      ---@diagnostic disable-next-line: missing-fields
      local run = runtests.build_spec({
        id = zero_arg_fixture,
        name = "default.nix",
        path = zero_arg_fixture,
        type = "file",
      }, fixtures, nil, nil, "dap")

      assert.is_not_nil(run)
      ---@cast run neotest.RunSpec
      assert.is_nil(run.strategy)
    end)

    it("appends extra args after the eval command", function()
      local run = runtests.build_spec(
        -- build_spec only reads id/path/type; name/range/total_range are
        -- always set by real tree-sitter discovery but aren't needed here.
        ---@diagnostic disable-next-line: missing-fields
        { id = "x", path = zero_arg_fixture, type = "file" },
        fixtures,
        {
          "--show-trace",
        }
      )

      assert.is_not_nil(run)
      ---@cast run neotest.RunSpec
      assert.are.equal("--show-trace", run.command[#run.command])
    end)

    it("returns nil when the file cannot be read", function()
      local missing = vim.fs.joinpath(fixtures, "runtests", "does-not-exist.nix")
      -- build_spec only reads id/path/type; name/range/total_range are
      -- always set by real tree-sitter discovery but aren't needed here.
      ---@diagnostic disable-next-line: missing-fields
      assert.is_nil(runtests.build_spec({ id = missing, path = missing, type = "file" }, fixtures))
    end)

    it("returns nil for a position without a path", function()
      -- Deliberately omits `path` to exercise the nil-path guard; a real
      -- position always has one.
      ---@diagnostic disable-next-line: missing-fields
      assert.is_nil(runtests.build_spec({ id = "x", type = "file" }, fixtures))
      -- Exercises the defensive nil-position guard directly; real callers
      -- always pass a position.
      ---@diagnostic disable-next-line: param-type-mismatch
      assert.is_nil(runtests.build_spec(nil, fixtures))
    end)
  end)

  describe("result mapping (reusing results.lua's nix-eval path)", function()
    it("maps a canned runTests failure list onto file/test positions", function()
      local tree = Tree:new({
        id = zero_arg_fixture,
        name = "default.nix",
        path = zero_arg_fixture,
        type = "file",
      }, {
        Tree:new({
          id = zero_arg_fixture .. "::tests::testPass",
          name = "testPass",
          path = zero_arg_fixture,
          type = "test",
        }),
        Tree:new({
          id = zero_arg_fixture .. "::tests::testFail",
          name = "testFail",
          path = zero_arg_fixture,
          type = "test",
        }),
      })

      local run = runtests.build_spec(tree:data(), fixtures)
      assert.is_not_nil(run)
      ---@cast run neotest.RunSpec

      local parsed = results.results(run, {
        code = 0,
        output = output_file({ '[{"name":"testFail","expected":3,"result":2}]' }),
      }, tree)

      assert.are.equal("passed", parsed[zero_arg_fixture .. "::tests::testPass"].status)
      assert.are.equal("failed", parsed[zero_arg_fixture .. "::tests::testFail"].status)
      assert.is_truthy(
        parsed[zero_arg_fixture .. "::tests::testFail"].short:find("testFail", 1, true)
      )
    end)

    it("marks a single filtered test position from an empty failure list as passed", function()
      local position = {
        id = zero_arg_fixture .. "::tests::testPass",
        name = "testPass",
        path = zero_arg_fixture,
        type = "test",
      }
      local tree = Tree:new(position)

      local run = runtests.build_spec(position, fixtures)
      assert.is_not_nil(run)
      ---@cast run neotest.RunSpec
      local parsed = results.results(run, { code = 0, output = output_file({ "[ ]" }) }, tree)

      assert.are.equal("passed", parsed[position.id].status)
    end)
  end)
end)
