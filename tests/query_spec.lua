local function parse_fixture()
  local query = table.concat(vim.fn.readfile("queries/nix/neotest-nix.scm"), "\n")
  local source = table.concat(vim.fn.readfile("tests/fixtures/flake.nix"), "\n")
  local parsed_query = vim.treesitter.query.parse("nix", query)
  local root = vim.treesitter.get_string_parser(source, "nix"):parse()[1]:root()
  local positions = {}

  for _, match in parsed_query:iter_matches(root, source, nil, nil) do
    local captured_nodes = {}
    for id, nodes in pairs(match) do
      local capture = parsed_query.captures[id]
      captured_nodes[capture] = type(nodes) == "table" and nodes[#nodes] or nodes
    end

    local position = require("neotest-nix")._build_position("flake.nix", source, captured_nodes)
    if position ~= nil then
      table.insert(positions, position)
    end
  end

  return positions
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
      { "integration", "testLibrary", "testPass", "unit", "vm" },
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

  it("discovers nix-unit assertions under arbitrary flake suite names", function()
    local positions = parse_fixture()

    for _, position in ipairs(positions) do
      if position.name == "testLibrary" then
        assert.are.equal("nix-unit", position.runner)
        assert.are.equal("libTests.nested.testLibrary", position.attr_path)
        return
      end
    end

    error("missing testLibrary position")
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
