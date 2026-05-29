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
      { "aarch64-darwin", "checks", "outputs", "x86_64-linux" },
      names_by_type(positions, "namespace")
    )
    assert.same({ "integration", "unit" }, names_by_type(positions, "test"))
  end)
end)
