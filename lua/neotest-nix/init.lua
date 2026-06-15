local discover = require("neotest-nix.discover")
local display = require("neotest-nix.display")
local eval = require("neotest-nix.eval")
local parser = require("neotest-nix.parser")
local positions = require("neotest-nix.positions")
local results = require("neotest-nix.results")
local spec = require("neotest-nix.spec")

local M = {}

-- The public config types (neotest-nix.Config / neotest-nix.EvalOutput) are
-- defined in lua/neotest-nix/types.lua; this module references them by name.

-- Active configuration. The module table itself is the Neotest adapter (see
-- neotest-haskell), so `setup`/`__call` mutate this shared state and return M.
-- Neotest uses a single adapter instance, so the last configuration wins.
---@type neotest-nix.Config
M._opts = {}

M.name = "neotest-nix"
M.root = discover.root
M.results = results.results

-- Thread the active configuration through, mirroring `build_spec`, so the
-- nixpkgs_mode override reaches discovery (and `nixpkgs_mode = false` can fully
-- disable nixpkgs handling).
---@param file_path string
---@return boolean
function M.is_test_file(file_path)
  return discover.is_test_file(file_path, M._opts)
end

---@param name string
---@param rel_path string
---@param root string
---@return boolean
function M.filter_dir(name, rel_path, root)
  return discover.filter_dir(name, rel_path, root, M._opts)
end

---Build a run spec for the given position, threading the active configuration
---through so the wrapping-check fallback (`nix_unit_checks`) is honoured.
---@param args neotest.RunArgs
---@return neotest.RunSpec?
function M.build_spec(args)
  return spec.build_spec(args, M._opts)
end

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

  -- Nixpkgs files (e.g. a `pkgs/by-name` package) build their own position tree
  -- from a static parse instead of the flake tree-sitter query.
  local nixpkgs = require("neotest-nix.nixpkgs")
  local nixpkgs_root = nixpkgs.resolve_root(file_path, opts)
  if nixpkgs_root ~= nil and nixpkgs.is_nixpkgs_test_file(file_path, nixpkgs_root) then
    return nixpkgs.discover_positions(file_path, nixpkgs_root, opts)
  end

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

  return display.label_tree(tree, file_path)
end

---Validate user-supplied config, failing fast with the offending field path.
---Uses the per-argument `vim.validate` signature (Neovim 0.11+).
---@param opts neotest-nix.Config
local function validate(opts)
  vim.validate("parser_runtime_paths", opts.parser_runtime_paths, "table", true)
  vim.validate("discover_eval_checks", opts.discover_eval_checks, "boolean", true)
  vim.validate("eval_outputs", opts.eval_outputs, "table", true)
  vim.validate("nix_unit_flakes", opts.nix_unit_flakes, "table", true)
  vim.validate("nixpkgs_mode", opts.nixpkgs_mode, "boolean", true)

  if opts.parser_runtime_paths ~= nil then
    for index, path in ipairs(opts.parser_runtime_paths) do
      vim.validate(("parser_runtime_paths[%d]"):format(index), path, "string")
    end
  end

  if opts.eval_outputs ~= nil then
    for index, output in ipairs(opts.eval_outputs) do
      vim.validate(("eval_outputs[%d]"):format(index), output, "table")
      vim.validate(("eval_outputs[%d].attr"):format(index), output.attr, "string")
      vim.validate(("eval_outputs[%d].match"):format(index), output.match, "string", true)
    end
  end

  if opts.nix_unit_flakes ~= nil then
    for index, entry in ipairs(opts.nix_unit_flakes) do
      vim.validate(("nix_unit_flakes[%d]"):format(index), entry, "table")
      vim.validate(("nix_unit_flakes[%d].path"):format(index), entry.path, "string")
      vim.validate(("nix_unit_flakes[%d].flake"):format(index), entry.flake, "string")
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
