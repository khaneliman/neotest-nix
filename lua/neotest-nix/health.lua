local M = {}

local uv = vim.uv
local health = vim.health

---@param name string
---@return boolean
local function has_plugin(name)
  return (pcall(require, name))
end

---@return table
local function active_opts()
  local ok, adapter = pcall(require, "neotest-nix")
  if not ok then
    return {}
  end

  return adapter._opts or {}
end

---@param roots string[]?
---@return boolean
local function configured_nix_grammar_available(roots)
  if roots == nil then
    return false
  end

  for _, root in ipairs(roots) do
    if type(root) == "string" then
      local parser = vim.fs.joinpath(root, "parser", "nix.so")
      if
        uv.fs_stat(parser) ~= nil and pcall(vim.treesitter.language.add, "nix", { path = parser })
      then
        return true
      end
    end
  end

  return false
end

---@param roots string[]?
---@return boolean
local function nix_grammar_available(roots)
  if #vim.api.nvim_get_runtime_file("parser/nix.so", true) > 0 then
    return true
  end

  if configured_nix_grammar_available(roots) then
    return true
  end

  return (pcall(vim.treesitter.language.add, "nix"))
end

---@type table<string, type>
local known_config_fields = {
  parser_runtime_paths = "table",
  discover_eval_checks = "boolean",
  eval_outputs = "table",
  nix_unit_flakes = "table",
  nixpkgs_mode = "boolean",
  discover_nixpkgs_eval_tests = "boolean",
}

---Inspect the active adapter configuration for typos and wrong-typed fields.
---setup() rejects bad types outright, so the value here is catching unknown
---keys (which vim.validate ignores) and a config set without going through setup.
local function check_config()
  local opts = active_opts()
  if next(opts) == nil then
    health.ok("using default configuration")
    return
  end

  local valid = true
  for key, value in pairs(opts) do
    local expected = known_config_fields[key]
    if expected == nil then
      valid = false
      health.warn(
        ("unknown config key `%s`"):format(key),
        "Check for a typo; see :h neotest-nix-configuration"
      )
    elseif type(value) ~= expected then
      valid = false
      health.error(("config `%s` must be a %s, got %s"):format(key, expected, type(value)))
    end
  end

  if type(opts.parser_runtime_paths) == "table" then
    for index, root in ipairs(opts.parser_runtime_paths) do
      if type(root) ~= "string" then
        valid = false
        health.error(("parser_runtime_paths[%d] must be a string"):format(index))
      end
    end
  end

  if type(opts.eval_outputs) == "table" then
    for index, output in ipairs(opts.eval_outputs) do
      if type(output) ~= "table" or type(output.attr) ~= "string" then
        valid = false
        health.error(("eval_outputs[%d] must be a table with a string `attr`"):format(index))
      elseif output.match ~= nil and type(output.match) ~= "string" then
        valid = false
        health.error(("eval_outputs[%d].match must be a string"):format(index))
      end
    end
  end

  if type(opts.nix_unit_flakes) == "table" then
    for index, entry in ipairs(opts.nix_unit_flakes) do
      if
        type(entry) ~= "table"
        or type(entry.path) ~= "string"
        or type(entry.flake) ~= "string"
      then
        valid = false
        health.error(
          ("nix_unit_flakes[%d] must be a table with string `path` and `flake`"):format(index)
        )
      end
    end
  end

  if valid then
    health.ok("configuration looks valid")
  end
end

function M.check()
  health.start("neotest-nix")
  local opts = active_opts()

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
    health.error("`nix` not found on PATH", "Install Nix and ensure `nix` is executable")
  end

  if vim.fn.executable("nix-unit") == 1 then
    health.ok("`nix-unit` on PATH")
  else
    health.warn(
      "`nix-unit` not found on PATH",
      "Only required to run nix-unit tests; see https://github.com/nix-community/nix-unit"
    )
  end

  if nix_grammar_available(opts.parser_runtime_paths) then
    health.ok("`nix` tree-sitter grammar available")
  else
    health.warn(
      "`nix` tree-sitter grammar not found",
      "Install the grammar (nvim-treesitter, a built parser, or the parser_runtime_paths option)"
    )
  end

  check_config()
end

return M
