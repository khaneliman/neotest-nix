-- First-class `lib.runTests` support for ordinary (non-Nixpkgs) projects.
--
-- nixpkgs.lua's lib_test_runner only applies inside a detected Nixpkgs
-- checkout. Outside one, a `tests/default.nix` containing
-- `lib.runTests { testFoo = { expr = ...; expected = ...; }; }` is discovered
-- only because its inner attrs happen to match the generic nix-unit shape
-- (`has_nix_unit_assertion` in discover.lua), and spec.lua then runs it
-- through the nix-unit paths, which need either the `nix-unit` binary or a
-- flake mapping. This module gives such files a direct
-- `nix-instantiate --eval` (or `nix eval --impure`) path, matching how
-- Nixpkgs' own lib/tests/*.nix eval-style files run.
--
-- Supported file shapes:
--   - zero-arg: the file's top-level expression evaluates directly to the
--     `lib.runTests` result, e.g.
--     `let lib = (import <nixpkgs> { }).lib; in lib.runTests { ... }`.
--   - function over a single, fully-defaulted attrset parameter, e.g.
--     `{ pkgs ? import <nixpkgs> { } }: pkgs.lib.runTests { ... }`, applied
--     with `{ }` under `--impure` (defaults commonly reach for `<nixpkgs>`,
--     an impure lookup path).
-- Unsupported (falls through to the zero-arg path and fails at eval time
-- rather than running):
--   - a named-pattern function head (`args@{ ... }:` or `{ ... }@args:`).
--   - a bare identifier function head (`pkgs: ...`).
--   - any required (non-defaulted) argument.

local eval = require("neotest-nix.eval")
local process = require("neotest-nix.process")

local M = {}

local uv = vim.uv

local nix_command_features = {
  "--extra-experimental-features",
  "nix-command flakes",
}

---@param opts neotest-nix.Config?
---@return string
local function nix_bin(opts)
  return (opts and opts.nix_bin) or "nix"
end

---@param opts neotest-nix.Config?
---@param suffix "build"|"instantiate"
---@return string
local function legacy_bin(opts, suffix)
  local bin = nix_bin(opts)
  if not bin:find("/", 1, true) then
    return "nix-" .. suffix
  end
  return vim.fs.joinpath(vim.fs.dirname(bin), "nix-" .. suffix)
end

---@param command string[]
---@param opts neotest-nix.Config?
local function append_nix_extra_args(command, opts)
  if opts and opts.nix_extra_args ~= nil then
    vim.list_extend(command, opts.nix_extra_args)
  end
end

---Read `value` as file content when it names an existing file, otherwise
---treat it as raw source already. Lets `is_runtests_file` accept either a
---path or in-memory content, which keeps unit tests free of temp files.
---@param value string
---@return string
local function read_as_content(value)
  local stat = uv.fs_stat(value)
  if stat == nil or stat.type ~= "file" then
    return value
  end

  local file = io.open(value, "r")
  if file == nil then
    return value
  end
  local content = file:read("*a")
  file:close()
  return content or value
end

---Whether stripped Nix source contains a bare `runTests` call (`runTests
---{ ... }` or `lib.runTests { ... }`), outside comments and strings.
---Lightweight source heuristic (word-boundary match only), not a structural
---parse -- it does not verify the call is actually applied to an attrset,
---mirroring the level of rigor `has_nix_unit_assertion` uses in discover.lua.
---@param content string
---@return boolean
local function source_has_run_tests(content)
  local stripped = require("neotest-nix.discover").strip_comments_and_strings(content)
  return stripped:match("%f[%w]runTests%f[%W]") ~= nil
end

---@param content_or_path string Raw Nix source, or a path to a `.nix` file.
---@return boolean
function M.is_runtests_file(content_or_path)
  if type(content_or_path) ~= "string" then
    return false
  end
  return source_has_run_tests(read_as_content(content_or_path))
end

---Whether the stripped source's top-level expression is a function over a
---single attrset parameter (`{ ... }:`, with or without defaults), which
---must be applied with `{ }` before `lib.runTests` can be evaluated. Only the
---plain `{ ... }:` header is recognized; see the module-level shape notes for
---what is not.
---@param source string
---@return boolean
local function starts_with_attrset_function(source)
  local stripped = require("neotest-nix.discover").strip_comments_and_strings(source)
  local start = stripped:find("%S")
  if start == nil or stripped:sub(start, start) ~= "{" then
    return false
  end

  local depth = 0
  for pos = start, #stripped do
    local char = stripped:sub(pos, pos)
    if char == "{" then
      depth = depth + 1
    elseif char == "}" then
      depth = depth - 1
      if depth == 0 then
        local after = stripped:sub(pos + 1):match("%S")
        return after == ":"
      end
    end
  end

  return false
end

---@param file_path string
---@return string?
local function read_file(file_path)
  local file = io.open(file_path, "r")
  if file == nil then
    return nil
  end
  local content = file:read("*a")
  file:close()
  return content
end

---Build the whole-suite eval command for a `lib.runTests` file.
---@param file_path string
---@param source string
---@param opts neotest-nix.Config?
---@return string[]
local function eval_command(file_path, source, opts)
  if starts_with_attrset_function(source) then
    -- `nix-instantiate --eval` on a function prints its representation, not
    -- the applied result, so the function is applied explicitly. `--impure`
    -- (via `nix eval`, which supports it; `nix-instantiate` does not) covers
    -- defaults that reach for an impure lookup path like `<nixpkgs>`.
    local expr = ("(import (builtins.path { path = %s; })) { }"):format(
      eval.nix_string_literal(file_path)
    )
    local command = { nix_bin(opts), "eval", "--impure", "--json" }
    vim.list_extend(command, nix_command_features)
    append_nix_extra_args(command, opts)
    vim.list_extend(command, { "--expr", expr })
    return command
  end

  local command = { legacy_bin(opts, "instantiate") }
  append_nix_extra_args(command, opts)
  vim.list_extend(command, { "--eval", "--strict", "--json", file_path })
  return command
end

---@param args_strategy string|table|neotest.Strategy|nil
---@return neotest.Strategy?
local function run_strategy(args_strategy)
  if args_strategy == nil or args_strategy == "integrated" then
    return process.strategy
  end
  return nil
end

---Build a run spec that evaluates a whole `lib.runTests` file. Every position
---(file, namespace, or test) runs the same whole-suite command: `runTests`
---only ever reports failures, so filtering the resulting failure list by
---`position.name` (done by results.lua's existing nix-eval path, reused
---as-is) is simpler and just as correct as re-evaluating a name-filtered
---expression per test.
---@param position neotest-nix.Position
---@param root string
---@param extra_args string[]?
---@param opts neotest-nix.Config?
---@param args_strategy string|table|neotest.Strategy|nil
---@return neotest.RunSpec?
function M.build_spec(position, root, extra_args, opts, args_strategy)
  if position == nil or type(position.path) ~= "string" then
    return nil
  end

  local source = read_file(position.path)
  if source == nil then
    return nil
  end

  local command = eval_command(position.path, source, opts)
  if extra_args ~= nil then
    vim.list_extend(command, extra_args)
  end

  return {
    command = command,
    cwd = root,
    strategy = run_strategy(args_strategy),
    context = {
      attr = position.path,
      nix_bin = nix_bin(opts),
      path = position.path,
      pos_id = position.id,
      runner = "nix-eval",
      type = position.type,
    },
  }
end

return M
