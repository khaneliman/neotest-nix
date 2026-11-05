local cache = require("neotest-nix.cache")

local function write_file(path, content)
  local file = assert(io.open(path, "w"))
  assert(file:write(content))
  assert(file:close())
end

describe("cache", function()
  local paths

  before_each(function()
    paths = {}
    cache.clear_source_cache()
  end)

  after_each(function()
    cache.clear_source_cache()
    for _, path in ipairs(paths) do
      vim.fn.delete(path)
    end
  end)

  it("reads through and retains small sources", function()
    local path = vim.fn.tempname()
    table.insert(paths, path)
    write_file(path, "{ test = 1; }\n")

    local original_io_open = io.open
    local reads = 0
    rawset(io, "open", function(file_path, mode)
      if file_path == path and mode == "r" then
        reads = reads + 1
      end
      return original_io_open(file_path, mode)
    end)
    finally(function()
      rawset(io, "open", original_io_open)
    end)

    assert.are.equal("{ test = 1; }\n", cache.read_source(path))
    assert.are.equal("{ test = 1; }\n", cache.read_source(path))
    assert.are.equal(1, reads)
  end)

  it("evicts least recently used sources within the memory bound", function()
    local source = string.rep("x", 64 * 1024)
    local original_io_open = io.open
    local reads = {}
    rawset(io, "open", function(file_path, mode)
      if mode == "r" then
        reads[file_path] = (reads[file_path] or 0) + 1
      end
      return original_io_open(file_path, mode)
    end)
    finally(function()
      rawset(io, "open", original_io_open)
    end)

    for _ = 1, 40 do
      local path = vim.fn.tempname()
      table.insert(paths, path)
      write_file(path, source)
      assert.are.equal(source, cache.read_source(path))
    end

    local first_path = paths[1]
    assert.are.equal(source, cache.read_source(first_path))
    assert.are.equal(2, reads[first_path])
  end)

  it("rejects an oversized source before opening it", function()
    local path = vim.fn.tempname()
    table.insert(paths, path)
    local source = string.rep("x", 512 * 1024 + 1)
    write_file(path, source)

    local original_io_open = io.open
    local reads = 0
    rawset(io, "open", function(file_path, mode)
      if file_path == path and mode == "r" then
        reads = reads + 1
      end
      return original_io_open(file_path, mode)
    end)
    finally(function()
      rawset(io, "open", original_io_open)
    end)

    local content, reason = cache.read_source(path)
    assert.is_nil(content and #content)
    assert.are.equal("too_large", reason)
    assert.is_nil(cache.read_source(path))
    assert.are.equal(0, reads)
  end)

  it("accepts empty sources and the exact source-size limit", function()
    for _, size in ipairs({ 0, 512 * 1024 - 1, 512 * 1024 }) do
      local path = vim.fn.tempname()
      table.insert(paths, path)
      local source = string.rep("x", size)
      write_file(path, source)
      assert.are.equal(source, cache.read_source(path))
      assert.are.equal(source, cache.read_source(path))
    end
  end)

  it("bounds reads and rejects a file that grows after stat", function()
    local path = vim.fn.tempname()
    table.insert(paths, path)
    write_file(path, "small")

    local original_io_open = io.open
    local closed = false
    rawset(io, "open", function(file_path, mode)
      if file_path ~= path or mode ~= "r" then
        return original_io_open(file_path, mode)
      end
      write_file(path, string.rep("x", 512 * 1024 + 100))
      local file = assert(original_io_open(file_path, mode))
      return {
        read = function(_, count)
          assert.are.equal(512 * 1024 + 1, count)
          return file:read(count)
        end,
        close = function()
          closed = true
          return file:close()
        end,
      }
    end)
    finally(function()
      rawset(io, "open", original_io_open)
    end)

    local content, reason = cache.read_source(path)
    assert.is_nil(content and #content)
    assert.are.equal("too_large", reason)
    assert.is_true(closed)
  end)

  it("does not turn a read error into an empty cached source", function()
    local path = vim.fn.tempname()
    table.insert(paths, path)
    write_file(path, "small")
    local original_io_open = io.open
    local closed = false
    rawset(io, "open", function(file_path, mode)
      if file_path == path and mode == "r" then
        return {
          read = function()
            return nil, "read failed"
          end,
          close = function()
            closed = true
          end,
        }
      end
      return original_io_open(file_path, mode)
    end)
    finally(function()
      rawset(io, "open", original_io_open)
    end)

    assert.is_nil(cache.read_source(path))
    assert.is_true(closed)
    rawset(io, "open", original_io_open)
    assert.are.equal("small", cache.read_source(path))
  end)
end)
