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
    it("keeps only the supported subtrees", function()
      assert.is_true(nixpkgs.should_descend(""))
      assert.is_true(nixpkgs.should_descend("pkgs"))
      assert.is_true(nixpkgs.should_descend("pkgs/by-name"))
      assert.is_true(nixpkgs.should_descend("pkgs/by-name/he/hello"))

      assert.is_false(nixpkgs.should_descend("pkgs/development"))
      assert.is_false(nixpkgs.should_descend("lib"))
      assert.is_false(nixpkgs.should_descend("nixos"))
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

  describe("build_command", function()
    it("builds a legacy nix-build for the attribute", function()
      assert.same(
        { "nix-build", "-A", "hello.tests.simple", "--no-out-link" },
        nixpkgs.build_command({ nixpkgs_attr = "hello.tests.simple" })
      )
    end)
  end)
end)
