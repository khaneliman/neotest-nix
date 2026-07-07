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

-- The commands this adapter shells out to (`nix build`, `nix flake check
-- --no-write-lock-file`, `--extra-experimental-features`, `--print-out-paths`)
-- have all been available since flakes landed as a `nix` subcommand; nothing
-- here needs a newer feature than that.
local min_nix_version = { 2, 4 }

---Parse the leading `<major>.<minor>` out of `nix --version` output (e.g.
---"nix (Nix) 2.18.1"). Done defensively since the format is not a stable
---contract across Nix versions/forks (e.g. Lix reports "nix (Lix, like Nix)").
---@param output string
---@return integer[]?
local function parse_nix_version(output)
  local major, minor = output:match("(%d+)%.(%d+)")
  if major == nil or minor == nil then
    return nil
  end
  return { tonumber(major), tonumber(minor) }
end

---@param version integer[]
---@param floor integer[]
---@return boolean
local function version_at_least(version, floor)
  for index = 1, #floor do
    local have = version[index] or 0
    local want = floor[index]
    if have ~= want then
      return have > want
    end
  end
  return true
end

---@param bin string
local function check_nix_version(bin)
  -- vim.system (not vim.fn.system) so this is testable the same way the rest
  -- of the adapter's subprocess calls are: stub vim.system, no reliance on the
  -- global vim.v.shell_error side channel.
  local ok, result = pcall(function()
    return vim.system({ bin, "--version" }, { text = true }):wait()
  end)
  if not ok or result == nil or result.code ~= 0 then
    health.warn(("could not run `%s --version`"):format(bin))
    return
  end

  local version = parse_nix_version(result.stdout or "")
  if version == nil then
    health.warn(("could not parse `%s --version` output"):format(bin))
    return
  end

  if version_at_least(version, min_nix_version) then
    health.ok(("`%s` %d.%d %s"):format(bin, version[1], version[2], "(>= 2.4 required)"))
  else
    health.error(
      ("`%s` %d.%d is older than the minimum supported version 2.4"):format(
        bin,
        version[1],
        version[2]
      ),
      "Upgrade Nix; the adapter relies on flake subcommands "
        .. "(`nix build`, `nix flake check`, `--extra-experimental-features`) "
        .. "available since Nix 2.4"
    )
  end
end

---@type table<string, type>
local known_config_fields = {
  parser_runtime_paths = "table",
  discover_eval_checks = "boolean",
  eval_outputs = "table",
  nix_unit_flakes = "table",
  nixpkgs_mode = "boolean",
  discover_nixpkgs_eval_tests = "boolean",
  vm_interactive = "boolean",
  non_flake_roots = "boolean",
  nix_bin = "string",
  nix_unit_bin = "string",
  namaka_bin = "string",
  nix_extra_args = "table",
  nix_unit_extra_args = "table",
  namaka_extra_args = "table",
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

  if type(opts.nix_extra_args) == "table" then
    for index, arg in ipairs(opts.nix_extra_args) do
      if type(arg) ~= "string" then
        valid = false
        health.error(("nix_extra_args[%d] must be a string"):format(index))
      end
    end
  end

  if type(opts.nix_unit_extra_args) == "table" then
    for index, arg in ipairs(opts.nix_unit_extra_args) do
      if type(arg) ~= "string" then
        valid = false
        health.error(("nix_unit_extra_args[%d] must be a string"):format(index))
      end
    end
  end

  if type(opts.namaka_extra_args) == "table" then
    for index, arg in ipairs(opts.namaka_extra_args) do
      if type(arg) ~= "string" then
        valid = false
        health.error(("namaka_extra_args[%d] must be a string"):format(index))
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

  local nix_bin = opts.nix_bin or "nix"
  local nix_unit_bin = opts.nix_unit_bin or "nix-unit"
  local namaka_bin = opts.namaka_bin or "namaka"

  if vim.fn.executable(nix_bin) == 1 then
    health.ok(("`%s` on PATH"):format(nix_bin))
    check_nix_version(nix_bin)
  else
    health.error(
      ("`%s` not found on PATH"):format(nix_bin),
      ("Install Nix and ensure `%s` is executable"):format(nix_bin)
    )
  end

  if vim.fn.executable(nix_unit_bin) == 1 then
    health.ok(("`%s` on PATH"):format(nix_unit_bin))
  else
    health.warn(
      ("`%s` not found on PATH"):format(nix_unit_bin),
      "Only required to run nix-unit tests; see https://github.com/nix-community/nix-unit"
    )
  end

  if vim.fn.executable(namaka_bin) == 1 then
    health.ok(("`%s` on PATH"):format(namaka_bin))
  else
    health.warn(
      ("`%s` not found on PATH"):format(namaka_bin),
      "Only required to run Namaka snapshot tests; see https://github.com/nix-community/namaka"
    )
  end

  if vim.fn.executable("git") == 1 then
    health.ok("`git` on PATH")
  else
    health.warn(
      "`git` not found on PATH",
      "Only required for the nix-unit --flake path and builtins.getFlake, which see "
        .. "only git-tracked files; see |neotest-nix.limitations|"
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
