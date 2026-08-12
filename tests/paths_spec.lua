local paths = require("neotest-nix.paths")

local store_files = {}
local original_fs_lstat
local original_io_open

local function write(path, content)
  local file = assert(original_io_open(path, "wb"))
  file:write(content)
  file:close()
end

local function store_file(name, content)
  local path = "/nix/store/" .. name
  local backing = vim.fn.tempname()
  write(backing, content)
  store_files[path] = backing
  return path
end

local function project()
  local root = vim.fn.tempname()
  vim.fn.mkdir(vim.fs.joinpath(root, "checks"), "p")
  vim.fn.writefile({ "{}" }, vim.fs.joinpath(root, "checks", "unit.nix"))
  return root
end

describe("paths", function()
  before_each(function()
    store_files = {}
    original_fs_lstat = vim.uv.fs_lstat
    original_io_open = rawget(io, "open")
    vim.uv.fs_lstat = function(path)
      return original_fs_lstat(store_files[path] or path)
    end
    rawset(io, "open", function(path, mode)
      return original_io_open(store_files[path] or path, mode)
    end)
  end)

  after_each(function()
    vim.uv.fs_lstat = original_fs_lstat
    rawset(io, "open", original_io_open)
    for _, backing in pairs(store_files) do
      vim.fn.delete(backing, "rf")
    end
  end)

  it("translates source store paths to local files", function()
    local root = project()
    local store_path = store_file("abc123-source/checks/unit.nix", "{}\n")

    assert.are.equal(
      vim.fs.joinpath(root, "checks", "unit.nix"),
      paths.translate_store_path(store_path, root)
    )
  end)

  it("leaves missing reconstructed files unchanged", function()
    local root = project()
    local store_path = store_file("abc123-source/checks/missing.nix", "{}\n")

    assert.are.equal(store_path, paths.translate_store_path(store_path, root))
  end)

  it("translates non-source store paths to local files", function()
    local root = project()
    local store_path = store_file("abc123-neotest-nix/checks/unit.nix", "{}\n")

    assert.are.equal(
      vim.fs.joinpath(root, "checks", "unit.nix"),
      paths.translate_store_path(store_path, root)
    )
  end)

  it("translates store paths embedded in output strings", function()
    local root = project()
    local local_path = vim.fs.joinpath(root, "checks", "unit.nix")
    local store_path = store_file("abc123-source/checks/unit.nix", "{}\n")
    local output = "error: " .. store_path .. ":2:3: failed"

    assert.are.equal(
      "error: " .. local_path .. ":2:3: failed",
      paths.translate_string(output, root)
    )
  end)

  it("translates store paths with line and column suffixes", function()
    local root = project()
    local local_path = vim.fs.joinpath(root, "checks", "unit.nix")
    local store_path = store_file("abc123-neotest-nix/checks/unit.nix", "{}\n")
    local output = "error: " .. store_path .. ":2:3: failed"

    assert.are.equal(
      "error: " .. local_path .. ":2:3: failed",
      paths.translate_string(output, root)
    )
  end)

  it("translates quoted store paths embedded in output strings", function()
    local root = project()
    local local_path = vim.fs.joinpath(root, "checks", "unit.nix")
    local store_path = store_file("abc123-source/checks/unit.nix", "{}\n")
    local output = 'error: "' .. store_path .. '":2:3'

    assert.are.equal('error: "' .. local_path .. '":2:3', paths.translate_string(output, root))
  end)

  it("translates parenthesized store paths embedded in output strings", function()
    local root = project()
    local local_path = vim.fs.joinpath(root, "checks", "unit.nix")
    local store_path = store_file("abc123-source/checks/unit.nix", "{}\n")
    local output = "error: (" .. store_path .. ")"

    assert.are.equal("error: (" .. local_path .. ")", paths.translate_string(output, root))
  end)

  it("translates comma-punctuated store paths embedded in output strings", function()
    local root = project()
    local local_path = vim.fs.joinpath(root, "checks", "unit.nix")
    local store_path = store_file("abc123-source/checks/unit.nix", "{}\n")
    local output = "trace: " .. store_path .. ", failed"

    assert.are.equal("trace: " .. local_path .. ", failed", paths.translate_string(output, root))
  end)

  it("mutates nested result tables", function()
    local root = project()
    local store_path = store_file("abc123-source/checks/unit.nix", "{}\n")
    local result = {
      output = "trace: " .. store_path,
      errors = {
        {
          message = "failed",
          path = store_path,
        },
      },
    }

    assert.are.same(result, paths.translate_result_paths(result, root))
    assert.are.equal(vim.fs.joinpath(root, "checks", "unit.nix"), result.errors[1].path)
    assert.are.equal("trace: " .. vim.fs.joinpath(root, "checks", "unit.nix"), result.output)
  end)

  it("preserves same-size files with different content", function()
    local root = project()
    local store_path = store_file("abc123-source/checks/unit.nix", "[]\n")

    assert.are.equal(store_path, paths.translate_store_path(store_path, root))
  end)

  it("preserves files with different sizes", function()
    local root = project()
    local store_path = store_file("abc123-source/checks/unit.nix", "longer\n")

    assert.are.equal(store_path, paths.translate_store_path(store_path, root))
  end)

  it("compares content across chunk boundaries", function()
    local root = project()
    local content = string.rep("a", 64 * 1024) .. "tail"
    local local_path = vim.fs.joinpath(root, "checks", "large.nix")
    write(local_path, content)
    local store_path = store_file("abc123-source/checks/large.nix", content)

    assert.are.equal(local_path, paths.translate_store_path(store_path, root))
  end)

  it("compares binary content byte for byte", function()
    local root = project()
    local content = "before\0after\255"
    local local_path = vim.fs.joinpath(root, "checks", "binary.nix")
    write(local_path, content)
    local store_path = store_file("abc123-source/checks/binary.nix", content)

    assert.are.equal(local_path, paths.translate_store_path(store_path, root))
  end)

  it("translates identical empty files", function()
    local root = project()
    local local_path = vim.fs.joinpath(root, "checks", "empty.nix")
    write(local_path, "")
    local store_path = store_file("abc123-source/checks/empty.nix", "")

    assert.are.equal(local_path, paths.translate_store_path(store_path, root))
  end)

  it("preserves paths when either entry is not a regular file", function()
    local root = project()
    local local_path = vim.fs.joinpath(root, "checks", "linked.nix")
    assert(vim.uv.fs_symlink(vim.fs.joinpath(root, "checks", "unit.nix"), local_path))
    local store_path = store_file("abc123-source/checks/linked.nix", "{}\n")

    assert.are.equal(store_path, paths.translate_store_path(store_path, root))
  end)

  it("preserves store symlinks even when their targets match", function()
    local root = project()
    local store_path = store_file("abc123-source/checks/unit.nix", "{}\n")
    local backing = store_files[store_path]
    local link = vim.fn.tempname()
    assert(vim.uv.fs_symlink(backing, link))
    store_files[store_path] = link

    assert.are.equal(store_path, paths.translate_store_path(store_path, root))
    vim.fn.delete(backing)
  end)

  it("preserves paths when a file cannot be opened", function()
    local root = project()
    local store_path = store_file("abc123-source/checks/unit.nix", "{}\n")
    local store_backing = store_files[store_path]
    rawset(io, "open", function(path, mode)
      if path == store_path or path == store_backing then
        return nil, "permission denied"
      end
      return original_io_open(path, mode)
    end)

    assert.are.equal(store_path, paths.translate_store_path(store_path, root))
  end)

  it("preserves paths when a file cannot be read", function()
    local root = project()
    local store_path = store_file("abc123-source/checks/unit.nix", "{}\n")
    local store_backing = store_files[store_path]
    rawset(io, "open", function(path, mode)
      if path == store_path or path == store_backing then
        return {
          close = function() end,
          read = function()
            return nil, "read failed"
          end,
        }
      end
      return original_io_open(path, mode)
    end)

    assert.are.equal(store_path, paths.translate_store_path(store_path, root))
  end)
end)
