local M = {}

local health = vim.health

---@param name string
---@return boolean
local function has_plugin(name)
  return (pcall(require, name))
end

---@return boolean
local function nix_grammar_available()
  if #vim.api.nvim_get_runtime_file("parser/nix.so", true) > 0 then
    return true
  end

  return (pcall(vim.treesitter.language.add, "nix"))
end

function M.check()
  health.start("neotest-nix")

  if vim.fn.has("nvim-0.11") == 1 then
    health.ok("Neovim >= 0.11")
  else
    health.error("Neovim >= 0.11 is required")
  end

  if has_plugin("neotest") then
    health.ok("`neotest` found")
  else
    health.error("`neotest` not found", "Install nvim-neotest/neotest")
  end

  if has_plugin("nio") then
    health.ok("`nvim-nio` found")
  else
    health.error("`nvim-nio` not found", "Install nvim-neotest/nvim-nio")
  end

  if vim.fn.executable("nix") == 1 then
    health.ok("`nix` on PATH")
  else
    health.error("`nix` not found on PATH", "Install Nix with nix-command and flakes enabled")
  end

  if vim.fn.executable("nix-unit") == 1 then
    health.ok("`nix-unit` on PATH")
  else
    health.warn(
      "`nix-unit` not found on PATH",
      "Only required to run nix-unit tests; see https://github.com/nix-community/nix-unit"
    )
  end

  if nix_grammar_available() then
    health.ok("`nix` tree-sitter grammar available")
  else
    health.warn(
      "`nix` tree-sitter grammar not found",
      "Install the grammar (nvim-treesitter, a built parser, or the parser_runtime_paths option)"
    )
  end
end

return M
