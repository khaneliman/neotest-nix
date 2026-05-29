describe("adapter", function()
  local notify

  before_each(function()
    package.loaded["neotest-nix"] = nil
    package.loaded["neotest.lib"] = {
      treesitter = {
        parse_positions = function()
          error("parser failed")
        end,
      },
    }

    notify = vim.notify
    vim.notify = function() end
    vim.opt.runtimepath:prepend(vim.loop.cwd())
  end)

  after_each(function()
    vim.notify = notify
    package.loaded["neotest.lib"] = nil
  end)

  it("fails discovery gracefully when tree-sitter parsing errors", function()
    local adapter = require("neotest-nix")()

    assert.is_nil(adapter.discover_positions("flake.nix"))
  end)
end)
