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

  it("matches flake and nix-unit test files", function()
    local nix_unit = { "{", "  testFoo = {", "    expr = 1;", "    expected = 1;", "  };", "}" }
    local empty = { "{ }" }

    write_file(vim.fs.joinpath(tmp, "flake.nix"), empty)
    write_file(vim.fs.joinpath(tmp, "foo_test.nix"), nix_unit)
    write_file(vim.fs.joinpath(tmp, "FooTest.nix"), nix_unit)
    write_file(vim.fs.joinpath(tmp, "test-fixture.nix"), empty)
    write_file(vim.fs.joinpath(tmp, "default.nix"), nix_unit)

    -- flake.nix always counts, regardless of contents
    assert.is_true(discover.is_test_file(vim.fs.joinpath(tmp, "flake.nix")))
    -- test-named files only count when they contain a nix-unit assertion
    assert.is_true(discover.is_test_file(vim.fs.joinpath(tmp, "foo_test.nix")))
    assert.is_true(discover.is_test_file(vim.fs.joinpath(tmp, "FooTest.nix")))
    assert.is_false(discover.is_test_file(vim.fs.joinpath(tmp, "test-fixture.nix")))
    -- non-test-named files never count, even with assertions
    assert.is_false(discover.is_test_file(vim.fs.joinpath(tmp, "default.nix")))
    assert.is_false(discover.is_test_file("/workspace/testdata.lua"))
  end)

  it("matches nix-unit files under a test-named directory", function()
    local nix_unit = { "{", "  testFoo = {", "    expr = 1;", "    expected = 1;", "  };", "}" }
    local empty = { "{ }" }

    local tests_dir = vim.fs.joinpath(tmp, "tests")
    mkdir(tests_dir)
    write_file(vim.fs.joinpath(tests_dir, "default.nix"), nix_unit)
    write_file(vim.fs.joinpath(tests_dir, "fixtures.nix"), empty)

    -- `tests/default.nix` is the common convention: the directory is
    -- test-named even though the file is not.
    assert.is_true(discover.is_test_file(vim.fs.joinpath(tests_dir, "default.nix")))
    -- still gated by the nix-unit content check
    assert.is_false(discover.is_test_file(vim.fs.joinpath(tests_dir, "fixtures.nix")))
  end)

  it("filters store, git, and build output directories", function()
    assert.is_false(discover.filter_dir(".git", ".git", tmp))
    assert.is_false(discover.filter_dir("result", "result", tmp))
    assert.is_false(discover.filter_dir("result-docs", "result-docs", tmp))
    assert.is_false(discover.filter_dir("source", "source", "/nix/store/hash-source"))
    assert.is_true(discover.filter_dir("tests", "tests", tmp))
  end)
end)
