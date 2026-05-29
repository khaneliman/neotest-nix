local discover = require("neotest-nix.discover")

local function mkdir(path)
  vim.fn.mkdir(path, "p")
end

local function write_file(path, lines)
  vim.fn.writefile(lines, path)
end

describe("discover", function()
  local tmp

  before_each(function()
    tmp = vim.fn.tempname()
    mkdir(tmp)
  end)

  it("finds the nearest flake root", function()
    local project = vim.fs.joinpath(tmp, "project")
    local nested = vim.fs.joinpath(project, "tests", "unit")
    mkdir(nested)
    write_file(vim.fs.joinpath(project, "flake.nix"), { "{}" })

    assert.are.equal(project, discover.root(nested))
    assert.are.equal(project, discover.root(vim.fs.joinpath(nested, "example_test.nix")))
  end)

  it("matches flake and nix test files", function()
    assert.is_true(discover.is_test_file("/workspace/flake.nix"))
    assert.is_true(discover.is_test_file("/workspace/foo_test.nix"))
    assert.is_true(discover.is_test_file("/workspace/foo_test_bar.nix"))
    assert.is_true(discover.is_test_file("/workspace/FooTest.nix"))
    assert.is_false(discover.is_test_file("/workspace/default.nix"))
    assert.is_false(discover.is_test_file("/workspace/testdata.lua"))
  end)

  it("filters store, git, and build output directories", function()
    assert.is_false(discover.filter_dir(".git", ".git", tmp))
    assert.is_false(discover.filter_dir("result", "result", tmp))
    assert.is_false(discover.filter_dir("result-docs", "result-docs", tmp))
    assert.is_false(discover.filter_dir("source", "source", "/nix/store/hash-source"))
    assert.is_true(discover.filter_dir("tests", "tests", tmp))
  end)
end)
