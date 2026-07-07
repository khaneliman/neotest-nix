-- Runs the Namaka adapter path against a real `namaka` executable when one is
-- available. The fixture config keeps the command cheap while still proving
-- adapter discovery, cwd, command execution, and result mapping.
local helpers = dofile(vim.fs.joinpath(vim.fn.getcwd(), "tests", "integration", "helpers.lua"))

if not helpers.enabled then
  describe("namaka integration", function()
    it("skips without NEOTEST_NIX_INTEGRATION=1", function()
      -- busted's `pending` stub only declares a 2-arg overload; the 1-arg
      -- form used here is valid busted usage that just skips with a message.
      ---@diagnostic disable-next-line: missing-parameter
      pending("set NEOTEST_NIX_INTEGRATION=1 to run real-nix integration specs")
    end)
  end)
  return
end

if not helpers.has_executable("namaka") then
  describe("namaka integration", function()
    it("skips: namaka not found", function()
      -- busted's `pending` stub only declares a 2-arg overload; the 1-arg
      -- form used here is valid busted usage that just skips with a message.
      ---@diagnostic disable-next-line: missing-parameter
      pending("namaka not found on PATH; skipping Namaka integration specs")
    end)
  end)
  return
end

local nio = require("nio")
local results = require("neotest-nix.results")
local spec = require("neotest-nix.spec")

describe("namaka integration (real namaka)", function()
  local dir, cleanup, tree

  setup(function()
    dir, cleanup = helpers.materialize_fixture("namaka-project")
    local path = vim.fs.joinpath(dir, "tests", "basic", "expr.nix")

    local done = false
    nio.run(function()
      tree = require("neotest-nix").discover_positions(path)
      done = true
    end)
    vim.wait(5000, function()
      return done
    end)
    assert(tree ~= nil, "neotest-nix integration: discovery found no Namaka position")
  end)

  teardown(function()
    if cleanup ~= nil then
      cleanup()
    end
  end)

  it("runs `namaka check` at the Namaka root", function()
    ---@diagnostic disable-next-line: missing-fields
    local run = spec.build_spec({ tree = tree })
    assert.is_not_nil(run)
    ---@cast run neotest.RunSpec
    assert.same({ "namaka", "check" }, run.command)
    assert.are.equal(dir, run.cwd)
    assert.are.equal("namaka", run.context.runner)

    local result = helpers.run_spec(run)
    assert.are.equal(0, result.code)

    local parsed = helpers.run_async(results.results, run, result, tree)
    assert.are.equal("passed", parsed[tree:data().id].status)
  end)
end)
