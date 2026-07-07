-- Runs the adapter's `nix build`/`nix flake check` command strings against a
-- real `nix`, closing the gap the rest of the suite leaves open: spec_spec.lua
-- only asserts the generated command array, and process_spec.lua/results_spec.lua
-- only ever feed it synthetic `sh` output. See tests/integration/helpers.lua
-- for the gating and process-execution scaffolding shared by every spec here.
-- .busted's lpath only covers lua/?.lua, so pull the shared helper in
-- directly by path rather than teaching Busted a second module root.
local helpers = dofile(vim.fs.joinpath(vim.fn.getcwd(), "tests", "integration", "helpers.lua"))

if not helpers.enabled then
  describe("flake check integration", function()
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

describe("flake check integration (real nix build)", function()
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

  it("passes a real `nix build` of a passing check", function()
    local node = find_node(tree, function(position)
      return position.attr_path == "checks.x86_64-linux.passing"
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
    assert.are.equal("nix", run.command[1])
    assert.are.equal("build", run.command[2])

    local result = helpers.run_spec(run)
    assert.are.equal(0, result.code)

    local parsed = helpers.run_async(results.results, run, result, node)
    assert.are.equal("passed", parsed[node:data().id].status)
  end)

  it("fails a real `nix build` of a failing check with the derivation's error", function()
    local node = find_node(tree, function(position)
      return position.attr_path == "checks.x86_64-linux.failing"
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
    local entry = parsed[node:data().id]
    assert.are.equal("failed", entry.status)
    -- A build failure has no `at <file>:<line>:<col>:` frame (unlike an
    -- evaluation error), so results.lua falls back to the raw failure text;
    -- confirm the derivation's own stderr survives that fallback intact.
    assert.is_truthy(entry.short:find("deliberate integration-test failure", 1, true))
  end)

  it("runs `nix flake check` for the whole fixture and reports the aggregate failure", function()
    -- Real neotest always fills RunArgs.strategy before build_spec runs (see
    -- spec.lua's run_strategy doc comment); omitting it here matches
    -- spec_spec.lua's own convention for calling build_spec directly.
    ---@diagnostic disable-next-line: missing-fields
    local run = spec.build_spec({ tree = tree })
    assert.is_not_nil(run)
    ---@cast run neotest.RunSpec
    assert.are.equal("check", run.command[3])

    local result = helpers.run_spec(run)
    assert.are.equal(1, result.code)

    local parsed = helpers.run_async(results.results, run, result, tree)
    local entry = parsed[tree:data().id]
    assert.are.equal("failed", entry.status)
    assert.is_truthy(entry.short:find("deliberate integration-test failure", 1, true))
  end)
end)
