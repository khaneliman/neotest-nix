-- Shared scaffolding for the real-nix integration specs in tests/integration/.
--
-- These specs run the actual `nix` / `nix-unit` binaries against the
-- committed fixture flakes under tests/fixtures/, closing the gap the rest of
-- the Busted suite leaves open: every other spec stubs `vim.system`, so the
-- command strings spec.lua builds are never executed, and the output parsers
-- in results.lua are only ever fed synthetic strings. Because that means real
-- network/build time and a real `nix`/`nix-unit` on PATH, this file is *not*
-- itself a `_spec.lua` (Busted would otherwise try to run it as one), and
-- every integration spec gates on `M.enabled` before doing any of it -- see
-- the "NEOTEST_NIX_INTEGRATION" note on `M.enabled` below.
local nio = require("nio")
local process = require("neotest-nix.process")

local M = {}

-- Unset (or any value other than "1") keeps the default `vusted tests/` run
-- hermetic: every integration spec checks this before touching disk/network,
-- and registers a single `pending` case instead of its real assertions so the
-- skip is visible in the suite's summary rather than silent.
M.enabled = vim.env.NEOTEST_NIX_INTEGRATION == "1"

---@param name string
---@return boolean
function M.has_executable(name)
  return vim.fn.executable(name) == 1
end

---Whether every file under `dir` (relative to the repository root) is
---visible to Git (tracked -- staged is enough, a commit is not required).
---Used by the `integration-flake-follows` fixture spec, which -- unlike the
---other fixtures -- cannot be materialized into an isolated temp copy (its
---`root` input is the relative path `path:../../..`, so it only resolves
---from its committed location): a contributor who has not yet staged a new
---fixture would otherwise see nix's own "not tracked by Git" error rather
---than a clear skip.
---@param dir string path relative to the repository root
---@return boolean
function M.fixture_is_git_tracked(dir)
  local output = vim.fn.system({ "git", "ls-files", "--error-unmatch", dir })
  return vim.v.shell_error == 0 and vim.trim(output) ~= ""
end

---Copy a committed fixture flake into a throwaway directory and initialize a
---throwaway Git repo there (`git init` + `git add -A`, no commit). Real `nix`
---refuses to evaluate a local flake whose files are not visible to Git
---(tracked -- staged is enough, a commit is not required), and the adapter's
---own nix-unit command relies on the same local-flake machinery
---(`builtins.getFlake (toString ./.)` needs a "locked" reference, which a
---plain uncommitted directory never has). Materializing into an isolated
---temp copy means the specs behave the same whether or not the contributor
---has staged tests/fixtures/ in the real repository, and a stray build
---artifact never lands under version control.
---
---Not used for `tests/fixtures/integration-flake-follows`: that fixture's
---`root` input is the relative path `path:../../..` (this repository), so it
---only resolves correctly from its committed location and must be run in
---place; see eval_integration_spec.lua and flake_check_integration_spec.lua
---for the input-free fixture this helper targets versus
---nix_unit_integration_spec.lua's use of the in-place follows fixture.
---@param fixture_name string directory name under tests/fixtures/
---@return string dir the materialized copy's path
---@return fun() cleanup call once the caller is done with `dir`
function M.materialize_fixture(fixture_name)
  local src = vim.fs.joinpath(vim.fn.getcwd(), "tests", "fixtures", fixture_name)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")

  local ok = os.execute(("cp -r %s/. %s/"):format(vim.fn.shellescape(src), vim.fn.shellescape(dir)))
  assert(ok, ("neotest-nix integration: failed to copy fixture `%s`"):format(fixture_name))

  local init_cmd = ("cd %s && git init -q && git -c user.email=neotest-nix@example.com "):format(
    vim.fn.shellescape(dir)
  ) .. "-c user.name=neotest-nix add -A"
  ok = os.execute(init_cmd)
  assert(
    ok,
    ("neotest-nix integration: failed to stage fixture `%s` for Git-aware nix evaluation"):format(
      fixture_name
    )
  )

  local function cleanup()
    vim.fn.delete(dir, "rf")
  end

  return dir, cleanup
end

---Run a `neotest.RunSpec` to completion with the real strategy
---(process.lua's `vim.system` wrapper -- the same code path Neotest drives in
---the editor) and return a `neotest.StrategyResult`-shaped table plus the raw
---output text, ready for `results.results`/`results.stream`.
---@param run neotest.RunSpec
---@param timeout_ms integer?
---@return neotest.StrategyResult result
---@return string output_text
function M.run_spec(run, timeout_ms)
  ---@type integer?, string?
  local code, output_path
  local done = false

  nio.run(function()
    local proc = process.strategy(run)
    code = proc.result()
    output_path = proc.output()
    done = true
  end)

  local waited = vim.wait(timeout_ms or 60000, function()
    return done
  end, 50)
  assert(waited, "neotest-nix integration: process did not complete before the timeout")

  local output_text = ""
  if output_path ~= nil then
    local file = io.open(output_path, "r")
    if file ~= nil then
      output_text = file:read("*a") or ""
      file:close()
    end
  end

  return { code = code, output = output_path }, output_text
end

---Call an `---@async` adapter function (e.g. `results.results`, which awaits a
---`nix log` enrichment future for failed builds) from an async context,
---mirroring how Neotest itself drives the adapter's hooks from a coroutine.
---Busted's test bodies are not themselves async contexts, so calling such a
---function directly errors with "Cannot call async function from non-async
---context".
---@param fn function
---@param ... any
---@return any
function M.run_async(fn, ...)
  local args = { ... }
  local done = false
  local ok, out

  nio.run(function()
    ok, out = pcall(fn, unpack(args))
    done = true
  end)

  local waited = vim.wait(30000, function()
    return done
  end, 50)
  assert(waited, "neotest-nix integration: async call did not complete before the timeout")

  if not ok then
    error(out, 0)
  end
  return out
end

return M
