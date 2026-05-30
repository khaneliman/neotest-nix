-- Public configuration types, defined in their own module so init.lua stays
-- code-only and references them by name. Nothing requires this at runtime;
-- lua-language-server still resolves the classes across the workspace.
local M = {}

---A single flake output to enumerate per system during eval-based discovery.
---@class neotest-nix.EvalOutput
---@field attr string Flake output to enumerate (e.g. "checks").
---@field match? string Lua pattern filtering attribute names.

---Adapter configuration. Every field is optional.
---@class neotest-nix.Config
---@field parser_runtime_paths? string[] Extra runtimepath roots containing parser/nix.so.
---@field discover_eval_checks? boolean Evaluate the flake to discover generated outputs.
---@field eval_outputs? neotest-nix.EvalOutput[] Outputs to enumerate when discovery is on.

return M
