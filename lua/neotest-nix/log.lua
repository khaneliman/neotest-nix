-- Opt-in debug logging and timing for discovery hot paths.
--
-- Disabled by default (zero overhead beyond a boolean check). Enable with the
-- `NEOTEST_NIX_DEBUG` environment variable or `vim.g.neotest_nix_debug = true`,
-- then inspect the log at `require("neotest-nix.log").path()` (under
-- `stdpath("log")`). On a tree the size of Nixpkgs this is the fastest way to
-- see how many files discovery touches and how long parsing each one costs.

local M = {}

local uv = vim.uv

local state = {
  enabled = nil,
  path = nil,
}

---@return boolean
function M.enabled()
  if state.enabled == nil then
    local env = vim.env.NEOTEST_NIX_DEBUG
    state.enabled = (env ~= nil and env ~= "" and env ~= "0") or vim.g.neotest_nix_debug == true
  end
  return state.enabled
end

---@return string
function M.path()
  if state.path == nil then
    state.path = vim.fs.joinpath(vim.fn.stdpath("log"), "neotest-nix.log")
  end
  return state.path
end

---@param line string
local function append(line)
  local file = io.open(M.path(), "a")
  if file == nil then
    return
  end
  file:write(line .. "\n")
  file:close()
end

---@param msg string
function M.debug(msg)
  if not M.enabled() then
    return
  end
  append(("%s %s"):format(os.date("!%Y-%m-%dT%H:%M:%SZ"), msg))
end

---Run `fn`, logging how long it took with a one-line message built from the
---result. `describe` receives whatever `fn` returned and yields the suffix.
---When logging is disabled `fn` runs with no measurement overhead.
---@generic T
---@param label string
---@param fn fun(): T
---@param describe? fun(result: T): string
---@return T
function M.time(label, fn, describe)
  if not M.enabled() then
    return fn()
  end
  local start = uv.hrtime()
  local result = fn()
  local elapsed_ms = (uv.hrtime() - start) / 1e6
  local suffix = describe ~= nil and (" " .. describe(result)) or ""
  M.debug(("%s %.2fms%s"):format(label, elapsed_ms, suffix))
  return result
end

return M
