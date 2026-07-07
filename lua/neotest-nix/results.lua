local paths = require("neotest-nix.paths")
local vm = require("neotest-nix.vm")

local M = {}

local uv = vim.uv

---@param text string
---@return string
local function strip_ansi(text)
  local stripped = text:gsub("\27%[[0-?]*[ -/]*[@-~]", "")
  return stripped
end

---@param path string
---@return string?
local function read_file(path)
  if type(path) ~= "string" or uv.fs_stat(path) == nil then
    return nil
  end

  local file = io.open(path, "r")
  if file == nil then
    return nil
  end

  local content = file:read("*a")
  file:close()
  return content
end

---@param line string
---@return string?
local function parse_error_line(line)
  line = strip_ansi(line)
  local parsed = line:match("^%s*error:%s*(.*)$")
  if parsed == nil then
    return nil
  end

  local trimmed = vim.trim(parsed)
  if trimmed == "" then
    return nil
  end

  return trimmed
end

local nix_unit_marker
local nix_unit_summary

---@param output string
---@return string
local function failure_message(output)
  local lines = {}
  local collecting = false

  for line in output:gmatch("[^\r\n]+") do
    line = strip_ansi(line)
    local parsed = parse_error_line(line)
    if not collecting and parsed ~= nil then
      table.insert(lines, parsed)
      collecting = true
    elseif collecting then
      local status = nix_unit_marker(line)
      if status ~= nil or nix_unit_summary(line) then
        break
      end
      table.insert(lines, line)
    end
  end

  if #lines == 0 then
    return "Nix command failed"
  end

  return vim.trim(table.concat(lines, "\n"))
end

