-- Runs first-class non-flake roots against real Nix executables. This covers
-- the Phase 3 paths that do not need a flake: generic lib.runTests evaluation
-- and import-style nix-unit files rooted at the nearest Git repository.
local helpers = dofile(vim.fs.joinpath(vim.fn.getcwd(), "tests", "integration", "helpers.lua"))

if not helpers.enabled then
  describe("non-flake integration", function()
    it("skips without NEOTEST_NIX_INTEGRATION=1", function()
      -- busted's `pending` stub only declares a 2-arg overload; the 1-arg
      -- form used here is valid busted usage that just skips with a message.
      ---@diagnostic disable-next-line: missing-parameter
      pending("set NEOTEST_NIX_INTEGRATION=1 to run real-nix integration specs")
    end)
  end)
  return
end

local nio = require("nio")
local results = require("neotest-nix.results")
local spec = require("neotest-nix.spec")

---@param tree neotest.Tree
---@param predicate fun(position: neotest.Position): boolean
---@return neotest.Tree?
local function find_node(tree, predicate)
  for _, node in tree:iter_nodes() do
    if predicate(node:data()) then
      return node
    end
  end
  return nil
end

---@param file_path string
---@return neotest.Tree
local function discover(file_path)
  local tree
  local done = false
  nio.run(function()
    tree = require("neotest-nix").discover_positions(file_path)
    done = true
  end)
  vim.wait(5000, function()
    return done
  end)
  assert(tree ~= nil, "neotest-nix integration: discovery found no positions")
  return tree
end

describe("non-flake integration (real nix)", function()
  it("runs a non-flake lib.runTests file from its Git root", function()
    if not helpers.has_executable("nix-instantiate") then
      ---@diagnostic disable-next-line: missing-parameter
      pending("nix-instantiate not found on PATH; skipping lib.runTests integration spec")
      return
    end

    local dir, cleanup = helpers.materialize_fixture("non-flake-runtests")
    local path = vim.fs.joinpath(dir, "tests", "default.nix")

    local tree = discover(path)
    assert.are.equal(dir, require("neotest-nix").root(path))

    ---@diagnostic disable-next-line: missing-fields
    local run = spec.build_spec({ tree = tree })
    assert.is_not_nil(run)
    ---@cast run neotest.RunSpec
    assert.are.equal("nix-instantiate", run.command[1])
    assert.are.equal("nix-eval", run.context.runner)
    assert.are.equal(dir, run.cwd)

    local result = helpers.run_spec(run)
    assert.are.equal(0, result.code)

    local parsed = helpers.run_async(results.results, run, result, tree)
    local pass = find_node(tree, function(position)
      return position.name == "testPass"
    end)
    local fail = find_node(tree, function(position)
      return position.name == "testFail"
    end)
    assert.is_not_nil(pass)
    assert.is_not_nil(fail)
    ---@cast pass neotest.Tree
    ---@cast fail neotest.Tree

    assert.are.equal("passed", parsed[pass:data().id].status)
    assert.are.equal("failed", parsed[fail:data().id].status)

    cleanup()
  end)

  it("runs an import-style nix-unit file from its Git root", function()
    if not helpers.has_executable("nix-unit") then
      ---@diagnostic disable-next-line: missing-parameter
      pending("nix-unit not found on PATH; skipping import-style nix-unit integration spec")
      return
    end

    local dir, cleanup = helpers.materialize_fixture("non-flake-nix-unit")
    local path = vim.fs.joinpath(dir, "tests", "default.nix")

    local tree = discover(path)
    assert.are.equal(dir, require("neotest-nix").root(path))

    local pass = find_node(tree, function(position)
      return position.name == "testPass"
    end)
    local fail = find_node(tree, function(position)
      return position.name == "testFail"
    end)
    assert.is_not_nil(pass)
    assert.is_not_nil(fail)
    ---@cast pass neotest.Tree
    ---@cast fail neotest.Tree

    ---@diagnostic disable-next-line: missing-fields
    local pass_run = spec.build_spec({ tree = pass })
    assert.is_not_nil(pass_run)
    ---@cast pass_run neotest.RunSpec
    assert.are.equal("nix-unit", pass_run.command[1])
    assert.are.equal("nix-unit", pass_run.context.runner)
    assert.are.equal(dir, pass_run.cwd)

    local pass_result = helpers.run_spec(pass_run)
    assert.are.equal(0, pass_result.code)
    local pass_parsed = helpers.run_async(results.results, pass_run, pass_result, pass)
    assert.are.equal("passed", pass_parsed[pass:data().id].status)

    ---@diagnostic disable-next-line: missing-fields
    local fail_run = spec.build_spec({ tree = fail })
    assert.is_not_nil(fail_run)
    ---@cast fail_run neotest.RunSpec
    local fail_result = helpers.run_spec(fail_run)
    assert.are.equal(1, fail_result.code)
    local fail_parsed = helpers.run_async(results.results, fail_run, fail_result, fail)
    assert.are.equal("failed", fail_parsed[fail:data().id].status)

    cleanup()
  end)
end)
