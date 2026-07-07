-- Builds the `tests/fixtures/integration-flake-follows` fixture with a real
-- `nix build`: the second, deliberately heavier fixture design (see its
-- flake.nix), which needs nixpkgs and gets it via `inputs.nixpkgs.follows`
-- instead of an independent fetch. Unlike tests/fixtures/integration-flake,
-- this fixture is run in place (not materialized into a temp copy): its
-- `root` input is the relative path `path:../../..` (this repository), which
-- only resolves correctly from its committed location.
local helpers = dofile(vim.fs.joinpath(vim.fn.getcwd(), "tests", "integration", "helpers.lua"))

if not helpers.enabled then
  describe("follows fixture integration", function()
    it("skips without NEOTEST_NIX_INTEGRATION=1", function()
      -- busted's `pending` stub only declares a 2-arg overload; the 1-arg
      -- form used here is valid busted usage that just skips with a message.
      ---@diagnostic disable-next-line: missing-parameter
      pending("set NEOTEST_NIX_INTEGRATION=1 to run real-nix integration specs")
    end)
  end)
  return
end

local fixture_dir = "tests/fixtures/integration-flake-follows"

if not helpers.fixture_is_git_tracked(fixture_dir) then
  describe("follows fixture integration", function()
    it("skips: fixture not staged in Git", function()
      -- busted's `pending` stub only declares a 2-arg overload; the 1-arg
      -- form used here is valid busted usage that just skips with a message.
      ---@diagnostic disable-next-line: missing-parameter
      pending(
        ("`%s` is not tracked by Git yet; run `git add %s` (a commit is not "):format(
          fixture_dir,
          fixture_dir
        ) .. "required) before running integration specs"
      )
    end)
  end)
  return
end

local nio = require("nio")
local results = require("neotest-nix.results")
local spec = require("neotest-nix.spec")

describe("follows fixture integration (real nix build, real nixpkgs.follows)", function()
  it("builds the follows fixture's check with nixpkgs resolved through `follows`", function()
    local done = false
    local tree
    nio.run(function()
      tree = require("neotest-nix").discover_positions(vim.fs.joinpath(fixture_dir, "flake.nix"))
      done = true
    end)
    vim.wait(5000, function()
      return done
    end)
    assert.is_not_nil(tree)
    ---@cast tree neotest.Tree

    local node
    for _, candidate in tree:iter_nodes() do
      if candidate:data().attr_path == "checks.x86_64-linux.unit" then
        node = candidate
      end
    end
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
    assert.are.equal(0, result.code)

    local parsed = helpers.run_async(results.results, run, result, node)
    assert.are.equal("passed", parsed[node:data().id].status)
  end)
end)
