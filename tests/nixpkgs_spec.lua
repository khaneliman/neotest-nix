---@diagnostic disable: need-check-nil, missing-fields
local nixpkgs = require("neotest-nix.nixpkgs")

local function mkdir(path)
  vim.fn.mkdir(path, "p")
end

local function write_file(path, lines)
  mkdir(vim.fs.dirname(path))
  vim.fn.writefile(lines, path)
end

---Create a Nixpkgs-shaped tree (markers present) and return its root.
local function nixpkgs_tree()
  local root = vim.fn.tempname()
  mkdir(vim.fs.joinpath(root, "lib"))
  mkdir(vim.fs.joinpath(root, "nixos"))
  mkdir(vim.fs.joinpath(root, "pkgs", "by-name"))
  return root
end

---Write a `pkgs/by-name` package and return its path.
local function write_package(root, name, lines)
  local shard = name:sub(1, 2)
  local path = vim.fs.joinpath(root, "pkgs", "by-name", shard, name, "package.nix")
  write_file(path, lines)
  return path
end

---Map test-position name -> nixpkgs_attr from a discovered tree.
local function test_attrs(tree)
  local attrs = {}
  for _, position in tree:iter() do
    if position.type == "test" then
      attrs[position.name] = position.nixpkgs_attr
    end
  end
  return attrs
end

---Map eval test-position name -> full position from a discovered tree.
local function eval_tests(tree)
  local tests = {}
  for _, position in tree:iter() do
    if position.type == "test" then
      tests[position.name] = position
    end
  end
  return tests
end

