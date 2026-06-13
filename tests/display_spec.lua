local display = require("neotest-nix.display")

---@param position table
---@return table
local function tree(position)
  return {
    data = function()
      return position
    end,
  }
end

describe("display labels", function()
  local tmp

  before_each(function()
    tmp = vim.fn.tempname()
    vim.fn.mkdir(vim.fs.joinpath(tmp, "github", "project"), "p")
  end)

  after_each(function()
    if tmp ~= nil then
      vim.fn.delete(tmp, "rf")
    end
  end)

  it("adds compact root context to flake.nix file labels", function()
    local file_path = vim.fs.joinpath(tmp, "github", "project", "flake.nix")
    vim.fn.writefile({ "{}" }, file_path)
    local position = {
      id = file_path,
      name = "flake.nix",
      path = file_path,
      type = "file",
    }

    display.label_tree(tree(position), file_path)

    assert.are.equal("flake.nix (github/project)", position.name)
    assert.are.equal(file_path, position.id)
    assert.are.equal(file_path, position.path)
  end)

  it("leaves non-flake file labels unchanged", function()
    local flake_path = vim.fs.joinpath(tmp, "github", "project", "flake.nix")
    local file_path = vim.fs.joinpath(tmp, "github", "project", "tests.nix")
    vim.fn.writefile({ "{}" }, flake_path)
    vim.fn.writefile({ "{}" }, file_path)
    local position = {
      id = file_path,
      name = "tests.nix",
      path = file_path,
      type = "file",
    }

    display.label_tree(tree(position), file_path)

    assert.are.equal("tests.nix", position.name)
  end)
end)
