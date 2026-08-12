-- Forces process setup failure through public Neotest orchestration. The
-- multi-position flake proves every running position receives a final result.
local nio = require("nio")
local results_module = require("neotest-nix.results")
local helpers = dofile(vim.fs.joinpath(vim.fn.getcwd(), "tests", "integration", "helpers.lua"))

if not helpers.enabled then
  describe("process failure orchestration integration", function()
    it("skips without NEOTEST_NIX_INTEGRATION=1", function()
      ---@diagnostic disable-next-line: missing-parameter
      pending("set NEOTEST_NIX_INTEGRATION=1 to run real-tool integration specs")
    end)
  end)
  return
end

describe("process failure orchestration integration", function()
  it("publishes exact failures for every position", function()
    local original_cwd = assert(vim.uv.cwd())
    local root, cleanup = helpers.materialize_fixture("integration-flake")
    local config_path = vim.fs.joinpath(root, "flake.nix")
    local missing_path = vim.fs.joinpath(root, "missing", "output")
    local real_tempname = nio.fn.tempname
    local real_stream = results_module.stream
    local output_file
    local stream_attached = false
    local stream_finished = false

    finally(function()
      nio.fn.tempname = real_tempname
      results_module.stream = real_stream
      vim.api.nvim_set_current_dir(original_cwd)
      if output_file ~= nil then
        output_file:close()
        vim.fn.delete(missing_path)
      end
      cleanup()
    end)
    vim.api.nvim_set_current_dir(root)

    local open_error
    output_file, open_error = io.open(missing_path, "w")
    assert.is_nil(output_file)
    local expected = ("neotest-nix: failed to open output file `%s`: %s"):format(
      missing_path,
      open_error
    )

    results_module.stream = function(spec, tree)
      stream_attached = true
      local stream_factory = real_stream(spec, tree)
      return function(output_stream)
        local iterator = stream_factory(output_stream)
        return function()
          local streamed = iterator()
          if streamed == nil then
            stream_finished = true
          end
          return streamed
        end
      end
    end

    local client
    local adapter_id
    local final_results
    local position_ids
    local function output_failure_probe(neotest_client)
      client = neotest_client
      client.listeners.run = function(observed_adapter_id, root_id, observed_position_ids)
        if root_id == config_path then
          adapter_id = observed_adapter_id
          position_ids = observed_position_ids
        end
      end
      client.listeners.results = function(observed_adapter_id, results, partial)
        if not partial and results[config_path] ~= nil then
          adapter_id = observed_adapter_id
          final_results = results
        end
      end
      return {}
    end

    local neotest = require("neotest")
    ---@diagnostic disable-next-line: missing-fields
    neotest.setup({
      adapters = { require("neotest-nix")({}) },
      consumers = { output_failure_probe = output_failure_probe },
      discovery = { enabled = true, concurrent = 1 },
      running = { concurrent = false },
    })

    nio.fn.tempname = function()
      return missing_path
    end
    neotest.run.run(config_path)
    local completed = vim.wait(5000, function()
      return final_results ~= nil and (not stream_attached or stream_finished)
    end, 20)

    assert.is_true(completed)
    assert.is_true(stream_attached)
    assert.is_true(stream_finished)
    assert.is_not_nil(position_ids)
    assert.is_true(#position_ids > 1)
    for _, position_id in ipairs(position_ids) do
      assert.are.equal("failed", final_results[position_id].status)
      assert.is_nil(final_results[position_id].output)
      assert.is_false(client:is_running(position_id, { adapter = adapter_id }))
    end
    assert.are.equal(expected, final_results[config_path].short)
  end)
end)
