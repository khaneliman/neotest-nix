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

  it("returns nil for missing relative paths instead of falling back to cwd", function()
    local cwd = vim.fn.getcwd()
    vim.fn.chdir(tmp)
    write_file(vim.fs.joinpath(tmp, "flake.nix"), { "{}" })

    local ok, err = pcall(function()
      assert.is_nil(discover.root("missing/path/example_test.nix"))
    end)

    vim.fn.chdir(cwd)
    if not ok then
      error(err)
    end
  end)

  it("finds the root for missing absolute paths under an existing flake", function()
    local project = vim.fs.joinpath(tmp, "project")
    mkdir(project)
    write_file(vim.fs.joinpath(project, "flake.nix"), { "{}" })

    assert.are.equal(
      project,
      discover.root(vim.fs.joinpath(project, "missing", "example_test.nix"))
    )
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

  it("accepts expectedError assertions and rejects expr alone", function()
    local expected_error = {
      "{",
      "  testThrows = {",
      '    expr = throw "boom";',
      '    expectedError.type = "ThrownError";',
      "  };",
      "}",
    }
    local expr_only = { "{", "  testFoo = {", "    expr = 1;", "  };", "}" }

    write_file(vim.fs.joinpath(tmp, "throws_test.nix"), expected_error)
    write_file(vim.fs.joinpath(tmp, "expr_test.nix"), expr_only)

    -- expr + expectedError is a valid nix-unit shape
    assert.is_true(discover.is_test_file(vim.fs.joinpath(tmp, "throws_test.nix")))
    -- expr without expected/expectedError is not
    assert.is_false(discover.is_test_file(vim.fs.joinpath(tmp, "expr_test.nix")))
  end)

  it("ignores nix-unit keywords in comments and strings", function()
    local commented_keywords = {
      "{",
      "  # test = { expr = 1; expected = 1; };",
      "}",
    }
    local string_keywords = {
      "{",
      "  testFixture = {",
      '    expr = "expected = 1;";',
      "  };",
      "}",
    }
    local block_comment_keywords = {
      "{",
      "  /* test = { expr = 1; expected = 1; }; */",
      "}",
    }

    write_file(vim.fs.joinpath(tmp, "commented_test.nix"), commented_keywords)
    write_file(vim.fs.joinpath(tmp, "stringed_test.nix"), string_keywords)
    write_file(vim.fs.joinpath(tmp, "block-commented_test.nix"), block_comment_keywords)

    assert.is_false(discover.is_test_file(vim.fs.joinpath(tmp, "commented_test.nix")))
    assert.is_false(discover.is_test_file(vim.fs.joinpath(tmp, "stringed_test.nix")))
    assert.is_false(discover.is_test_file(vim.fs.joinpath(tmp, "block-commented_test.nix")))
  end)

  it("ignores nix-unit keywords in indented string escapes", function()
    local escaped_quotes = {
      "{",
      "  fixture = ''",
      "    ''' expr = 1; expected = 1;",
      "  '';",
      "}",
    }
    local escaped_interpolation = {
      "{",
      "  fixture = ''",
      "    ''${expr = 1; expected = 1;}",
      "  '';",
      "}",
    }

    write_file(vim.fs.joinpath(tmp, "escaped-quotes_test.nix"), escaped_quotes)
    write_file(vim.fs.joinpath(tmp, "escaped-interpolation_test.nix"), escaped_interpolation)

    assert.is_false(discover.is_test_file(vim.fs.joinpath(tmp, "escaped-quotes_test.nix")))
    assert.is_false(discover.is_test_file(vim.fs.joinpath(tmp, "escaped-interpolation_test.nix")))
  end)

  it("filters store, git, and build output directories", function()
    assert.is_false(discover.filter_dir(".git", ".git", tmp))
    assert.is_false(discover.filter_dir("result", "result", tmp))
    assert.is_false(discover.filter_dir("result-docs", "result-docs", tmp))
    assert.is_false(discover.filter_dir("source", "source", "/nix/store/hash-source"))
    assert.is_true(discover.filter_dir("tests", "tests", tmp))
  end)

  it("recognizes a by-name package in a Nixpkgs checkout", function()
    vim.fn.mkdir(vim.fs.joinpath(tmp, "lib"), "p")
    vim.fn.mkdir(vim.fs.joinpath(tmp, "nixos"), "p")
    local pkg_dir = vim.fs.joinpath(tmp, "pkgs", "by-name", "he", "hello")
    mkdir(pkg_dir)
    local pkg = vim.fs.joinpath(pkg_dir, "package.nix")
    write_file(pkg, { "{ stdenv }:", "stdenv.mkDerivation { passthru.tests.x = { }; }" })

    -- A by-name package.nix that declares passthru.tests is a test file even
    -- without test-named paths or a nix-unit assertion.
    assert.is_true(discover.is_test_file(pkg))

    -- A by-name package with no tests is not a test file: gating it out keeps
    -- Nixpkgs' tens of thousands of testless packages out of the Neotest tree.
    local testless_dir = vim.fs.joinpath(tmp, "pkgs", "by-name", "pl", "plain")
    mkdir(testless_dir)
    local testless = vim.fs.joinpath(testless_dir, "package.nix")
    write_file(testless, { "{ stdenv }:", 'stdenv.mkDerivation { pname = "plain"; }' })
    assert.is_false(discover.is_test_file(testless))

    -- The same file in a plain (non-Nixpkgs) tree is not a test file.
    local plain_dir = vim.fn.tempname()
    mkdir(plain_dir)
    local plain = vim.fs.joinpath(plain_dir, "package.nix")
    write_file(plain, { "{ stdenv }:", "stdenv.mkDerivation { }" })
    assert.is_false(discover.is_test_file(plain))
  end)

  it("prunes unsupported directories on a Nixpkgs root", function()
    vim.fn.mkdir(vim.fs.joinpath(tmp, "lib"), "p")
    vim.fn.mkdir(vim.fs.joinpath(tmp, "nixos"), "p")
    mkdir(vim.fs.joinpath(tmp, "pkgs", "by-name"))

    assert.is_true(discover.filter_dir("pkgs", "pkgs", tmp))
    assert.is_true(discover.filter_dir("by-name", "pkgs/by-name", tmp))
    assert.is_false(discover.filter_dir("development", "pkgs/development", tmp))
    assert.is_false(discover.filter_dir("lib", "lib", tmp))

    -- nixpkgs_mode = false keeps the default behaviour (no pruning).
    assert.is_true(
      discover.filter_dir("development", "pkgs/development", tmp, { nixpkgs_mode = false })
    )
  end)
end)
