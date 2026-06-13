local parser = require("neotest-nix.parser")

describe("parser", function()
  it("prepends explicit parser runtime roots", function()
    local root = vim.fn.tempname()
    vim.fn.mkdir(vim.fs.joinpath(root, "parser"), "p")
    vim.fn.writefile({}, vim.fs.joinpath(root, "parser", "nix.so"))

    parser.ensure_nix_parser({ root })

    assert.are.equal(vim.fs.normalize(root), vim.opt.runtimepath:get()[1])
  end)

  it("adds parser runtime roots to neotest subprocesses", function()
    local root = vim.fn.tempname()
    local original_lib = package.loaded["neotest.lib"]
    local captured
    package.loaded["neotest.lib"] = {
      subprocess = {
        enabled = function()
          return true
        end,
        add_paths_to_rtp = function(paths)
          captured = vim.deepcopy(paths)
        end,
      },
    }
    finally(function()
      package.loaded["neotest.lib"] = original_lib
    end)

    parser.ensure_nix_parser({ root })

    assert.is_not_nil(captured)
    assert.is_true(vim.tbl_contains(captured, root))
  end)
end)
