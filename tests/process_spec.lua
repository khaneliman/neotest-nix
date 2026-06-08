local nio = require("nio")
local process = require("neotest-nix.process")

describe("process", function()
  it("runs commands with vim.system and streams output", function()
    local done = false
    local failed

    nio.run(function()
      local proc = process.strategy({
        command = { "sh", "-c", "printf 'hello'; printf ' error' >&2; exit 7" },
      })
      local stream = proc.output_stream()
      local first = stream()
      local code = proc.result()
      local output_path = proc.output()
      local file = assert(io.open(output_path, "r"))
      local output = file:read("*a")
      file:close()

      local ok, err = pcall(function()
        assert.are.equal(7, code)
        assert.is_true(first == "hello" or first == " error")
        assert.is_true(output:find("hello", 1, true) ~= nil)
        assert.is_true(output:find(" error", 1, true) ~= nil)
        assert.is_true(proc.is_complete())
      end)
      failed = not ok and err or nil
      done = true
    end)

    vim.wait(1000, function()
      return done
    end)
    assert.is_nil(failed)
    assert.is_true(done)
  end)

  it("reports spawn failures as failed process output", function()
    local done = false
    local failed

    nio.run(function()
      local proc = process.strategy({
        command = { "__neotest_nix_missing_command__" },
      })
      local code = proc.result()
      local output_path = proc.output()
      local file = assert(io.open(output_path, "r"))
      local output = file:read("*a")
      file:close()

      local ok, err = pcall(function()
        assert.are.equal(1, code)
        assert.are.equal(
          "neotest-nix: failed to start `__neotest_nix_missing_command__`: "
            .. "executable not found on PATH",
          output
        )
        assert.is_true(proc.is_complete())
      end)
      failed = not ok and err or nil
      done = true
    end)

    vim.wait(1000, function()
      return done
    end)
    assert.is_nil(failed)
    assert.is_true(done)
  end)
end)
