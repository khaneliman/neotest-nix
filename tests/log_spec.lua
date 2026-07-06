local function reload_log()
  package.loaded["neotest-nix.log"] = nil
  return require("neotest-nix.log")
end

describe("log", function()
  local env
  local debug
  local stdpath
  local hrtime

  before_each(function()
    env = vim.env.NEOTEST_NIX_DEBUG
    debug = vim.g.neotest_nix_debug
    stdpath = vim.fn.stdpath
    hrtime = vim.uv.hrtime

    vim.env.NEOTEST_NIX_DEBUG = nil
    vim.g.neotest_nix_debug = nil
    package.loaded["neotest-nix.log"] = nil
  end)

  after_each(function()
    vim.env.NEOTEST_NIX_DEBUG = env
    vim.g.neotest_nix_debug = debug
    vim.fn.stdpath = stdpath
    vim.uv.hrtime = hrtime
    package.loaded["neotest-nix.log"] = nil
  end)

  it("defaults to disabled", function()
    assert.is_false(reload_log().enabled())
  end)

  it("enables for non-empty non-zero env values", function()
    vim.env.NEOTEST_NIX_DEBUG = "1"

    assert.is_true(reload_log().enabled())
  end)

  it("disables for empty or zero env values", function()
    vim.env.NEOTEST_NIX_DEBUG = ""
    assert.is_false(reload_log().enabled())

    vim.env.NEOTEST_NIX_DEBUG = "0"
    assert.is_false(reload_log().enabled())
  end)

  it("enables from vim.g when env disables logging", function()
    vim.env.NEOTEST_NIX_DEBUG = "0"
    vim.g.neotest_nix_debug = true

    assert.is_true(reload_log().enabled())
  end)

  it("memoizes the log path", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local calls = 0
    vim.fn.stdpath = function(kind)
      assert.are.equal("log", kind)
      calls = calls + 1
      return dir
    end

    local log = reload_log()
    assert.are.equal(vim.fs.joinpath(dir, "neotest-nix.log"), log.path())
    assert.are.equal(log.path(), log.path())
    assert.are.equal(1, calls)
  end)

  it("does not write when disabled", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    vim.fn.stdpath = function()
      return dir
    end

    local log = reload_log()
    log.debug("ignored")

    assert.is_nil(vim.uv.fs_stat(log.path()))
  end)

  it("writes timestamped debug lines when enabled", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    vim.fn.stdpath = function()
      return dir
    end
    vim.env.NEOTEST_NIX_DEBUG = "1"

    local log = reload_log()
    log.debug("hello")

    local lines = vim.fn.readfile(log.path())
    assert.are.equal(1, #lines)
    assert.is_truthy(lines[1]:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ hello$"))
  end)

  it("runs timed functions without logging when disabled", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    vim.fn.stdpath = function()
      return dir
    end

    local log = reload_log()
    local value = log.time("parse", function()
      return "result"
    end)

    assert.are.equal("result", value)
    assert.is_nil(vim.uv.fs_stat(log.path()))
  end)

  it("logs elapsed time and describe suffix when enabled", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    vim.fn.stdpath = function()
      return dir
    end
    vim.env.NEOTEST_NIX_DEBUG = "1"
    local ticks = { 0, 1000000000 }
    local index = 0
    vim.uv.hrtime = function()
      index = index + 1
      return ticks[index]
    end

    local log = reload_log()
    local value = log.time("parse", function()
      return 7
    end, function(result)
      return ("files=%d"):format(result)
    end)

    assert.are.equal(7, value)
    local lines = vim.fn.readfile(log.path())
    assert.is_truthy(lines[#lines]:find("parse 1000.00ms files=7", 1, true))
  end)
end)
