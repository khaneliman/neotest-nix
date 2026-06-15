-- Verifies the adapter is constructible and fully functional across every
-- supported entry point:
--   * bare module        require("neotest-nix")            (no .setup call)
--   * call form          require("neotest-nix")(opts)      (__call)
--   * explicit setup     require("neotest-nix").setup(opts)
-- and that it is usable once handed to neotest, plus that config options reach
-- the discovery path. The module table itself is the adapter (see
-- neotest-haskell), so all three forms resolve to the same object.

local fixtures = vim.fs.joinpath(vim.fn.getcwd(), "tests", "fixtures")
local flake_fixture = vim.fs.joinpath(fixtures, "flake.nix")
local bare_tests_fixture = vim.fs.joinpath(fixtures, "bare-tests.nix")

local adapter_hooks = {
  "root",
  "is_test_file",
  "filter_dir",
  "build_spec",
  "results",
  "discover_positions",
}

---@param adapter table
local function assert_adapter_shape(adapter)
  assert.are.equal("table", type(adapter))
  assert.are.equal("neotest-nix", adapter.name)
  for _, hook in ipairs(adapter_hooks) do
    assert.are.equal("function", type(adapter[hook]), hook .. " should be a function")
  end
end

describe("adapter construction", function()
  before_each(function()
    package.loaded["neotest-nix"] = nil
    vim.opt.runtimepath:prepend(vim.fn.getcwd())
  end)

  it("exposes a complete adapter without a setup call (bare module)", function()
    assert_adapter_shape(require("neotest-nix"))
  end)

  it("exposes a complete adapter via the call form", function()
    assert_adapter_shape(require("neotest-nix")({}))
  end)

  it("exposes a complete adapter via setup", function()
    assert_adapter_shape(require("neotest-nix").setup({}))
  end)

  it("resolves every entry point to the same adapter instance", function()
    local m = require("neotest-nix")
    assert.are.equal(m, m({}))
    assert.are.equal(m, m.setup({}))
    assert.are.equal(m, m.setup())
  end)
end)

describe("adapter behavior is identical across entry points", function()
  before_each(function()
    package.loaded["neotest-nix"] = nil
    vim.opt.runtimepath:prepend(vim.fn.getcwd())
  end)

  local function variants()
    local m = require("neotest-nix")
    return { bare = m, call = m({}), setup = m.setup({}) }
  end

  it("classifies test files consistently", function()
    for label, adapter in pairs(variants()) do
      assert.are.equal(
        true,
        adapter.is_test_file(flake_fixture),
        label .. ": flake.nix is a test file"
      )
      assert.are.equal(
        true,
        adapter.is_test_file(bare_tests_fixture),
        label .. ": nix-unit file is a test file"
      )
      assert.are.equal(
        false,
        adapter.is_test_file(vim.fs.joinpath(vim.fn.getcwd(), "README.md")),
        label .. ": README.md is not a test file"
      )
    end
  end)

  it("resolves the flake root consistently", function()
    for label, adapter in pairs(variants()) do
      assert.are.equal(fixtures, adapter.root(flake_fixture), label .. ": root is the fixtures dir")
    end
  end)
end)

describe("adapter integrates with neotest", function()
  before_each(function()
    package.loaded["neotest-nix"] = nil
    vim.opt.runtimepath:prepend(vim.fn.getcwd())
  end)

  -- Skips gracefully when neotest is absent (e.g. running specs outside the
  -- dev shell) so the suite stays portable.
  local function with_neotest(fn)
    local ok, neotest = pcall(require, "neotest")
    if not ok then
      return
    end
    fn(neotest, require("neotest.config"))
  end

  it("stores a working adapter when configured without setup (bare)", function()
    with_neotest(function(neotest, config)
      neotest.setup({ adapters = { require("neotest-nix") } })

      local stored = config.adapters[1]
      assert.is_not_nil(stored)
      assert.are.equal("neotest-nix", stored.name)
      assert.is_true(stored.is_test_file(flake_fixture))
    end)
  end)

  it("stores a working adapter when configured via the call form", function()
    with_neotest(function(neotest, config)
      neotest.setup({ adapters = { require("neotest-nix")({}) } })

      local stored = config.adapters[1]
      assert.is_not_nil(stored)
      assert.are.equal("neotest-nix", stored.name)
      assert.is_true(stored.is_test_file(flake_fixture))
    end)
  end)
end)

