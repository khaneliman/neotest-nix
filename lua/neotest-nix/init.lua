local discover = require("neotest-nix.discover")
local eval = require("neotest-nix.eval")
local parser = require("neotest-nix.parser")
local positions = require("neotest-nix.positions")
local results = require("neotest-nix.results")
local spec = require("neotest-nix.spec")

local M = {}

---@class neotest-nix.EvalOutput
---@field attr string Flake output to enumerate per system (e.g. "checks", "legacyPackages").
---@field match? string Lua pattern; only attribute names matching it are kept.

---@class neotest-nix.Config
---@field parser_runtime_paths? string[] Extra runtimepath roots containing parser/nix.so.
---@field discover_eval_checks? boolean Evaluate the flake to discover generated outputs.
---@field eval_outputs? neotest-nix.EvalOutput[] Outputs to enumerate (defaults to checks).

-- Active configuration. The module table itself is the Neotest adapter (see
-- neotest-haskell), so `setup`/`__call` mutate this shared state and return M.
-- Neotest uses a single adapter instance, so the last configuration wins.
---@type neotest-nix.Config
M._opts = {}

M.name = "neotest-nix"
M.root = discover.root
M.is_test_file = discover.is_test_file
M.filter_dir = discover.filter_dir
M.build_spec = spec.build_spec
M.results = results.results

-- Re-exported on the module table so neotest's tree-sitter pass can reach the
-- position builder via `require("neotest-nix")._build_position`, and so the
-- spec suite can drive these directly.
M._build_position = positions.build_position
M._merge_eval_outputs = eval.merge_outputs

---@async
---@param file_path string
---@return neotest.Tree?
function M.discover_positions(file_path)
  local opts = M._opts
  parser.ensure_nix_parser(opts.parser_runtime_paths)

  local lib = require("neotest.lib")
  ---@type any
  local parse_options = {
    build_position = 'require("neotest-nix")._build_position',
  }
  local ok, tree =
    pcall(lib.treesitter.parse_positions, file_path, positions.query(), parse_options)
  if not ok then
    vim.notify(("neotest-nix: failed to parse %s: %s"):format(file_path, tree), vim.log.levels.WARN)
    return nil
  end

  if opts.discover_eval_checks and vim.fs.basename(file_path) == "flake.nix" then
    local root = discover.root(file_path)
    local discovered = root ~= nil and eval.eval_outputs(root, opts.eval_outputs) or nil
    if discovered ~= nil and #discovered.outputs > 0 then
      tree = eval.merge_outputs(tree, discovered.system, discovered.outputs)
    end
  end

  return tree
end

---Validate user-supplied config, failing fast with the offending field path.
---Uses the per-argument `vim.validate` signature (Neovim 0.11+).
---@param opts neotest-nix.Config
local function validate(opts)
  vim.validate("parser_runtime_paths", opts.parser_runtime_paths, "table", true)
  vim.validate("discover_eval_checks", opts.discover_eval_checks, "boolean", true)
  vim.validate("eval_outputs", opts.eval_outputs, "table", true)

  if opts.eval_outputs ~= nil then
    for index, output in ipairs(opts.eval_outputs) do
      vim.validate(("eval_outputs[%d].attr"):format(index), output.attr, "string")
      vim.validate(("eval_outputs[%d].match"):format(index), output.match, "string", true)
    end
  end
end

---Configure the adapter. Returns the adapter (the module table itself), so all
---of `require("neotest-nix")`, `require("neotest-nix")(opts)` and
---`require("neotest-nix").setup(opts)` yield the same working adapter.
---@param opts neotest-nix.Config?
---@return neotest.Adapter
function M.setup(opts)
  opts = opts or {}
  validate(opts)
  M._opts = opts
  ---@diagnostic disable-next-line: return-type-mismatch
  return M
end

return setmetatable(M, {
  __call = function(_, opts)
    return M.setup(opts)
  end,
})
