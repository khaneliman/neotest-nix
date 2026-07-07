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

  it("roots non-flake test files at the nearest git root by default", function()
    local project = vim.fs.joinpath(tmp, "project")
    local tests = vim.fs.joinpath(project, "tests")
    mkdir(vim.fs.joinpath(project, ".git"))
    mkdir(tests)
    local path = vim.fs.joinpath(tests, "default.nix")
    write_file(path, { "{", "  testFoo = { expr = 1; expected = 1; };", "}" })

    assert.are.equal(project, discover.root(path))
    assert.is_true(discover.is_test_file(path))
  end)

  it("falls back to the file parent for recognized non-flake tests without git", function()
    local tests = vim.fs.joinpath(tmp, "tests")
    mkdir(tests)
    local path = vim.fs.joinpath(tests, "default.nix")
    write_file(path, { "{", "  testFoo = { expr = 1; expected = 1; };", "}" })

    assert.are.equal(tests, discover.root(path))
  end)

  it("keeps flake-only behavior when non_flake_roots is false", function()
    local tests = vim.fs.joinpath(tmp, "tests")
    mkdir(tests)
    local path = vim.fs.joinpath(tests, "default.nix")
    write_file(path, { "{", "  testFoo = { expr = 1; expected = 1; };", "}" })

    assert.is_nil(discover.root(path, { non_flake_roots = false }))
    assert.is_false(discover.is_test_file(path, { non_flake_roots = false }))
  end)

  it("roots Namaka files at namaka.toml and prunes snapshots", function()
    local project = vim.fs.joinpath(tmp, "namaka")
    local case = vim.fs.joinpath(project, "tests", "math")
    local snapshots = vim.fs.joinpath(project, "tests", "_snapshots", "math")
    mkdir(case)
    mkdir(snapshots)
    local config = vim.fs.joinpath(project, "namaka.toml")
    local expr = vim.fs.joinpath(case, "expr.nix")
    local snapshot_expr = vim.fs.joinpath(snapshots, "expr.nix")
    write_file(config, { "[namaka]" })
    write_file(expr, { "1 + 1" })
    write_file(snapshot_expr, { "2" })

    assert.are.equal(project, discover.root(expr))
    assert.is_true(discover.is_test_file(config))
    assert.is_true(discover.is_test_file(expr))
    assert.is_false(discover.is_test_file(snapshot_expr))
    assert.is_false(discover.filter_dir("_snapshots", "tests/_snapshots", project))
  end)

  it("does not classify Namaka expr files when non_flake_roots is false", function()
    local project = vim.fs.joinpath(tmp, "namaka")
    local case = vim.fs.joinpath(project, "tests", "math")
    mkdir(case)
    write_file(vim.fs.joinpath(project, "namaka.toml"), { "[namaka]" })
    local expr = vim.fs.joinpath(case, "expr.nix")
    write_file(expr, { "1 + 1" })

    assert.is_nil(discover.root(expr, { non_flake_roots = false }))
    assert.is_false(discover.is_test_file(expr, { non_flake_roots = false }))
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

  it("keeps code inside string interpolation while stripping nested strings", function()
    local nested_string_keywords = {
      "{",
      '  fixture = "prefix ${let x = "expr = 1; expected = 1;"; in x} suffix";',
      "}",
    }
    local interpolated_assertion = {
      "{",
      '  fixture = "prefix ${ { testInterpolated = { expr = 1; expected = 1; }; } } suffix";',
      "}",
    }

    write_file(vim.fs.joinpath(tmp, "nested-string_test.nix"), nested_string_keywords)
    write_file(vim.fs.joinpath(tmp, "interpolated-assertion_test.nix"), interpolated_assertion)

    assert.is_false(discover.is_test_file(vim.fs.joinpath(tmp, "nested-string_test.nix")))
    assert.is_true(discover.is_test_file(vim.fs.joinpath(tmp, "interpolated-assertion_test.nix")))
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
    -- lib and nixos are descended only as far as their tests subtrees.
    assert.is_true(discover.filter_dir("lib", "lib", tmp))
    assert.is_true(discover.filter_dir("tests", "lib/tests", tmp))
    assert.is_true(discover.filter_dir("tests", "nixos/tests", tmp))
    assert.is_false(discover.filter_dir("modules", "nixos/modules", tmp))

    -- nixpkgs_mode = false keeps the default behaviour (no pruning).
    assert.is_true(
      discover.filter_dir("development", "pkgs/development", tmp, { nixpkgs_mode = false })
    )
  end)

  it("recognizes lib and nixos test files in a Nixpkgs checkout", function()
    vim.fn.mkdir(vim.fs.joinpath(tmp, "lib", "tests"), "p")
    vim.fn.mkdir(vim.fs.joinpath(tmp, "nixos", "tests"), "p")
    mkdir(vim.fs.joinpath(tmp, "pkgs", "by-name"))

    local release = vim.fs.joinpath(tmp, "lib", "tests", "release.nix")
    local nixos = vim.fs.joinpath(tmp, "nixos", "tests", "login.nix")
    local helper = vim.fs.joinpath(tmp, "nixos", "tests", "make-test-python.nix")
    write_file(release, { "{ }" })
    write_file(nixos, { '{ testScript = ""; }' })
    write_file(helper, { "{ }" })

    assert.is_true(discover.is_test_file(release))
    assert.is_true(discover.is_test_file(nixos))
    -- infrastructure files are not tests
    assert.is_false(discover.is_test_file(helper))
  end)

  it("roots a nested sub-flake at the Nixpkgs top", function()
    -- Nixpkgs ships `lib/flake.nix`. Walking to the nearest flake.nix would
    -- root files under lib/ at that sub-flake, splitting the tree into a second
    -- adapter root. They must collapse to the Nixpkgs top instead.
    vim.fn.mkdir(vim.fs.joinpath(tmp, "lib", "tests"), "p")
    vim.fn.mkdir(vim.fs.joinpath(tmp, "nixos"), "p")
    mkdir(vim.fs.joinpath(tmp, "pkgs", "by-name"))
    write_file(vim.fs.joinpath(tmp, "flake.nix"), { "{}" })
    write_file(vim.fs.joinpath(tmp, "lib", "flake.nix"), { "{}" })

    local misc = vim.fs.joinpath(tmp, "lib", "tests", "misc.nix")
    write_file(misc, { "{ }" })

    assert.are.equal(tmp, discover.root(misc))
    assert.are.equal(tmp, discover.root(vim.fs.joinpath(tmp, "lib", "flake.nix")))
  end)

  it("does not treat flake.nix as a test file inside a Nixpkgs checkout", function()
    -- The root flake and any nested sub-flake would otherwise be claimed by the
    -- flake.nix short-circuit and run `nix flake check` over the whole tree.
    vim.fn.mkdir(vim.fs.joinpath(tmp, "lib"), "p")
    vim.fn.mkdir(vim.fs.joinpath(tmp, "nixos"), "p")
    mkdir(vim.fs.joinpath(tmp, "pkgs", "by-name"))
    local root_flake = vim.fs.joinpath(tmp, "flake.nix")
    local sub_flake = vim.fs.joinpath(tmp, "lib", "flake.nix")
    write_file(root_flake, { "{}" })
    write_file(sub_flake, { "{}" })

    assert.is_false(discover.is_test_file(root_flake))
    assert.is_false(discover.is_test_file(sub_flake))

    -- A plain flake project keeps the flake.nix-is-a-test-file behaviour.
    local plain = vim.fn.tempname()
    mkdir(plain)
    local plain_flake = vim.fs.joinpath(plain, "flake.nix")
    write_file(plain_flake, { "{}" })
    assert.is_true(discover.is_test_file(plain_flake))
  end)

  it("uses legacy lib discovery instead of generic nix-unit inside a Nixpkgs checkout", function()
    vim.fn.mkdir(vim.fs.joinpath(tmp, "lib", "tests"), "p")
    vim.fn.mkdir(vim.fs.joinpath(tmp, "nixos"), "p")
    mkdir(vim.fs.joinpath(tmp, "pkgs", "by-name"))

    local fetchers = vim.fs.joinpath(tmp, "lib", "tests", "fetchers.nix")
    local helper = vim.fs.joinpath(tmp, "lib", "tests", "helper.nix")
    write_file(fetchers, { "let runTests = x: x; in runTests [ ]" })
    write_file(helper, { "{", "  testFoo = {", "    expr = 1;", "    expected = 1;", "  };", "}" })

    assert.is_true(discover.is_test_file(fetchers))
    -- A nix-unit-shaped helper under lib/tests would match the generic path
    -- (parent dir is "tests"), but in a Nixpkgs checkout it must not be claimed:
    -- that is what triggered a getFlake evaluation of the whole tree.
    assert.is_false(discover.is_test_file(helper))
  end)

  it("falls back to a bare `runTests` call when no expr/expected keyword is present", function()
    local tests_dir = vim.fs.joinpath(tmp, "tests")
    mkdir(tests_dir)

    -- Test bodies built through a shared helper defined elsewhere: neither
    -- "expr" nor "expected"/"expectedError" appears literally in this file,
    -- only the `runTests` call itself.
    local helper_based = {
      "let",
      "  lib = (import <nixpkgs> { }).lib;",
      "in",
      "lib.runTests (mkCases [ 1 2 3 ])",
    }
    write_file(vim.fs.joinpath(tests_dir, "default.nix"), helper_based)
    assert.is_true(discover.is_test_file(vim.fs.joinpath(tests_dir, "default.nix")))

    local no_run_tests = { "{", "  foo = 1;", "}" }
    write_file(vim.fs.joinpath(tests_dir, "plain.nix"), no_run_tests)
    assert.is_false(discover.is_test_file(vim.fs.joinpath(tests_dir, "plain.nix")))
  end)

  it("ignores a `runTests` mention inside a comment for the fallback", function()
    local tests_dir = vim.fs.joinpath(tmp, "tests")
    mkdir(tests_dir)

    local commented = {
      "{",
      "  # lib.runTests (mkCases [ 1 2 3 ])",
      "  foo = 1;",
      "}",
    }
    write_file(vim.fs.joinpath(tests_dir, "commented.nix"), commented)
    assert.is_false(discover.is_test_file(vim.fs.joinpath(tests_dir, "commented.nix")))
  end)
end)
