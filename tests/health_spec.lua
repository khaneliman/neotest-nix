-- Exercises the config-correctness reporting in health.lua. vim.health is
-- stubbed so the recorded ok/warn/error messages can be asserted; the
-- dependency/binary checks still run but their messages are ignored.

describe("health config check", function()
  local recorded
  local real_health

  before_each(function()
    package.loaded["neotest-nix"] = nil
    package.loaded["neotest-nix.health"] = nil
    vim.opt.runtimepath:prepend(vim.fn.getcwd())

    recorded = { ok = {}, warn = {}, error = {} }
    real_health = vim.health
    vim.health = {
      start = function() end,
      ok = function(msg)
        table.insert(recorded.ok, msg)
      end,
      warn = function(msg)
        table.insert(recorded.warn, msg)
      end,
      error = function(msg)
        table.insert(recorded.error, msg)
      end,
    }
  end)

  after_each(function()
    vim.health = real_health
    package.loaded["neotest-nix.health"] = nil
    package.loaded["neotest-nix"] = nil
  end)

  ---@param opts table
  local function check_with_opts(opts)
    local adapter = require("neotest-nix")
    -- Assign directly to exercise the "config not set via setup" path without
    -- tripping setup()'s own validation.
    adapter._opts = opts
    require("neotest-nix.health").check()
  end

  ---@param messages string[]
  ---@param pattern string
  ---@return boolean
  local function any_match(messages, pattern)
    for _, message in ipairs(messages) do
      if message:match(pattern) then
        return true
      end
    end
    return false
  end

  it("reports default configuration when no opts are set", function()
    check_with_opts({})
    assert.is_true(any_match(recorded.ok, "using default configuration"))
  end)

  it("warns on an unknown config key", function()
    check_with_opts({ discover_eval_check = true })
    assert.is_true(any_match(recorded.warn, "unknown config key `discover_eval_check`"))
  end)

  it("errors on a malformed eval_outputs entry", function()
    check_with_opts({ eval_outputs = { { match = "^t" } } })
    assert.is_true(any_match(recorded.error, "eval_outputs%[1%]"))
  end)

  it("reports a valid configuration", function()
    check_with_opts({ discover_eval_checks = true, eval_outputs = { { attr = "checks" } } })
    assert.is_true(any_match(recorded.ok, "configuration looks valid"))
  end)
end)
