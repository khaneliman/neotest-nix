-- Runs the legacy `nix-instantiate --eval --strict --json` command (the
-- `lib.runTests`-shaped eval leg spec.lua builds for a Nixpkgs
-- `lib/tests/misc.nix`-style file) against a real `nix-instantiate`, and
-- checks results.lua's `nix_eval_results` JSON parsing against real output.
-- The fixture at tests/fixtures/integration-flake/misc.nix hand-rolls the
-- same output shape `lib.runTests` produces (an empty list means every case
-- passed; each failing case names `expected`/`result`) without importing
-- nixpkgs, so this stays as cheap as the rest of tests/fixtures/integration-flake.
--
-- The position tree below is hand-built the same way spec_spec.lua's
-- "nix-eval" cases are (`nixpkgs_file_eval` is normally attached by
-- nixpkgs.lua's real Nixpkgs-checkout discovery, which this fixture is not);
-- what this spec adds over spec_spec.lua is executing the resulting command
-- against a real nix-instantiate and parsing its real output, not a
-- synthetic string.
local helpers = dofile(vim.fs.joinpath(vim.fn.getcwd(), "tests", "integration", "helpers.lua"))

if not helpers.enabled then
  describe("eval (nix-instantiate) integration", function()
    it("skips without NEOTEST_NIX_INTEGRATION=1", function()
      -- busted's `pending` stub only declares a 2-arg overload; the 1-arg
      -- form used here is valid busted usage that just skips with a message.
      ---@diagnostic disable-next-line: missing-parameter
      pending("set NEOTEST_NIX_INTEGRATION=1 to run real-nix integration specs")
    end)
  end)
  return
end

local Tree = require("neotest.types").Tree
local results = require("neotest-nix.results")
local spec = require("neotest-nix.spec")

local function get_id(data)
  return data.id
end

describe("eval (nix-instantiate) integration (real nix-instantiate)", function()
  local misc_path =
    vim.fs.joinpath(vim.fn.getcwd(), "tests", "fixtures", "integration-flake", "misc.nix")

  local function build_tree()
    return Tree.from_list({
      {
        id = misc_path,
        name = "misc.nix",
        path = misc_path,
        type = "file",
        runner = "nix-eval",
        nixpkgs_file_eval = "misc.nix",
      },
      {
        {
          id = misc_path .. "::testPass",
          name = "testPass",
          path = misc_path,
          type = "test",
        },
      },
      {
        {
          id = misc_path .. "::testFail",
          name = "testFail",
          path = misc_path,
          type = "test",
        },
      },
    }, get_id)
  end

  it("builds and runs a real `nix-instantiate --eval --strict --json` of the fixture", function()
    local tree = build_tree()

    -- Real neotest always fills RunArgs.strategy before build_spec runs (see
    -- spec.lua's run_strategy doc comment); omitting it here matches
    -- spec_spec.lua's own convention for calling build_spec directly.
    ---@diagnostic disable-next-line: missing-fields
    local run = spec.build_spec({ tree = tree })
    assert.is_not_nil(run)
    ---@cast run neotest.RunSpec
    assert.same({ "nix-instantiate", "--eval", "--strict", "--json", "misc.nix" }, run.command)
    assert.are.equal("nix-eval", run.context.runner)

    local result = helpers.run_spec(run)
    -- nix-instantiate exits 0 even though the evaluated value reports a
    -- failing case: the *evaluation* succeeded, `lib.runTests`-shaped output
    -- is just data. Only a real Nix eval error (a bad expression) exits
    -- non-zero here.
    assert.are.equal(0, result.code)

    local parsed = helpers.run_async(results.results, run, result, tree)
    assert.are.equal("passed", parsed[misc_path .. "::testPass"].status)

    local fail_entry = parsed[misc_path .. "::testFail"]
    assert.are.equal("failed", fail_entry.status)
    assert.is_truthy(fail_entry.short:find("expected 2, got 1", 1, true))
  end)
end)
