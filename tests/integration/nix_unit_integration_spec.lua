-- Runs the adapter's `nix-unit` command strings (both the `--flake` suite
-- form and the single-test `--expr`/`builtins.getFlake` form) against a real
-- `nix-unit`, and checks results.lua's marker parsing (✅/❌/🎉/😢, including
-- ANSI-colored diff blocks) against real output rather than the hand-written
-- strings the rest of the suite uses. See tests/integration/helpers.lua for
-- the gating and process-execution scaffolding shared by every spec here.
local helpers = dofile(vim.fs.joinpath(vim.fn.getcwd(), "tests", "integration", "helpers.lua"))

if not helpers.enabled then
  describe("nix-unit integration", function()
    it("skips without NEOTEST_NIX_INTEGRATION=1", function()
      -- busted's `pending` stub only declares a 2-arg overload; the 1-arg
      -- form used here is valid busted usage that just skips with a message.
      ---@diagnostic disable-next-line: missing-parameter
      pending("set NEOTEST_NIX_INTEGRATION=1 to run real-nix integration specs")
    end)
  end)
  return
end

if not helpers.has_executable("nix-unit") then
  describe("nix-unit integration", function()
    it("skips: nix-unit not found", function()
      -- busted's `pending` stub only declares a 2-arg overload; the 1-arg
      -- form used here is valid busted usage that just skips with a message.
      ---@diagnostic disable-next-line: missing-parameter
      pending("nix-unit not found on PATH; skipping nix-unit integration specs")
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

describe("nix-unit integration (real nix-unit)", function()
  local dir, cleanup, tree

  setup(function()
    dir, cleanup = helpers.materialize_fixture("integration-flake")

    local done = false
    nio.run(function()
      tree = require("neotest-nix").discover_positions(vim.fs.joinpath(dir, "flake.nix"))
      done = true
    end)
    vim.wait(5000, function()
      return done
    end)
    assert(
      tree ~= nil,
      "neotest-nix integration: discovery found no positions in the fixture flake"
    )
  end)

  teardown(function()
    if cleanup ~= nil then
      cleanup()
    end
  end)

  it("runs the whole `tests` suite via `nix-unit --flake` and maps pass/fail per test", function()
    local suite = find_node(tree, function(position)
      return position.type == "namespace" and position.name == "tests"
    end)
    assert.is_not_nil(suite)
    ---@cast suite neotest.Tree

    -- Real neotest always fills RunArgs.strategy before build_spec runs (see
    -- spec.lua's run_strategy doc comment); omitting it here matches
    -- spec_spec.lua's own convention for calling build_spec directly.
    ---@diagnostic disable-next-line: missing-fields
    local run = spec.build_spec({ tree = suite })
    assert.is_not_nil(run)
    ---@cast run neotest.RunSpec
    assert.are.equal("nix-unit", run.command[1])
    assert.are.equal("--flake", run.command[4])
    assert.are.equal("nix-unit", run.context.runner)

    local result = helpers.run_spec(run)
    -- nix-unit exits non-zero whenever any attribute fails; that is expected
    -- here since the fixture deliberately includes a failing case.
    assert.are.equal(1, result.code)

    local parsed = helpers.run_async(results.results, run, result, suite)

    local pass_node = find_node(tree, function(position)
      return position.attr_path == "tests.testPass"
    end)
    local fail_node = find_node(tree, function(position)
      return position.attr_path == "tests.testFail"
    end)
    assert.is_not_nil(pass_node)
    assert.is_not_nil(fail_node)
    ---@cast pass_node neotest.Tree
    ---@cast fail_node neotest.Tree

    assert.are.equal("passed", parsed[pass_node:data().id].status)
    assert.are.equal("failed", parsed[fail_node:data().id].status)
  end)

  it("passes a single targeted test via nix-unit's `--expr`/`builtins.getFlake` form", function()
    local node = find_node(tree, function(position)
      return position.attr_path == "tests.testPass"
    end)
    assert.is_not_nil(node)
    ---@cast node neotest.Tree

    -- Real neotest always fills RunArgs.strategy before build_spec runs (see
    -- spec.lua's run_strategy doc comment); omitting it here matches
    -- spec_spec.lua's own convention for calling build_spec directly.
    ---@diagnostic disable-next-line: missing-fields
    local run = spec.build_spec({ tree = node })
    assert.is_not_nil(run)
    ---@cast run neotest.RunSpec
    assert.are.equal("--expr", run.command[4])

    local result = helpers.run_spec(run)
    assert.are.equal(0, result.code)

    local parsed = helpers.run_async(results.results, run, result, node)
    assert.are.equal("passed", parsed[node:data().id].status)
  end)

  it("fails a single targeted test via nix-unit's `--expr`/`builtins.getFlake` form", function()
    local node = find_node(tree, function(position)
      return position.attr_path == "tests.testFail"
    end)
    assert.is_not_nil(node)
    ---@cast node neotest.Tree

    -- Real neotest always fills RunArgs.strategy before build_spec runs (see
    -- spec.lua's run_strategy doc comment); omitting it here matches
    -- spec_spec.lua's own convention for calling build_spec directly.
    ---@diagnostic disable-next-line: missing-fields
    local run = spec.build_spec({ tree = node })
    assert.is_not_nil(run)
    ---@cast run neotest.RunSpec

    local result = helpers.run_spec(run)
    assert.are.equal(1, result.code)

    local parsed = helpers.run_async(results.results, run, result, node)
    assert.are.equal("failed", parsed[node:data().id].status)
  end)
end)