describe("nixpkgs", function()
  describe("detect_root", function()
    it("walks up to a Nixpkgs-shaped root", function()
      local root = nixpkgs_tree()
      local pkg = write_package(root, "hello", { "{}" })

      assert.are.equal(vim.fs.normalize(root), nixpkgs.detect_root(pkg))
      assert.are.equal(vim.fs.normalize(root), nixpkgs.detect_root(root))
    end)

    it("requires the full marker combination", function()
      -- A plain flake repo (only flake.nix) is not Nixpkgs.
      local root = vim.fn.tempname()
      write_file(vim.fs.joinpath(root, "flake.nix"), { "{}" })
      assert.is_nil(nixpkgs.detect_root(vim.fs.joinpath(root, "flake.nix")))

      -- lib present but no pkgs/by-name is still not enough.
      local partial = vim.fn.tempname()
      mkdir(vim.fs.joinpath(partial, "lib"))
      mkdir(vim.fs.joinpath(partial, "nixos"))
      assert.is_nil(nixpkgs.detect_root(partial))
    end)

    it("accepts all-packages.nix in place of nixos/", function()
      local root = vim.fn.tempname()
      mkdir(vim.fs.joinpath(root, "lib"))
      mkdir(vim.fs.joinpath(root, "pkgs", "by-name"))
      write_file(vim.fs.joinpath(root, "pkgs", "top-level", "all-packages.nix"), { "{}" })
      assert.are.equal(vim.fs.normalize(root), nixpkgs.detect_root(root))
    end)
  end)

  describe("mode_for", function()
    it("auto-detects via markers and honours the override", function()
      local root = nixpkgs_tree()
      local plain = vim.fn.tempname()
      mkdir(plain)

      assert.are.equal("nixpkgs", nixpkgs.mode_for(root, {}))
      assert.are.equal("flake", nixpkgs.mode_for(plain, {}))

      assert.are.equal("flake", nixpkgs.mode_for(root, { nixpkgs_mode = false }))
      assert.are.equal("nixpkgs", nixpkgs.mode_for(plain, { nixpkgs_mode = true }))
    end)
  end)

  describe("resolve_root", function()
    it("returns the marker root by default", function()
      local root = nixpkgs_tree()
      local pkg = write_package(root, "hello", { "{}" })
      assert.are.equal(vim.fs.normalize(root), nixpkgs.resolve_root(pkg, {}))
    end)

    it("disables handling when nixpkgs_mode is false", function()
      local root = nixpkgs_tree()
      local pkg = write_package(root, "hello", { "{}" })
      assert.is_nil(nixpkgs.resolve_root(pkg, { nixpkgs_mode = false }))
    end)

    it("forces the flake root when nixpkgs_mode is true without markers", function()
      local root = vim.fn.tempname()
      write_file(vim.fs.joinpath(root, "flake.nix"), { "{}" })
      local file = vim.fs.joinpath(root, "anything.nix")

      assert.is_nil(nixpkgs.resolve_root(file, {}))
      assert.are.equal(root, nixpkgs.resolve_root(file, { nixpkgs_mode = true }))
    end)
  end)

  describe("attr_for_by_name", function()
    it("maps a by-name path to its attribute", function()
      local root = "/nixpkgs"
      assert.are.equal(
        "hello",
        nixpkgs.attr_for_by_name("/nixpkgs/pkgs/by-name/he/hello/package.nix", root)
      )
      assert.is_nil(nixpkgs.attr_for_by_name("/nixpkgs/pkgs/development/foo/default.nix", root))
      assert.is_nil(nixpkgs.attr_for_by_name("/elsewhere/package.nix", root))
    end)
  end)

  describe("should_descend", function()
    it("keeps the supported subtrees and their ancestors", function()
      assert.is_true(nixpkgs.should_descend(""))
      assert.is_true(nixpkgs.should_descend("pkgs"))
      assert.is_true(nixpkgs.should_descend("pkgs/by-name"))
      assert.is_true(nixpkgs.should_descend("pkgs/by-name/he/hello"))
      -- lib/nixos are descended only as far as their tests subtrees.
      assert.is_true(nixpkgs.should_descend("lib"))
      assert.is_true(nixpkgs.should_descend("lib/tests"))
      assert.is_true(nixpkgs.should_descend("nixos/tests"))

      assert.is_false(nixpkgs.should_descend("pkgs/development"))
      assert.is_false(nixpkgs.should_descend("lib/sources"))
      assert.is_false(nixpkgs.should_descend("nixos/modules"))
    end)
  end)

  describe("discover_positions", function()
    it("enumerates passthru.tests members (attrset form)", function()
      local root = nixpkgs_tree()
      local pkg = write_package(root, "hello", {
        "{ stdenv }:",
        "stdenv.mkDerivation {",
        '  pname = "hello";',
        "  passthru.tests = {",
        "    simple = { };",
        "    version = { };",
        "  };",
        "}",
      })

      local tree = nixpkgs.discover_positions(pkg, root, {})
      assert.is_not_nil(tree)
      assert.are.equal("hello.tests", tree:data().nixpkgs_attr)

      local attrs = test_attrs(tree)
      assert.are.equal("hello.tests.simple", attrs.simple)
      assert.are.equal("hello.tests.version", attrs.version)
    end)

    it("handles a nested passthru attrset and dotted entries", function()
      local root = nixpkgs_tree()
      local nested = write_package(root, "nested", {
        "{ stdenv }:",
        "stdenv.mkDerivation {",
        "  passthru = {",
        "    tests = {",
        "      alpha = { };",
        "    };",
        "  };",
        "}",
      })
      local dotted = write_package(root, "dotted", {
        "{ stdenv }:",
        "stdenv.mkDerivation {",
        "  passthru.tests.beta = { };",
        "}",
      })

      assert.are.equal(
        "nested.tests.alpha",
        test_attrs(nixpkgs.discover_positions(nested, root, {})).alpha
      )
      assert.are.equal(
        "dotted.tests.beta",
        test_attrs(nixpkgs.discover_positions(dotted, root, {})).beta
      )
    end)

    it("handles inherited and selected passthru test members", function()
      local root = nixpkgs_tree()
      local inherited = write_package(root, "inherited", {
        "{ nixosTests, smoke }:",
        "stdenv.mkDerivation {",
        "  passthru.tests = {",
        "    inherit smoke;",
        "    inherit (nixosTests) podman;",
        "  };",
        "}",
      })
      local selected = write_package(root, "selected", {
        "{ nixosTests }:",
        "stdenv.mkDerivation {",
        "  passthru = {",
        "    tests = nixosTests.alice-lg;",
        "  };",
        "}",
      })

      local inherited_attrs = test_attrs(nixpkgs.discover_positions(inherited, root, {}))
      assert.are.equal("inherited.tests.smoke", inherited_attrs.smoke)
      assert.are.equal("inherited.tests.podman", inherited_attrs.podman)
      assert.are.equal(
        "selected.tests.alice-lg",
        test_attrs(nixpkgs.discover_positions(selected, root, {}))["alice-lg"]
      )
    end)

    it("quotes test names that are not bare identifiers", function()
      local root = nixpkgs_tree()
      local pkg = write_package(root, "hello", {
        "{ stdenv }:",
        "stdenv.mkDerivation {",
        "  passthru.tests = {",
        '    "1.0" = { };',
        "    plain = { };",
        "  };",
        "}",
      })

      local attrs = test_attrs(nixpkgs.discover_positions(pkg, root, {}))
      assert.are.equal('hello.tests."1.0"', attrs["1.0"])
      assert.are.equal("hello.tests.plain", attrs.plain)

      local command = nixpkgs.build_command({ nixpkgs_attr = attrs["1.0"] })
      assert.same({ "nix-build", "-A", 'hello.tests."1.0"', "--no-out-link" }, command)
    end)

    it("selects the attr, not the or-fallback, from a select expression", function()
      local root = nixpkgs_tree()
      local pkg = write_package(root, "guarded", {
        "{ nixosTests, fallback }:",
        "stdenv.mkDerivation {",
        "  passthru.tests = nixosTests.foo or fallback;",
        "}",
      })

      local attrs = test_attrs(nixpkgs.discover_positions(pkg, root, {}))
      assert.are.equal("guarded.tests.foo", attrs.foo)
      assert.is_nil(attrs.fallback)
    end)

    it("selects a quoted leaf attr", function()
      local root = nixpkgs_tree()
      local pkg = write_package(root, "quoted", {
        "{ drv }:",
        "stdenv.mkDerivation {",
        '  passthru.tests = drv.tests."foo-bar";',
        "}",
      })

      local attrs = test_attrs(nixpkgs.discover_positions(pkg, root, {}))
      assert.are.equal("quoted.tests.foo-bar", attrs["foo-bar"])
      assert.is_nil(attrs.tests)
      assert.is_nil(attrs.drv)
    end)

    it("ignores nested attrs inside computed passthru tests", function()
      local root = nixpkgs_tree()
      local pkg = write_package(root, "computed", {
        "{ lib, finalPackage }:",
        "stdenv.mkDerivation {",
        "  passthru.tests =",
        "    (lib.listToAttrs (map (name: lib.nameValuePair name (",
        "      finalPackage.overrideAttrs (previousAttrs: {",
        "        passthru = previousAttrs.passthru // { flag = true; };",
        "      })",
        '    )) [ "generated" ]))',
        "    // { static = { }; };",
        "}",
      })

      local attrs = test_attrs(nixpkgs.discover_positions(pkg, root, {}))
      assert.are.equal("computed.tests.static", attrs.static)
      assert.is_nil(attrs.passthru)
    end)

    it("falls back to eval when static parse finds no tests", function()
      local root = nixpkgs_tree()
      -- Computed tests: static parse cannot see the names.
      local pkg = write_package(root, "computed", {
        "{ stdenv, callPackages }:",
        "stdenv.mkDerivation {",
        "  passthru.tests = callPackages ./tests.nix { };",
        "}",
      })

      local eval_module = package.loaded["neotest-nix.eval"]
      local seen_attr
      package.loaded["neotest-nix.eval"] = {
        nixpkgs_test_names = function(_, attr)
          seen_attr = attr
          return { "alpha", "beta" }
        end,
      }

      local tree = nixpkgs.discover_positions(pkg, root, { discover_nixpkgs_eval_tests = true })
      package.loaded["neotest-nix.eval"] = eval_module

      assert.are.equal("computed", seen_attr)
      local attrs = test_attrs(tree)
      assert.are.equal("computed.tests.alpha", attrs.alpha)
      assert.are.equal("computed.tests.beta", attrs.beta)
    end)

    it("does not eval when the option is disabled", function()
      local root = nixpkgs_tree()
      local pkg = write_package(root, "computed", {
        "{ stdenv, callPackages }:",
        "stdenv.mkDerivation { passthru.tests = callPackages ./tests.nix { }; }",
      })

      local eval_module = package.loaded["neotest-nix.eval"]
      local called = false
      package.loaded["neotest-nix.eval"] = {
        nixpkgs_test_names = function()
          called = true
          return { "alpha" }
        end,
      }

      local tree = nixpkgs.discover_positions(pkg, root, {})
      package.loaded["neotest-nix.eval"] = eval_module

      assert.is_false(called)
      assert.are.same({}, test_attrs(tree))
    end)

    it("does not eval when the static parse already found tests", function()
      local root = nixpkgs_tree()
      local pkg = write_package(root, "static", {
        "{ stdenv }:",
        "stdenv.mkDerivation { passthru.tests = { only = { }; }; }",
      })

      local eval_module = package.loaded["neotest-nix.eval"]
      local called = false
      package.loaded["neotest-nix.eval"] = {
        nixpkgs_test_names = function()
          called = true
          return { "eval_should_not_run" }
        end,
      }

      local tree = nixpkgs.discover_positions(pkg, root, { discover_nixpkgs_eval_tests = true })
      package.loaded["neotest-nix.eval"] = eval_module

      assert.is_false(called)
      assert.are.equal("static.tests.only", test_attrs(tree).only)
    end)

    it("yields just the file node when no tests are declared", function()
      local root = nixpkgs_tree()
      local pkg = write_package(root, "plain", {
        "{ stdenv }:",
        'stdenv.mkDerivation { pname = "plain"; }',
      })

      local tree = nixpkgs.discover_positions(pkg, root, {})
      assert.is_not_nil(tree)
      assert.are.equal("plain.tests", tree:data().nixpkgs_attr)
      assert.are.same({}, test_attrs(tree))
    end)
  end)

  describe("test_file_kind", function()
    it("classifies by-name, lib, and nixos test files", function()
      local root = "/nixpkgs"
      local function kind(rel)
        return nixpkgs.test_file_kind("/nixpkgs/" .. rel, root)
      end

      assert.are.equal("by-name", kind("pkgs/by-name/he/hello/package.nix"))
      assert.are.equal("lib", kind("lib/tests/release.nix"))
      assert.are.equal("lib", kind("lib/tests/misc.nix"))
      assert.are.equal("lib", kind("lib/tests/fetchers.nix"))
      assert.are.equal("lib", kind("lib/tests/systems.nix"))
      assert.are.equal("lib", kind("lib/tests/maintainers.nix"))
      assert.are.equal("lib", kind("lib/tests/nix-unit.nix"))
      assert.are.equal("lib", kind("lib/tests/teams.nix"))
      assert.are.equal("nixos", kind("nixos/tests/login.nix"))

      -- not tests
      assert.is_nil(kind("lib/tests/modules.nix"))
      assert.is_nil(kind("lib/tests/maintainer-module.nix"))
      assert.is_nil(kind("lib/tests/nix-for-tests.nix"))
      assert.is_nil(kind("lib/tests/test-with-nix.nix"))
      assert.is_nil(kind("nixos/tests/make-test-python.nix"))
      assert.is_nil(kind("nixos/tests/default.nix"))
      assert.is_nil(kind("nixos/tests/common/acme.nix"))
      assert.is_nil(kind("pkgs/development/libraries/qt-6/default.nix"))
    end)
  end)

  describe("lib discovery", function()
    it("builds build-style files and evaluates eval-style files", function()
      local root = nixpkgs_tree()
      vim.fn.mkdir(vim.fs.joinpath(root, "lib", "tests"), "p")
      local release = vim.fs.joinpath(root, "lib", "tests", "release.nix")
      local maintainers = vim.fs.joinpath(root, "lib", "tests", "maintainers.nix")
      local misc = vim.fs.joinpath(root, "lib", "tests", "misc.nix")
      local systems = vim.fs.joinpath(root, "lib", "tests", "systems.nix")
      write_file(release, { "{ }" })
      write_file(maintainers, { '{ pkgs ? import ../.. { } }: pkgs.runCommand "x" { } "" ' })
      write_file(misc, { "[ ]" })
      write_file(systems, { "[ ]" })

      local rtree = nixpkgs.discover_positions(release, root, {})
      assert.are.equal("lib/tests/release.nix", rtree:data().nixpkgs_file_build)
      assert.are.equal("nix", rtree:data().runner)

      local maintree = nixpkgs.discover_positions(maintainers, root, {})
      assert.are.equal("lib/tests/maintainers.nix", maintree:data().nixpkgs_file_build)
      assert.are.equal("nix", maintree:data().runner)

      local mtree = nixpkgs.discover_positions(misc, root, {})
      assert.are.equal("lib/tests/misc.nix", mtree:data().nixpkgs_file_eval)
      assert.are.equal("nix-eval", mtree:data().runner)

      local stree = nixpkgs.discover_positions(systems, root, {})
      assert.are.equal("lib/tests/systems.nix", stree:data().nixpkgs_file_eval)
      assert.are.equal("nix-eval", stree:data().runner)
    end)

    it("enumerates static lib.runTests members under eval-style files", function()
      local root = nixpkgs_tree()
      local misc = vim.fs.joinpath(root, "lib", "tests", "misc.nix")
      local systems = vim.fs.joinpath(root, "lib", "tests", "systems.nix")
      write_file(misc, {
        "let",
        "  lib.runTests = tests: [ ];",
        "in",
        "lib.runTests {",
        "  testAlpha = { expr = 1; expected = 1; };",
        "  helper = { expr = 2; expected = 2; };",
        "  testBeta.expr = 3;",
        "  testBeta.expected = 3;",
        "}",
      })
      write_file(systems, {
        "let runTests = tests: [ ]; in",
        "runTests (({",
        "  testSystem = { expr = true; expected = true; };",
        "}) // {",
        "  testOther = { expr = false; expected = false; };",
        "})",
      })

      local misc_tests = eval_tests(nixpkgs.discover_positions(misc, root, {}))
      assert.are.equal("testAlpha", misc_tests.testAlpha.nixpkgs_eval_test)
      assert.are.equal("testBeta", misc_tests.testBeta.nixpkgs_eval_test)
      assert.is_nil(misc_tests.helper)
      assert.are.equal("lib/tests/misc.nix", misc_tests.testAlpha.nixpkgs_file_eval)
      assert.are.equal("nix-eval", misc_tests.testAlpha.runner)

      local system_tests = eval_tests(nixpkgs.discover_positions(systems, root, {}))
      assert.are.equal("testSystem", system_tests.testSystem.nixpkgs_eval_test)
      assert.are.equal("testOther", system_tests.testOther.nixpkgs_eval_test)
    end)
  end)

  describe("nixos discovery", function()
    it("targets nixosTests.<name>", function()
      local root = nixpkgs_tree()
      vim.fn.mkdir(vim.fs.joinpath(root, "nixos", "tests"), "p")
      local test = vim.fs.joinpath(root, "nixos", "tests", "login.nix")
      write_file(test, {
        "{",
        '  name = "login";',
        "  testScript = ''",
        "    machine.wait_for_unit()",
        "  '';",
        "}",
      })

      local tree = nixpkgs.discover_positions(test, root, {})
      assert.are.equal("nixosTests.login", tree:data().nixpkgs_attr)
      assert.are.equal("nix", tree:data().runner)
      -- testScript range captured for traceback attribution
      assert.is_not_nil(tree:data().test_script_range)
    end)
  end)

  describe("build_command", function()
    it("builds nix-build -A for an attribute", function()
      local command, runner = nixpkgs.build_command({ nixpkgs_attr = "hello.tests.simple" })
      assert.same({ "nix-build", "-A", "hello.tests.simple", "--no-out-link" }, command)
      assert.are.equal("nix", runner)
    end)

    it("builds nix-build <file> for a buildable file", function()
      local command, runner =
        nixpkgs.build_command({ nixpkgs_file_build = "lib/tests/release.nix" })
      assert.same({ "nix-build", "lib/tests/release.nix", "--no-out-link" }, command)
      assert.are.equal("nix", runner)
    end)

    it("builds nix-instantiate --eval for an eval file", function()
      local command, runner = nixpkgs.build_command({ nixpkgs_file_eval = "lib/tests/misc.nix" })
      assert.same(
        { "nix-instantiate", "--eval", "--strict", "--json", "lib/tests/misc.nix" },
        command
      )
      assert.are.equal("nix-eval", runner)
    end)

    it("builds a filtered eval expression for an eval test", function()
      local command, runner = nixpkgs.build_command({
        nixpkgs_file_eval = "lib/tests/misc.nix",
        nixpkgs_eval_test = "testAlpha",
      })

      assert.are.equal("nix-eval", runner)
      assert.same({ "nix-instantiate", "--eval", "--strict", "--json", "--expr" }, {
        command[1],
        command[2],
        command[3],
        command[4],
        command[5],
      })
      assert.is_truthy(command[6]:find("import ./lib/tests/misc.nix", 1, true))
      assert.is_truthy(command[6]:find("builtins.filter", 1, true))
      assert.is_truthy(command[6]:find("testAlpha", 1, true))
    end)

    it("splices nix_extra_args right after the binary name, before -A", function()
      local command = nixpkgs.build_command(
        { nixpkgs_attr = "hello.tests.simple" },
        { nix_extra_args = { "-L", "--show-trace" } }
      )
      assert.same(
        { "nix-build", "-L", "--show-trace", "-A", "hello.tests.simple", "--no-out-link" },
        command
      )
    end)

    it("derives nix-build/nix-instantiate alongside a path-shaped nix_bin", function()
      local build_command = nixpkgs.build_command(
        { nixpkgs_file_build = "lib/tests/release.nix" },
        { nix_bin = "/opt/nix/bin/nix" }
      )
      assert.same(
        { "/opt/nix/bin/nix-build", "lib/tests/release.nix", "--no-out-link" },
        build_command
      )

      local eval_command = nixpkgs.build_command(
        { nixpkgs_file_eval = "lib/tests/misc.nix" },
        { nix_bin = "/opt/nix/bin/nix" }
      )
      assert.same(
        { "/opt/nix/bin/nix-instantiate", "--eval", "--strict", "--json", "lib/tests/misc.nix" },
        eval_command
      )
    end)
  end)

  describe("legacy_bin", function()
    it("keeps the literal name for a bare (or unset) nix_bin", function()
      assert.are.equal("nix-build", nixpkgs.legacy_bin({ nix_bin = "nix" }, "build"))
      assert.are.equal("nix-instantiate", nixpkgs.legacy_bin(nil, "instantiate"))
    end)

    it("substitutes the basename alongside a path-shaped nix_bin", function()
      assert.are.equal(
        "/opt/nix/bin/nix-build",
        nixpkgs.legacy_bin({ nix_bin = "/opt/nix/bin/nix" }, "build")
      )
      assert.are.equal(
        "/opt/nix/bin/nix-instantiate",
        nixpkgs.legacy_bin({ nix_bin = "/opt/nix/bin/nix" }, "instantiate")
      )
    end)
  end)
end)
