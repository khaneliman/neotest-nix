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

  it("errors on a malformed parser_runtime_paths entry", function()
    check_with_opts({ parser_runtime_paths = { false } })
    assert.is_true(any_match(recorded.error, "parser_runtime_paths%[1%]"))
  end)

  it("errors on a malformed eval_outputs entry", function()
    check_with_opts({ eval_outputs = { { match = "^t" } } })
    assert.is_true(any_match(recorded.error, "eval_outputs%[1%]"))
  end)

  it("reports a valid configuration", function()
    check_with_opts({ discover_eval_checks = true, eval_outputs = { { attr = "checks" } } })
    assert.is_true(any_match(recorded.ok, "configuration looks valid"))
  end)

  it("accepts parser_runtime_paths for the grammar check", function()
    local root = vim.fn.tempname()
    vim.fn.mkdir(vim.fs.joinpath(root, "parser"), "p")
    vim.fn.writefile({}, vim.fs.joinpath(root, "parser", "nix.so"))

    local real_runtime_file = vim.api.nvim_get_runtime_file
    local real_language_add = vim.treesitter.language.add
    local expected_parser = vim.fs.joinpath(root, "parser", "nix.so")
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.api.nvim_get_runtime_file = function(name, all)
      if name == "parser/nix.so" then
        return {}
      end
      return real_runtime_file(name, all)
    end
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.treesitter.language.add = function(lang, opts)
      if lang == "nix" and (opts == nil or opts.path ~= expected_parser) then
        error("missing nix parser")
      end
      return true
    end
    finally(function()
      vim.api.nvim_get_runtime_file = real_runtime_file
      vim.treesitter.language.add = real_language_add
    end)

    check_with_opts({ parser_runtime_paths = { root } })

    assert.is_true(any_match(recorded.ok, "`nix` tree%-sitter grammar available"))
  end)

  it("rejects broken parser_runtime_paths for the grammar check", function()
    local root = vim.fn.tempname()
    vim.fn.mkdir(vim.fs.joinpath(root, "parser"), "p")
    vim.fn.writefile({}, vim.fs.joinpath(root, "parser", "nix.so"))

    local real_runtime_file = vim.api.nvim_get_runtime_file
    local real_language_add = vim.treesitter.language.add
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.api.nvim_get_runtime_file = function(name, all)
      if name == "parser/nix.so" then
        return {}
      end
      return real_runtime_file(name, all)
    end
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.treesitter.language.add = function(lang)
      if lang == "nix" then
        error("missing nix parser")
      end
      return real_language_add(lang)
    end
    finally(function()
      vim.api.nvim_get_runtime_file = real_runtime_file
      vim.treesitter.language.add = real_language_add
    end)

    check_with_opts({ parser_runtime_paths = { root } })

    assert.is_true(any_match(recorded.warn, "`nix` tree%-sitter grammar not found"))
  end)

  it("errors on an unsupported Neovim version", function()
    local real_has = vim.fn.has
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.fn.has = function(feature)
      if feature == "nvim-0.11" then
        return 0
      end
      return real_has(feature)
    end
    finally(function()
      vim.fn.has = real_has
    end)

    check_with_opts({})
    assert.is_true(any_match(recorded.error, "Neovim >= 0.11 is required"))
  end)

  it("errors when nix is not on PATH", function()
    local real_executable = vim.fn.executable
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.fn.executable = function(name)
      if name == "nix" then
        return 0
      end
      return real_executable(name)
    end
    finally(function()
      vim.fn.executable = real_executable
    end)

    check_with_opts({})
    assert.is_true(any_match(recorded.error, "`nix` not found on PATH"))
  end)

  it("warns when nix-unit is not on PATH", function()
    local real_executable = vim.fn.executable
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.fn.executable = function(name)
      if name == "nix-unit" then
        return 0
      end
      return real_executable(name)
    end
    finally(function()
      vim.fn.executable = real_executable
    end)

    check_with_opts({})
    assert.is_true(any_match(recorded.warn, "`nix%-unit` not found on PATH"))
  end)

  ---@param stdout string
  ---@param code integer?
  local function stub_nix_version(stdout, code)
    local real_system = vim.system
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.system = function(_command, _opts)
      return {
        wait = function()
          return { code = code or 0, stdout = stdout, stderr = "" }
        end,
      }
    end
    finally(function()
      vim.system = real_system
    end)
  end

  it("reports the nix version when it meets the minimum", function()
    stub_nix_version("nix (Nix) 2.18.1\n")

    check_with_opts({})

    assert.is_true(any_match(recorded.ok, "`nix` 2%.18"))
  end)

  it("errors when the nix version is older than the minimum", function()
    stub_nix_version("nix (Nix) 2.3.0\n")

    check_with_opts({})

    assert.is_true(any_match(recorded.error, "older than the minimum supported version"))
  end)

  it("warns when nix --version output cannot be parsed", function()
    stub_nix_version("unexpected output with no version\n")

    check_with_opts({})

    assert.is_true(any_match(recorded.warn, "could not parse"))
  end)

  it("honours a configured nix_bin for the version check", function()
    local real_system = vim.system
    local captured
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.system = function(command)
      captured = command
      return {
        wait = function()
          return { code = 0, stdout = "nix (Nix) 2.18.1\n", stderr = "" }
        end,
      }
    end

    local real_executable = vim.fn.executable
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.fn.executable = function(name)
      if name == "/opt/nix/bin/nix" then
        return 1
      end
      return real_executable(name)
    end

    -- A single finally covering both stubs: this busted setup only keeps the
    -- last `finally` registered per test, so two separate calls here would
    -- silently drop the vim.system restore and leak the stub into later specs.
    finally(function()
      vim.system = real_system
      vim.fn.executable = real_executable
    end)

    check_with_opts({ nix_bin = "/opt/nix/bin/nix" })

    assert.are.equal("/opt/nix/bin/nix", captured[1])
  end)

  it("warns when git is not on PATH", function()
    local real_executable = vim.fn.executable
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.fn.executable = function(name)
      if name == "git" then
        return 0
      end
      return real_executable(name)
    end
    finally(function()
      vim.fn.executable = real_executable
    end)

    check_with_opts({})
    assert.is_true(any_match(recorded.warn, "`git` not found on PATH"))
  end)

  it("reports git on PATH when present", function()
    local real_executable = vim.fn.executable
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.fn.executable = function(name)
      if name == "git" then
        return 1
      end
      return real_executable(name)
    end
    finally(function()
      vim.fn.executable = real_executable
    end)

    check_with_opts({})
    assert.is_true(any_match(recorded.ok, "`git` on PATH"))
  end)
end)
