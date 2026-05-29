local parser = require("neotest-nix.parser")

describe("parser", function()
  it("prepends explicit parser runtime roots", function()
    local root = vim.fn.tempname()
    vim.fn.mkdir(vim.fs.joinpath(root, "parser"), "p")
    vim.fn.writefile({}, vim.fs.joinpath(root, "parser", "nix.so"))

    parser.ensure_nix_parser({ root })

    assert.are.equal(vim.fs.normalize(root), vim.opt.runtimepath:get()[1])
  end)
end)
