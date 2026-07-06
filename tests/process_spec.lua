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

  it("streams every chunk from a process that exits immediately after emitting", function()
    local done = false
    local failed
    local line_count = 200

    nio.run(function()
      local proc = process.strategy({
        command = {
          "sh",
          "-c",
          ("i=1; while [ $i -le %d ]; do echo line$i; i=$((i+1)); done"):format(line_count),
        },
      })
      local stream = proc.output_stream()
      local chunks = {}
      local chunk = stream()
      while chunk ~= nil do
        chunks[#chunks + 1] = chunk
        chunk = stream()
      end
      local code = proc.result()

      local ok, err = pcall(function()
        assert.are.equal(0, code)
        local streamed = table.concat(chunks)
        local seen = 0
        for _ in streamed:gmatch("line%d+\n") do
          seen = seen + 1
        end
        assert.are.equal(line_count, seen)
        assert.is_nil(stream())
        assert.is_true(proc.is_complete())
      end)
      failed = not ok and err or nil
      done = true
    end)

    vim.wait(2000, function()
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

  it("reports output file open failures as a completed process", function()
    local done = false
    local failed

    nio.run(function()
      local original_tempname = nio.fn.tempname
      local missing_path = vim.fs.joinpath(vim.fn.tempname(), "missing", "output")
      nio.fn.tempname = function()
        return missing_path
      end

      local ok, proc = pcall(process.strategy, {
        command = { "sh", "-c", "exit 0" },
      })
      nio.fn.tempname = original_tempname

      local stream = ok and proc.output_stream() or nil
      local message = stream and stream() or nil
      local ok_assert, err = pcall(function()
        assert.is_true(ok)
        if not ok then
          error(proc)
        end
        if stream == nil or message == nil then
          error("missing completed failure stream")
        end
        assert.are.equal(1, proc.result())
        assert.is_true(proc.is_complete())
        assert.is_truthy(message:find("failed to open output file", 1, true))
        assert.is_truthy(message:find(missing_path, 1, true))
        assert.are.equal(message, proc.output())
        assert.is_nil(stream())
      end)
      failed = not ok_assert and err or nil
      done = true
    end)

    vim.wait(1000, function()
      return done
    end)
    assert.is_nil(failed)
    assert.is_true(done)
  end)
end)
