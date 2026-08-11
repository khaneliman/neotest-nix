-- Drives a passing fixture through Neotest itself. Other integration specs call
-- adapter discovery, spec, strategy, and result hooks directly; this one proves
-- registration, Neotest client discovery, run orchestration, and final result
-- publication compose correctly with the real Namaka executable.
local helpers = dofile(vim.fs.joinpath(vim.fn.getcwd(), "tests", "integration", "helpers.lua"))

if not helpers.enabled then
  describe("Neotest orchestration integration", function()
    it("skips without NEOTEST_NIX_INTEGRATION=1", function()
      ---@diagnostic disable-next-line: missing-parameter
      pending("set NEOTEST_NIX_INTEGRATION=1 to run real-tool integration specs")
    end)
  end)
  return
end

if not helpers.has_executable("namaka") then
  describe("Neotest orchestration integration", function()
    it("skips: namaka not found", function()
      ---@diagnostic disable-next-line: missing-parameter
      pending("namaka not found on PATH; skipping Neotest orchestration integration spec")
    end)
  end)
  return
end

describe("Neotest orchestration integration (real namaka)", function()
  it("discovers and runs a passing project through Neotest", function()
    local root, cleanup = helpers.materialize_fixture("namaka-project")
    local config_path = vim.fs.joinpath(root, "namaka.toml")
    local original_cwd = assert(vim.uv.cwd())
    local final_result
    local system_command
    local system_cwd
    local system_process
    local system_complete = false
    local real_system = vim.system

    ---@diagnostic disable-next-line: duplicate-set-field
    vim.system = function(command, opts, on_exit)
      system_command = vim.deepcopy(command)
      system_cwd = opts.cwd
      system_process = real_system(command, opts, function(result)
        system_complete = true
        if on_exit then
          on_exit(result)
        end
      end)
      return system_process
    end

    finally(function()
      vim.system = real_system
      if system_process and not system_complete then
        system_process:kill(15)
        vim.wait(5000, function()
          return system_complete
        end, 20)
      end
      vim.api.nvim_set_current_dir(original_cwd)
      if final_result and final_result.output then
        vim.fn.delete(final_result.output)
      end
      cleanup()
    end)
    vim.api.nvim_set_current_dir(root)

    local observed = {
      adapter_id = nil,
      discovered = false,
      started = false,
    }
    local function orchestration_probe(client)
      client.listeners.discover_positions = function(adapter_id, tree)
        if tree:get_key(config_path) ~= nil then
          observed.adapter_id = adapter_id
          observed.discovered = true
        end
      end
      client.listeners.run = function(adapter_id, root_id, position_ids)
        if root_id == config_path and vim.tbl_contains(position_ids, config_path) then
          observed.adapter_id = adapter_id
          observed.started = true
        end
      end
      client.listeners.results = function(adapter_id, results, partial)
        if not partial and results[config_path] ~= nil then
          observed.adapter_id = adapter_id
          final_result = results[config_path]
        end
      end
      return {}
    end

    local neotest = require("neotest")
    ---@diagnostic disable-next-line: missing-fields
    neotest.setup({
      adapters = { require("neotest-nix")({}) },
      consumers = { orchestration_probe = orchestration_probe },
      discovery = { enabled = true, concurrent = 1 },
      running = { concurrent = false },
    })

    neotest.run.run(config_path)
    local completed = vim.wait(60000, function()
      return final_result ~= nil
    end, 20)

    assert.is_true(completed)
    assert.are.equal("neotest-nix:" .. root, observed.adapter_id)
    assert.is_true(observed.discovered)
    assert.is_true(observed.started)
    assert.same({ "namaka", "check" }, system_command)
    assert.are.equal(root, system_cwd)
    assert.are.equal("passed", final_result.status)
    assert.is_truthy(final_result.short:find("All 1 tests succeeded", 1, true))
  end)
end)