describe("config validation", function()
  before_each(function()
    package.loaded["neotest-nix"] = nil
    vim.opt.runtimepath:prepend(vim.fn.getcwd())
  end)

  local function setup_error(opts)
    local adapter = require("neotest-nix")
    local ok, err = pcall(adapter.setup, opts)
    assert.is_false(ok)
    return tostring(err)
  end

  it("accepts a fully specified config", function()
    local adapter = require("neotest-nix")
    assert.has_no.errors(function()
      adapter.setup({
        parser_runtime_paths = { "/tmp/nix-parser" },
        discover_eval_checks = true,
        eval_outputs = { { attr = "checks", match = "^test" } },
        nix_unit_flakes = { { path = "lib/tests", flake = ".#tests" } },
        nixpkgs_mode = true,
        discover_nixpkgs_eval_tests = true,
      })
    end)
  end)

  it("rejects a non-boolean discover_eval_checks", function()
    local adapter = require("neotest-nix")
    assert.has_error(function()
      ---@diagnostic disable-next-line: assign-type-mismatch
      adapter.setup({ discover_eval_checks = "yes" })
    end)
  end)

  it("rejects a non-boolean discover_nixpkgs_eval_tests", function()
    local adapter = require("neotest-nix")
    assert.has_error(function()
      ---@diagnostic disable-next-line: assign-type-mismatch
      adapter.setup({ discover_nixpkgs_eval_tests = "yes" })
    end)
  end)

  it("rejects a non-table eval_outputs", function()
    local adapter = require("neotest-nix")
    assert.has_error(function()
      ---@diagnostic disable-next-line: assign-type-mismatch
      adapter.setup({ eval_outputs = "checks" })
    end)
  end)

  it("rejects non-string parser_runtime_paths entries", function()
    local err = setup_error({
      ---@diagnostic disable-next-line: assign-type-mismatch
      parser_runtime_paths = { 42 },
    })

    assert.is_truthy(err:find("parser_runtime_paths[1]", 1, true))
  end)

  it("rejects non-table eval_outputs entries", function()
    local err = setup_error({
      ---@diagnostic disable-next-line: assign-type-mismatch
      eval_outputs = { false },
    })

    assert.is_truthy(err:find("eval_outputs[1]", 1, true))
  end)

  it("rejects eval_outputs entries without an attr", function()
    local err = setup_error({
      ---@diagnostic disable-next-line: missing-fields
      eval_outputs = { { match = "^test" } },
    })

    assert.is_truthy(err:find("eval_outputs[1].attr", 1, true))
  end)

  it("rejects non-table nix_unit_flakes entries", function()
    local err = setup_error({
      ---@diagnostic disable-next-line: assign-type-mismatch
      nix_unit_flakes = { false },
    })

    assert.is_truthy(err:find("nix_unit_flakes[1]", 1, true))
  end)

  it("rejects nix_unit_flakes entries without a flake", function()
    local err = setup_error({
      ---@diagnostic disable-next-line: missing-fields
      nix_unit_flakes = { { path = "lib/tests" } },
    })

    assert.is_truthy(err:find("nix_unit_flakes[1].flake", 1, true))
  end)
end)

describe("config options reach discovery", function()
  local notify, system

  before_each(function()
    package.loaded["neotest-nix"] = nil
    vim.opt.runtimepath:prepend(vim.fn.getcwd())

    notify = vim.notify
    vim.notify = function() end

    -- Stub the tree-sitter pass so discovery does not require a parser, and so
    -- discover_positions returns a non-nil tree and proceeds to the eval gate.
    package.loaded["neotest.lib"] = {
      treesitter = {
        parse_positions = function()
          return { _fake_tree = true }
        end,
      },
    }
  end)

  after_each(function()
    vim.notify = notify
    if system ~= nil then
      vim.system = system
      system = nil
    end
    package.loaded["neotest.lib"] = nil
    package.loaded["neotest-nix"] = nil
  end)

  ---@return string[][] recorded vim.system command argument lists
  local function record_system_commands()
    system = vim.system
    local commands = {}
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.system = function(cmd, _opts, cb)
      table.insert(commands, cmd)
      local result = { code = 1, stdout = "", stderr = "" }
      if cb ~= nil then
        cb(result)
      end
      return {
        wait = function()
          return result
        end,
      }
    end
    return commands
  end

  ---@param commands string[][]
  ---@return integer
  local function nix_eval_count(commands)
    local count = 0
    for _, cmd in ipairs(commands) do
      if cmd[1] == "nix" and cmd[2] == "eval" then
        count = count + 1
      end
    end
    return count
  end

  it("does not evaluate the flake when discover_eval_checks is unset", function()
    local commands = record_system_commands()
    local adapter = require("neotest-nix").setup({})

    adapter.discover_positions(flake_fixture)

    assert.are.equal(0, nix_eval_count(commands))
  end)

  it("evaluates the flake when discover_eval_checks is enabled", function()
    local commands = record_system_commands()
    local adapter = require("neotest-nix").setup({ discover_eval_checks = true })

    adapter.discover_positions(flake_fixture)

    assert.is_true(nix_eval_count(commands) > 0)
  end)

  it("forwards parser_runtime_paths to the parser loader", function()
    local parser = require("neotest-nix.parser")
    local original = parser.ensure_nix_parser
    local captured
    ---@diagnostic disable-next-line: duplicate-set-field
    parser.ensure_nix_parser = function(roots)
      captured = roots
    end

    local roots = { "/tmp/nix-parser-a", "/tmp/nix-parser-b" }
    local adapter = require("neotest-nix").setup({ parser_runtime_paths = roots })
    adapter.discover_positions(flake_fixture)

    parser.ensure_nix_parser = original
    assert.same(roots, captured)
  end)

  it("uses the latest configuration when reconfigured (single instance)", function()
    local commands = record_system_commands()
    local adapter = require("neotest-nix")

    adapter.setup({ discover_eval_checks = true })
    adapter.setup({})
    adapter.discover_positions(flake_fixture)

    assert.are.equal(0, nix_eval_count(commands))
  end)
end)