---@param path string
---@param root string
---@return string?
local function local_error_path(path, root)
  local translated = paths.translate_store_path(path, root)
  if uv.fs_stat(translated) == nil then
    return nil
  end

  local normalized_root = vim.fs.normalize(root)
  local normalized_path = vim.fs.normalize(translated)
  if
    normalized_path == normalized_root
    or normalized_path:sub(1, #normalized_root + 1) == normalized_root .. "/"
  then
    return normalized_path
  end

  return nil
end

---@class neotest-nix.ParsedError
---@field message string
---@field path string
---@field line integer
---@field column integer
---@field severity integer?

---@param output string
---@param root string
---@return neotest-nix.ParsedError[]
function M.parse_errors(output, root)
  local errors = {}
  -- Track the most recent `error:` line so each location is attributed to the
  -- error it belongs to. A run with `--keep-going` emits several independent
  -- errors, each followed by its own `at <path>:row:col:` frame(s); a single
  -- shared message would mislabel every location with the first error's text.
  local current_message

  for line in output:gmatch("[^\r\n]+") do
    line = strip_ansi(line)
    local parsed = parse_error_line(line)
    if parsed ~= nil then
      current_message = parsed
    end

    local path, row, column = line:match("^%s*at%s+(.+):(%d+):(%d+):")
    if path ~= nil then
      local translated = local_error_path(path, root)
      if translated ~= nil then
        table.insert(errors, {
          message = current_message or failure_message(output),
          path = translated,
          line = tonumber(row) - 1,
          column = tonumber(column) - 1,
          severity = vim.diagnostic.severity.ERROR,
        })
      end
    end
  end

  return errors
end

-- nix-unit prints one line per test attribute, prefixed with a status glyph,
-- followed by an optional detail block (a value diff or an evaluation error)
-- that runs until the next attribute or the summary line.
local nix_unit_markers = {
  ["\226\156\133"] = "passed", -- ✅
  ["\226\157\140"] = "failed", -- ❌
  ["\226\152\162"] = "failed", -- ☢ (radioactive sign, optionally + variation selector)
}

-- Summary lines are emitted once per run, e.g. "🎉 3/3 successful".
-- Guard against legitimate detail lines containing the same fraction text.
local nix_unit_summary_markers = {
  ["\240\159\142\137"] = true, -- 🎉
  ["\240\159\152\162"] = true, -- 😢
}

---@param line string
---@return ("passed"|"failed")?, string?
nix_unit_marker = function(line)
  line = strip_ansi(line)
  for glyph, status in pairs(nix_unit_markers) do
    if vim.startswith(line, glyph) then
      -- Skip the glyph and optional variation selector; nix-unit may print
      -- runtime-prefixed names that include separators outside Lua identifiers.
      local rest = line:sub(#glyph + 1):gsub("^\239\184\143", "", 1)
      local name = vim.trim(rest)
      if name ~= "" then
        return status, name
      end
      return status, nil
    end
  end
  return nil, nil
end

---@param line string
---@return boolean
nix_unit_summary = function(line)
  line = strip_ansi(line)
  -- e.g. "🎉 3/3 successful", "😢 1/3 successful", "error: Tests failed".
  -- Tolerate spacing drift so a summary line is never mistaken for a detail
  -- line and appended to the previous attribute's message.
  for glyph in pairs(nix_unit_summary_markers) do
    if vim.startswith(line, glyph) then
      return line:match("^" .. glyph .. "%s+%d+/%d+%s+successful%s*$") ~= nil
    end
  end

  return line:match("^%s*error:%s*Tests%s+failed%s*$") ~= nil
end

---@class neotest-nix.NixUnitEntry
---@field name string
---@field status "passed"|"failed"
---@field message string

---Parse nix-unit's per-attribute output. Works on both passing (exit 0) and
---failing (exit 1) runs, since nix-unit reports every attribute either way.
---@param output string
---@return neotest-nix.NixUnitEntry[]
function M.parse_nix_unit(output)
  local entries = {}
  ---@type { name: string, status: "passed"|"failed", lines: string[] }?
  local current

  local function flush()
    if current ~= nil then
      local message = vim.trim(table.concat(current.lines, "\n"))
      table.insert(entries, { name = current.name, status = current.status, message = message })
      current = nil
    end
  end

  for line in (output .. "\n"):gmatch("(.-)\n") do
    line = strip_ansi(line)
    local status, name = nix_unit_marker(line)
    if status ~= nil and name ~= nil then
      flush()
      current = { name = name, status = status, lines = {} }
    elseif nix_unit_summary(line) then
      flush()
    elseif current ~= nil then
      table.insert(current.lines, line)
    end
  end
  flush()

  return entries
end

---@param tree neotest.Tree
---@return neotest.Position[]
local function test_positions(tree)
  local positions = {}

  for _, position in tree:iter() do
    if position.type == "test" then
      table.insert(positions, position)
    end
  end

  return positions
end

---@param tree neotest.Tree
---@return neotest-nix.Position[]
local function vm_positions(tree)
  local positions = {}

  for _, position in tree:iter() do
    ---@cast position neotest-nix.Position
    if position.type == "test" and position.test_script_range ~= nil then
      table.insert(positions, position)
    end
  end

  return positions
end

---@param position neotest.Position
---@param error neotest-nix.ParsedError
---@return boolean
local function contains_error(position, error)
  if vim.fs.normalize(position.path) ~= error.path then
    return false
  end

  local range = position.total_range or position.range
  if range == nil then
    return false
  end

  return error.line >= range[1] and error.line <= range[3]
end

---@param tree neotest.Tree
---@param spec neotest.RunSpec
---@param error neotest-nix.ParsedError
---@param positions neotest.Position[]
---@return string
local function result_id_for_error(tree, spec, error, positions)
  local context = spec.context or {}
  -- Pin to the run node only for single-test runs; broader runs distribute
  -- errors per position below instead of collapsing onto the covering node.
  if context.type == "test" and context.pos_id ~= nil and tree:get_key(context.pos_id) ~= nil then
    return context.pos_id
  end

  for _, position in ipairs(positions) do
    if contains_error(position, error) then
      return position.id
    end
  end

  return tree:data().id
end

---Select the single VM test a traceback can be attributed to.
---A NixOS VM failure prints a Python traceback whose line numbers are
---relative to that test's generated script; line numbers reset per test,
---so they cannot tell sibling VM tests apart. Only attribute when the run
---unambiguously targets one VM test: either there is a single VM position,
---or the run context names one. A broader run (e.g. `nix flake check` over
---several VM tests) returns nil rather than blaming every VM test.
---@param tree neotest.Tree
---@param spec neotest.RunSpec
---@return neotest-nix.Position?
local function vm_target(tree, spec)
  local positions = vm_positions(tree)
  if #positions <= 1 then
    return positions[1]
  end

  local context = spec.context or {}
  if context.pos_id ~= nil then
    for _, position in ipairs(positions) do
      if position.id == context.pos_id then
        return position
      end
    end
  end

  return nil
end

---@param results table<string, neotest.Result>
---@param id string
---@param error neotest-nix.ParsedError
local function add_error(results, id, error)
  results[id] = results[id] or {
    status = "failed",
    errors = {},
  }

  table.insert(results[id].errors, {
    message = error.message,
    line = error.line,
    column = error.column,
    severity = error.severity,
  })
end

---@param results table<string, neotest.Result>
---@param target neotest-nix.Position?
---@param output string
---@param start_at integer?
---@return integer
local function add_vm_tracebacks(results, target, output, start_at)
  local tracebacks = vm.parse_python_tracebacks(output)
  start_at = start_at or 1
  if target == nil or #tracebacks < start_at then
    return #tracebacks
  end

  for index = start_at, #tracebacks do
    local traceback = tracebacks[index]
    local line = vm.test_script_line(target, traceback.line)
    if line ~= nil then
      add_error(results, target.id, {
        message = traceback.message,
        path = target.path,
        line = line,
        column = 0,
        severity = vim.diagnostic.severity.ERROR,
      })
    end
  end

  return #tracebacks
end

-- nix-unit names each test by its dotted path within the run set, which may
-- carry a runtime prefix the source has no position for (e.g.
-- "systems.x86_64-linux.testFoo" for a per-system suite). Match the most
-- specific thing first, then fall back to the leaf attribute, which is what a
-- position is named. A leaf shared by several positions is left unmatched
-- rather than attributed to the wrong one.
--
-- Shared by the final (whole-output) nix-unit parse and the incremental
-- streaming parse, so both resolve a name to a position the same way.
---@param positions neotest.Position[]
---@param name string
---@return neotest.Position?
local function match_nix_unit_position(positions, name)
  for _, position in ipairs(positions) do
    ---@cast position neotest-nix.Position
    if position.name == name or position.attr_path == name then
      return position
    end
  end
  -- A suffix shared by several attr_paths is ambiguous, so fall through to
  -- the leaf check (which carries the same guard) rather than blaming the
  -- first match.
  local suffix_match
  for _, position in ipairs(positions) do
    ---@cast position neotest-nix.Position
    local attr_path = position.attr_path
    if attr_path ~= nil and attr_path:sub(-(#name + 1)) == "." .. name then
      if suffix_match ~= nil then
        suffix_match = nil
        break
      end
      suffix_match = position
    end
  end
  if suffix_match ~= nil then
    return suffix_match
  end

  local leaf = name:match("[^.]+$") or name
  local found
  for _, position in ipairs(positions) do
    if position.name == leaf then
      if found ~= nil then
        return nil
      end
      found = position
    end
  end
  return found
end

---Fold nix-unit per-attribute entries into per-position results. Shared by the
---final (whole-output) parse and the incremental streaming parse: a passing
---occurrence never overwrites an earlier failure for the same position, since
---the same leaf can appear once per system and any failing occurrence wins.
---@param entries neotest-nix.NixUnitEntry[]
---@param positions neotest.Position[]
---@return table<string, neotest.Result>
---@return boolean any_failed
local function nix_unit_entry_results(entries, positions)
  local results = {}
  local any_failed = false
  for _, entry in ipairs(entries) do
    if entry.status ~= "passed" then
      any_failed = true
    end

    local position = match_nix_unit_position(positions, entry.name)
    if position ~= nil then
      local existing = results[position.id]
      if entry.status == "passed" then
        -- Keep an earlier failure: the same leaf can appear under several
        -- systems, and any failing occurrence should win.
        if existing == nil then
          results[position.id] = { status = "passed", short = entry.message }
        end
      else
        results[position.id] = {
          status = "failed",
          short = entry.message,
          errors = {
            { message = entry.message ~= "" and entry.message or (entry.name .. " failed") },
          },
        }
      end
    end
  end

  return results, any_failed
end

---Build results for a nix-unit run from its per-attribute output. Each test
---attribute is mapped to its position by name; the run's own node carries the
---overall verdict so file/suite runs still report a status.
---@param tree neotest.Tree
---@param output string
---@param code integer
---@param root string
---@param spec neotest.RunSpec
---@return table<string, neotest.Result>
local function nix_unit_results(tree, output, code, root, spec)
  local clean_output = strip_ansi(output)
  local entries = M.parse_nix_unit(clean_output)
  local root_id = tree:data().id

  if #entries == 0 then
    -- No per-attribute lines (e.g. a top-level eval error before any test ran).
    if code == 0 then
      return { [root_id] = { status = "passed", short = clean_output } }
    end

    local parsed = M.parse_errors(clean_output, root)
    local results = {
      [root_id] = { status = "failed", short = failure_message(clean_output), errors = {} },
    }
    local positions = test_positions(tree)
    for _, error in ipairs(parsed) do
      add_error(results, result_id_for_error(tree, spec, error, positions), error)
    end
    return results
  end

  local positions = test_positions(tree)
  local results, any_failed = nix_unit_entry_results(entries, positions)

  if results[root_id] == nil then
    results[root_id] = { status = any_failed and "failed" or "passed", short = clean_output }
  end

  return results
end

---Render a `lib.runTests` value (expected/result) compactly for a failure
---message. Strings pass through; everything else is JSON-encoded so attrsets and
---lists stay readable. Long values are truncated so the summary line stays short.
---@param value any
---@return string
local function format_eval_value(value)
  local text
  if type(value) == "string" then
    text = value
  else
    local ok, encoded = pcall(vim.json.encode, value)
    text = (ok and encoded ~= nil) and encoded or tostring(value)
  end
  if #text > 200 then
    text = text:sub(1, 197) .. "..."
  end
  return text
end

---Human-readable detail for one `lib.runTests` failure entry, e.g.
---`expected 1, got 2`. Returns nil when the entry carries no expected/result
---(then the caller falls back to a bare "failed").
---@param failure any
---@return string?
local function eval_failure_detail(failure)
  if type(failure) ~= "table" then
    return nil
  end
  if failure.expected == nil and failure.result == nil then
    return nil
  end
  return ("expected %s, got %s"):format(
    format_eval_value(failure.expected),
    format_eval_value(failure.result)
  )
end

-- Monotonic suffix so concurrent eval runs never collide on an output path.
local output_seq = 0

---Write `text` to a temp file and return its path, or nil on failure. Used to
---give nix-eval results their own trimmed output: `nix-instantiate` ends its
---output with a trailing newline, so the captured file's last line is blank and
---the result (`[]` on success) is pushed out of view in Neotest's output box.
---
---Neotest invokes `results` from a libuv (fast event) context, where `vim.fn.*`
---is forbidden, so the path is built from `vim.uv` primitives and written with
---plain Lua IO rather than `vim.fn.tempname`.
---@param text string
---@return string?
local function write_output(text)
  output_seq = output_seq + 1
  local dir = uv.os_tmpdir() or "/tmp"
  local path = ("%s/neotest-nix-%d-%d-%d.out"):format(dir, uv.os_getpid(), uv.hrtime(), output_seq)
  local file = io.open(path, "w")
  if file == nil then
    return nil
  end
  file:write(text)
  file:close()
  return path
end

---@param text string
---@return table?
local function decode_last_json_array(text)
  local last
  local len = #text
  local start = 1

  while start <= len do
    local open = text:find("%[", start)
    if open == nil then
      break
    end

    local depth = 0
    local in_string = false
    local escaped = false
    for index = open, len do
      local char = text:sub(index, index)
      if in_string then
        if escaped then
          escaped = false
        elseif char == "\\" then
          escaped = true
        elseif char == '"' then
          in_string = false
        end
      elseif char == '"' then
        in_string = true
      elseif char == "[" then
        depth = depth + 1
      elseif char == "]" then
        depth = depth - 1
        if depth == 0 then
          local ok, decoded = pcall(vim.json.decode, text:sub(open, index))
          if ok and type(decoded) == "table" then
            last = decoded
          end
          start = index + 1
          break
        end
      end
    end

    if start <= open then
      start = open + 1
    end
  end

  return last
end

---Build results for a legacy eval run (lib/tests/misc.nix), whose output is a
---`lib.runTests` failure list: `[]` means every test passed, otherwise each
---entry names a failing test. The JSON is extracted from the merged
---stdout/stderr with a balanced-bracket match.
---
---`lib.runTests` only ever reports failures, so a passing test produces no
---output of its own. Rather than surface the bare `[]` (which reads as "nothing
---ran"), each position is given an explicit pass/fail `short` message, and
---failures carry an `expected/got` detail anchored to the test's line.
---@param tree neotest.Tree
---@param output string
---@param code integer
---@return table<string, neotest.Result>
local function nix_eval_results(tree, output, code)
  local id = tree:data().id
  local clean = strip_ansi(output)

  local value = decode_last_json_array(clean)

  -- A trimmed copy of the eval output, so the box's last line is the result
  -- (`[]` or the failure list) rather than the trailing blank Nix prints.
  local out = write_output(vim.trim(clean))
  local function attach(results)
    if out ~= nil then
      for _, result in pairs(results) do
        result.output = out
      end
    end
    return results
  end

  if code == 0 and value ~= nil then
    local failures = {}
    local names = {}
    for _, failure in ipairs(value) do
      local name = (type(failure) == "table" and failure.name) or tostring(failure)
      failures[name] = failure
      names[#names + 1] = name
    end

    local positions = test_positions(tree)
    if #positions > 0 then
      local results = {}
      for _, position in ipairs(positions) do
        local failure = failures[position.name]
        if failure == nil then
          results[position.id] = {
            status = "passed",
            short = ("%s: passed"):format(position.name),
          }
        else
          local detail = eval_failure_detail(failure)
          local message = detail and ("%s: %s"):format(position.name, detail)
            or ("%s: failed"):format(position.name)
          local err = { message = message }
          if type(position.range) == "table" and position.range[1] ~= nil then
            err.line = position.range[1]
          end
          results[position.id] = { status = "failed", short = message, errors = { err } }
        end
      end
      -- Summarize the file/namespace node when it is not itself a test position.
      if results[id] == nil then
        if #value > 0 then
          local message = ("%d failing: %s"):format(#names, table.concat(names, ", "))
          results[id] = { status = "failed", short = message, errors = { { message = message } } }
        else
          results[id] = {
            status = "passed",
            short = ("all %d tests passed"):format(#positions),
          }
        end
      end
      return attach(results)
    end

    -- No per-test positions (static parse found nothing): report at file level.
    if #value == 0 then
      return attach({ [id] = { status = "passed", short = "all tests passed" } })
    end

    local message = ("%d failing: %s"):format(#names, table.concat(names, ", "))
    return attach({
      [id] = { status = "failed", short = message, errors = { { message = message } } },
    })
  end

  return attach({ [id] = { status = "failed", short = failure_message(clean), errors = {} } })
end

---@param tree neotest.Tree
---@param output string
---@param code integer
---@return table<string, neotest.Result>
local function namaka_results(tree, output, code)
  local root_id = tree:data().id
  if code == 0 then
    return { [root_id] = { status = "passed", short = output } }
  end

  return {
    [root_id] = {
      status = "failed",
      short = vim.trim(output) ~= "" and output or "Namaka command failed",
      errors = {
        { message = vim.trim(output) ~= "" and output or "Namaka command failed" },
      },
    },
  }
end

-- A failed `nix build`/`nix flake check` names the derivation it could not
-- build, e.g. `error: builder for '/nix/store/<hash>-<name>.drv' failed with
-- exit code 1` and `For full logs, run 'nix log /nix/store/<hash>-<name>.drv'`.
-- Only lines that actually name the failure (rather than any incidental
-- `.drv` mention) are considered, and duplicates are collapsed so
-- `--keep-going` runs that repeat the same derivation only queue it once.
---@param output string
---@return string[]
local function detect_failed_drvs(output)
  local seen = {}
  local drvs = {}

  for line in output:gmatch("[^\r\n]+") do
    line = strip_ansi(line)
    if line:find("failed", 1, true) or line:find("nix log", 1, true) then
      for drv in line:gmatch("(/nix/store/[^%s'\"]+%.drv)") do
        if not seen[drv] then
          seen[drv] = true
          table.insert(drvs, drv)
        end
      end
    end
  end

  return drvs
end

-- Bounds on the `nix log` enrichment so a failing build never makes Neotest
-- feel slow or floods the output box: each call is timeboxed, and only the
-- last slice of a log is kept.
local NIX_LOG_TIMEOUT_MS = 3000
local NIX_LOG_TAIL_BYTES = 4096

---@param text string
---@param max_bytes integer
---@return string
local function tail_bytes(text, max_bytes)
  if #text <= max_bytes then
    return text
  end
  return text:sub(#text - max_bytes + 1)
end

---Run `nix log <drv>`, bounded by `NIX_LOG_TIMEOUT_MS`. Mirrors the
---`vim.system` + `nio.control.future` pattern already used to shell out
---synchronously from an async context (see `neotest-nix.eval`'s `run`
---helper). Returns nil on any failure (spawn error, timeout, non-zero exit,
---or empty output) so the caller can fall back to a bare repro hint.
---@param drv string
---@param root string
---@param nix_bin string
---@return string?
local function run_nix_log(drv, root, nix_bin)
  local nio = require("nio")
  local future = nio.control.future()
  local ok = pcall(vim.system, { nix_bin, "log", drv }, {
    cwd = root,
    text = true,
    timeout = NIX_LOG_TIMEOUT_MS,
  }, function(system_result)
    future.set(system_result)
  end)
  if not ok then
    return nil
  end

  local system_result = future.wait()
  if system_result.code ~= 0 then
    return nil
  end

  local stdout = vim.trim(system_result.stdout or "")
  if stdout == "" then
    return nil
  end

  return stdout
end

---Build the enrichment text appended after a failed build's own output: a
---separator, the (capped) `nix log` tail when it could be fetched, and a
---bare `nix log <drv>` line the user can copy-paste to see the rest. Never
---raises and never returns nil once at least one `.drv` was detected, so a
---`nix log` failure still leaves the repro hint behind.
---@param drv string
---@param root string
---@param nix_bin string
---@return string
local function drv_log_section(drv, root, nix_bin)
  local lines = { "---" }
  local log = run_nix_log(drv, root, nix_bin)
  if log ~= nil then
    table.insert(lines, tail_bytes(log, NIX_LOG_TAIL_BYTES))
  end
  table.insert(lines, ("%s log %s"):format(nix_bin, drv))
  return table.concat(lines, "\n")
end

---@param results table<string, neotest.Result>
---@return integer
local function count_failed(results)
  local count = 0
  for _, result in pairs(results) do
    if result.status == "failed" then
      count = count + 1
    end
  end
  return count
end

---Enrich a failed build/flake-check result with `nix log` output for any
---failed derivation named in its own output. Bounded to the number of
---failed positions in this run, so a pathological `--keep-going` run with
---many failures cannot turn one result into dozens of `nix log` calls.
---Returns nil when no `.drv` was detected, leaving the result untouched.
---@param output string
---@param root string
---@param results table<string, neotest.Result>
---@param nix_bin string
---@return string?
local function build_drv_enrichment(output, root, results, nix_bin)
  local drvs = detect_failed_drvs(output)
  if #drvs == 0 then
    return nil
  end

  local max_logs = math.max(count_failed(results), 1)
  local sections = {}
  for index = 1, math.min(#drvs, max_logs) do
    table.insert(sections, drv_log_section(drvs[index], root, nix_bin))
  end

  return table.concat(sections, "\n\n")
end

---@param spec neotest.RunSpec
---@param result neotest.StrategyResult
---@param tree neotest.Tree
---@return table<string, neotest.Result>
function M.results(spec, result, tree)
  local root = spec.cwd or uv.cwd() or "."
  local output = read_file(result.output) or ""
  output = paths.translate_string(output, root)

  if spec.context ~= nil and spec.context.runner == "nix-unit" then
    return nix_unit_results(tree, output, result.code, root, spec)
  end

  if spec.context ~= nil and spec.context.runner == "nix-eval" then
    return nix_eval_results(tree, output, result.code)
  end

  if spec.context ~= nil and spec.context.runner == "namaka" then
    return namaka_results(tree, output, result.code)
  end

  if result.code == 0 then
    return {
      [tree:data().id] = {
        status = "passed",
        short = output,
      },
    }
  end

  local parsed_errors = M.parse_errors(output, root)
  local results = {}
  local positions = test_positions(tree)

  for _, parsed in ipairs(parsed_errors) do
    add_error(results, result_id_for_error(tree, spec, parsed, positions), parsed)
  end
  add_vm_tracebacks(results, vm_target(tree, spec), output)

  if vim.tbl_isempty(results) then
    results[tree:data().id] = {
      status = "failed",
      short = failure_message(output),
      errors = {},
    }
  end

  local context = spec.context or {}
  local nix_bin = context.nix_bin or "nix"
  local enrichment = build_drv_enrichment(output, root, results, nix_bin)
  if enrichment ~= nil then
    local out = write_output(vim.trim(output) .. "\n\n" .. enrichment)
    if out ~= nil then
      for _, entry in pairs(results) do
        entry.output = out
      end
    end
  end

  return paths.translate_result_paths(results, root)
end

---Incrementally parse nix-unit's per-attribute output as it streams in,
---returning only positions whose result changed since the last call. Only
---complete lines (those already terminated by a newline) are handed to
---`M.parse_nix_unit`: a marker or detail line still arriving byte-by-byte
---must never be matched to a position before it has fully arrived (e.g. a
---truncated name that happens to collide with a *different*, shorter
---attribute name). A multi-line diff block is unaffected by this since it
---keeps accumulating into the same attribute's entry, exactly like the final
---(whole-output) parse already does; nothing here needs to guess where a
---detail block ends. Whatever is reported here is always superseded by the
---authoritative parse in `nix_unit_results` once the run finishes, so a
---mis-resolved or still-partial message never survives past the final result.
---@param text string
---@param positions neotest.Position[]
---@param streamed table<string, { status: string, short: string? }>
---@return table<string, neotest.Result>
local function nix_unit_stream_results(text, positions, streamed)
  local complete = text:match("^(.*\n)")
  if complete == nil then
    return {}
  end

  local entries = M.parse_nix_unit(complete)
  local entry_results = nix_unit_entry_results(entries, positions)

  local changed = {}
  for id, result in pairs(entry_results) do
    local previous = streamed[id]
    if previous == nil or previous.status ~= result.status or previous.short ~= result.short then
      changed[id] = result
    end
    streamed[id] = { status = result.status, short = result.short }
  end

  return changed
end

---@param spec neotest.RunSpec
---@param tree neotest.Tree
---@return fun(output_stream: fun(): string?): fun(): table<string, neotest.Result>?
function M.stream(spec, tree)
  return function(output_stream)
    local output = {}
    local parsed_error_count = 0
    local traceback_count = 0
    local positions = test_positions(tree)
    local target = vm_target(tree, spec)
    local is_nix_unit = spec.context ~= nil and spec.context.runner == "nix-unit"
    ---@type table<string, { status: string, short: string? }>
    local streamed_nix_unit = {}

    return function()
      while true do
        local chunk = output_stream()
        if chunk == nil then
          return nil
        end

        table.insert(output, chunk)
        local text = table.concat(output)
        local root = spec.cwd or uv.cwd() or "."

        if is_nix_unit then
          local stream_results = nix_unit_stream_results(text, positions, streamed_nix_unit)
          if not vim.tbl_isempty(stream_results) then
            return paths.translate_result_paths(stream_results, root)
          end
        else
          local parsed_errors = M.parse_errors(text, root)
          local stream_results = {}

          for index = parsed_error_count + 1, #parsed_errors do
            local parsed = parsed_errors[index]
            add_error(stream_results, result_id_for_error(tree, spec, parsed, positions), parsed)
          end
          parsed_error_count = #parsed_errors

          traceback_count = add_vm_tracebacks(stream_results, target, text, traceback_count + 1)

          if not vim.tbl_isempty(stream_results) then
            for _, result in pairs(stream_results) do
              result.short = text
            end
            return paths.translate_result_paths(stream_results, root)
          end
        end
      end
    end
  end
end

return M
