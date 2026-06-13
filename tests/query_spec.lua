local function parse_source(source, file_path)
  local query = table.concat(vim.fn.readfile("queries/nix/neotest-nix.scm"), "\n")
  local parsed_query = vim.treesitter.query.parse("nix", query)
  local root = vim.treesitter.get_string_parser(source, "nix"):parse()[1]:root()
  local positions = {}

  for _, match in parsed_query:iter_matches(root, source, nil, nil) do
    local captured_nodes = {}
    for id, nodes in pairs(match) do
      local capture = parsed_query.captures[id]
      captured_nodes[capture] = type(nodes) == "table" and nodes[#nodes] or nodes
    end

    local position = require("neotest-nix")._build_position(file_path, source, captured_nodes)
    if position ~= nil then
      table.insert(positions, position)
    end
  end

  return positions
end

local function parse_file(fixture, file_path)
  return parse_source(table.concat(vim.fn.readfile(fixture), "\n"), file_path)
end

local function parse_fixture()
  return parse_file("tests/fixtures/flake.nix", "flake.nix")
end

local function find_position(positions, name)
  for _, position in ipairs(positions) do
    if position.name == name then
      return position
    end
  end
end

local function names_by_type(positions, node_type)
  local names = {}

  for _, position in ipairs(positions) do
    if position.type == node_type then
      table.insert(names, position.name)
    end
  end

  table.sort(names)
  return names
end

describe("nix query", function()
  it("discovers flake checks without treating unrelated attrs as tests", function()
    local positions = parse_fixture()

    assert.same(
      { "aarch64-darwin", "aarch64-linux", "checks", "outputs", "tests", "x86_64-linux" },
      names_by_type(positions, "namespace")
    )
    assert.same(
      { "addition", "integration", "libraryCase", "testLibrary", "testPass", "unit", "vm" },
      names_by_type(positions, "test")
    )
  end)

  it("marks nix-unit test output positions with runner metadata", function()
    local positions = parse_fixture()

    for _, position in ipairs(positions) do
      if position.name == "testPass" then
        assert.are.equal("nix-unit", position.runner)
        assert.are.equal("tests.testPass", position.attr_path)
        return
      end
    end

    error("missing testPass position")
  end)

  it("discovers nix-unit assertions under arbitrary suite and test names", function()
    local positions = parse_fixture()

    for _, position in ipairs(positions) do
      if position.name == "testLibrary" then
        assert.are.equal("nix-unit", position.runner)
        assert.are.equal("libTests.nested.testLibrary", position.attr_path)
      elseif position.name == "libraryCase" then
        assert.are.equal("nix-unit", position.runner)
        assert.are.equal("libTests.nested.libraryCase", position.attr_path)
      end
    end

    assert.is_not_nil(find_position(positions, "testLibrary"))
    assert.is_not_nil(find_position(positions, "libraryCase"))
  end)

  it("discovers nix-unit assertions whose value is recursive", function()
    local positions = parse_source(
      table.concat({
        "{",
        "  testRecursive = rec {",
        "    expr = 1;",
        "    expected = 1;",
        "  };",
        "}",
      }, "\n"),
      "recursive-tests.nix"
    )

    local position = find_position(positions, "testRecursive")
    assert.is_not_nil(position)
    assert.are.equal("nix-unit", position.runner)
    assert.are.equal("testRecursive", position.attr_path)
  end)

  it("keeps system namespaces for dotted checks attrpaths", function()
    local positions = parse_source(
      table.concat({
        "{",
        "  outputs = { self }: {",
        "    checks.x86_64-linux = {",
        "      unit = true;",
        "    };",
        "  };",
        "}",
      }, "\n"),
      "flake.nix"
    )

    local checks = find_position(positions, "checks")
    local system = find_position(positions, "x86_64-linux")
    local unit = find_position(positions, "unit")

    assert.are.equal("namespace", checks.type)
    assert.are.equal("namespace", system.type)
    assert.are.equal("test", unit.type)
    assert.are.equal("checks.x86_64-linux.unit", unit.attr_path)
  end)

  it("marks flake.nix nix-unit suites as flake-reachable", function()
    local positions = parse_fixture()

    assert.are.equal("flake", find_position(positions, "testPass").nix_unit_kind)
    assert.are.equal("flake", find_position(positions, "addition").nix_unit_kind)
    assert.are.equal("flake", find_position(positions, "testLibrary").nix_unit_kind)
    assert.are.equal("flake", find_position(positions, "libraryCase").nix_unit_kind)
  end)

  it("marks bare-attrset nix-unit files as import-reachable", function()
    local positions = parse_file("tests/fixtures/bare-tests.nix", "bare-tests.nix")

    local bare = find_position(positions, "testBare")
    assert.are.equal("nix-unit", bare.runner)
    assert.are.equal("import", bare.nix_unit_kind)
    assert.are.equal("testBare", bare.attr_path)

    local non_prefixed = find_position(positions, "bareCase")
    assert.are.equal("nix-unit", non_prefixed.runner)
    assert.are.equal("import", non_prefixed.nix_unit_kind)
    assert.are.equal("bareCase", non_prefixed.attr_path)

    local nested = find_position(positions, "testNested")
    assert.are.equal("import", nested.nix_unit_kind)
    assert.are.equal("nested.testNested", nested.attr_path)

    local nested_non_prefixed = find_position(positions, "nestedCase")
    assert.are.equal("import", nested_non_prefixed.nix_unit_kind)
    assert.are.equal("nested.nestedCase", nested_non_prefixed.attr_path)
  end)

  it("ignores test-prefixed attrs that are not nix-unit assertions", function()
    local positions = parse_fixture()

    for _, position in ipairs(positions) do
      assert.is_not.equal("testFunction", position.name)
      assert.is_not.equal("testDerivation", position.name)
      assert.is_not.equal("testMissingExpected", position.name)
    end
  end)

  it("captures NixOS VM testScript ranges", function()
    local positions = parse_fixture()

    for _, position in ipairs(positions) do
      if position.name == "vm" then
        assert.are.equal("nix", position.runner)
        assert.are.equal("checks.aarch64-linux.vm", position.attr_path)
        assert.is_not_nil(position.test_script_range)
        assert.are.equal(20, position.test_script_range[1])
        return
      end
    end

    error("missing vm position")
  end)
end)
