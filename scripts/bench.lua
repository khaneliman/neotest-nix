-- Headless performance harness for neotest-nix discovery.
--
-- Drives the real adapter hot paths against a large tree (Nixpkgs) and reports
-- how long each synchronous burst takes, since that is what locks the UI:
-- Neotest runs discovery in an nio coroutine, but our is_test_file /
-- discover_positions do their file IO, comment stripping, and tree-sitter parse
-- synchronously with no yields, so each call blocks the event loop.
--
-- Run it through the dev shell so the nix grammar, neotest, and nio are on the
-- runtimepath:
--
--   scripts/bench.sh ~/Documents/github/nixpkgs            # walk + static parse
--   scripts/bench.sh ~/Documents/github/nixpkgs --profile  # + LuaJIT hotspots
--   scripts/bench.sh ~/Documents/github/nixpkgs --eval      # + eval enumeration
--
-- Flags: --profile, --eval, --sample=N (static parse sample, default 300),
--        --eval-sample=N (eval sample, default 10), --json.

local uv = vim.uv

---@type table<string, string|boolean>
local opts = { sample = "300", ["eval-sample"] = "10" }
local root
for _, a in ipairs(arg or {}) do
  local key, value = a:match("^%-%-([^=]+)=(.*)$")
  if key ~= nil then
    opts[key] = value
  elseif a:match("^%-%-") then
    opts[a:sub(3)] = true
  elseif root == nil then
    root = a
  end
end
root = vim.fs.normalize(root or vim.fn.expand("~/Documents/github/nixpkgs"))

local discover = require("neotest-nix.discover")
local nixpkgs = require("neotest-nix.nixpkgs")

---@param ns integer
---@return number
local function ms(ns)
  return ns / 1e6
end

local report = { root = root }

-- 1) Faithful discovery walk: exactly what Neotest does — descend with
-- filter_dir, classify .nix files with is_test_file. This single synchronous
-- stretch is the project-wide discovery freeze.
local function walk_phase()
  local stats = { dirs_seen = 0, dirs_pruned = 0, files_seen = 0, matched = 0 }
  local matched_paths = {}

  local function walk(dir, rel)
    local handle = uv.fs_scandir(dir)
    if handle == nil then
      return
    end
    while true do
      local name, typ = uv.fs_scandir_next(handle)
      if name == nil then
        break
      end
      local child_rel = rel == "" and name or (rel .. "/" .. name)
      local child = dir .. "/" .. name
      if typ == "directory" then
        stats.dirs_seen = stats.dirs_seen + 1
        if discover.filter_dir(name, child_rel, root) then
          walk(child, child_rel)
        else
          stats.dirs_pruned = stats.dirs_pruned + 1
        end
      elseif name:match("%.nix$") ~= nil then
        stats.files_seen = stats.files_seen + 1
        if discover.is_test_file(child) then
          stats.matched = stats.matched + 1
          matched_paths[#matched_paths + 1] = child
        end
      end
    end
  end

  local start = uv.hrtime()
  walk(root, "")
  stats.ms = ms(uv.hrtime() - start)
  report.walk = stats
  return matched_paths
end

-- 2) Static parse cost per matched file (the per-expand freeze). Sampled evenly
-- across the matched set.
local function static_phase(matched_paths)
  local n = tonumber(opts.sample) or 300
  local total = #matched_paths
  if total == 0 then
    report.static = { sampled = 0 }
    return
  end
  local step = math.max(1, math.floor(total / n))
  local positions, sampled, slowest = 0, 0, 0
  local start = uv.hrtime()
  for i = 1, total, step do
    local file_start = uv.hrtime()
    local tree = nixpkgs.discover_positions(matched_paths[i], root, {})
    slowest = math.max(slowest, ms(uv.hrtime() - file_start))
    sampled = sampled + 1
    if tree ~= nil then
      for _, p in tree:iter() do
        if p.type == "test" then
          positions = positions + 1
        end
      end
    end
  end
  local elapsed = ms(uv.hrtime() - start)
  report.static = {
    sampled = sampled,
    positions = positions,
    ms = elapsed,
    ms_per_file = elapsed / sampled,
    slowest_ms = slowest,
  }
end

-- 3) Optional eval enumeration cost (the Phase 1.5 fallback). nio-driven.
local function eval_phase(matched_paths)
  local nio = require("nio")
  local n = tonumber(opts["eval-sample"]) or 10
  local done, err = false, nil
  nio.run(function()
    local ok, e = pcall(function()
      local candidates, count = {}, 0
      for _, path in ipairs(matched_paths) do
        local tree = nixpkgs.discover_positions(path, root, {})
        local has = false
        if tree ~= nil then
          for _, p in tree:iter() do
            if p.type == "test" then
              has = true
              break
            end
          end
        end
        if not has then
          count = count + 1
          candidates[count] = path
          if count >= n then
            break
          end
        end
      end

      local total, ok_count = 0, 0
      for _, path in ipairs(candidates) do
        local start = uv.hrtime()
        local tree = nixpkgs.discover_positions(path, root, { discover_nixpkgs_eval_tests = true })
        total = total + ms(uv.hrtime() - start)
        if tree ~= nil then
          for _, p in tree:iter() do
            if p.type == "test" then
              ok_count = ok_count + 1
              break
            end
          end
        end
      end
      report.eval = {
        candidates = #candidates,
        with_tests = ok_count,
        ms_total = total,
        ms_per_pkg = #candidates > 0 and (total / #candidates) or 0,
      }
    end)
    err = not ok and e or nil
    done = true
  end)
  vim.wait(600000, function()
    return done
  end, 50)
  if err ~= nil then
    error(err)
  end
end

-- 4) Optional LuaJIT sampling profiler over the walk, to auto-surface the hot
-- functions/lines without manual instrumentation.
local function profile_walk()
  local ok, profile = pcall(require, "jit.profile")
  if not ok then
    report.profile = { error = "jit.profile unavailable" }
    return walk_phase()
  end

  local counts = {}
  profile.start("li1", function(thread)
    local stack = profile.dumpstack(thread, "lf", 1)
    counts[stack] = (counts[stack] or 0) + 1
  end)
  local matched = walk_phase()
  profile.stop()

  local rows = {}
  for stack, n in pairs(counts) do
    rows[#rows + 1] = { stack = stack:gsub("%s+$", ""), samples = n }
  end
  table.sort(rows, function(a, b)
    return a.samples > b.samples
  end)
  local top = {}
  for i = 1, math.min(15, #rows) do
    top[i] = rows[i]
  end
  report.profile = { top = top }
  return matched
end

local matched_paths
if opts.profile then
  matched_paths = profile_walk()
else
  matched_paths = walk_phase()
end
static_phase(matched_paths)
if opts.eval then
  eval_phase(matched_paths)
end

-- Human summary.
local w = report.walk
io.write(("\nroot: %s\n"):format(root))
io.write(
  ("walk:   %d dirs (%d pruned), %d .nix files, %d matched in %.0f ms\n"):format(
    w.dirs_seen,
    w.dirs_pruned,
    w.files_seen,
    w.matched,
    w.ms
  )
)
local s = report.static
if s and s.sampled and s.sampled > 0 then
  io.write(
    ("static: %d sampled, %d positions, %.2f ms/file (slowest %.2f ms) -> ~%.1f s for all %d\n"):format(
      s.sampled,
      s.positions,
      s.ms_per_file,
      s.slowest_ms,
      s.ms_per_file * w.matched / 1000,
      w.matched
    )
  )
end
if report.eval then
  local e = report.eval
  io.write(
    ("eval:   %d candidates, %d had tests, %.0f ms/pkg\n"):format(
      e.candidates,
      e.with_tests,
      e.ms_per_pkg
    )
  )
end
if report.profile and report.profile.top then
  io.write("hotspots (walk, by samples):\n")
  for _, r in ipairs(report.profile.top) do
    io.write(("  %5d  %s\n"):format(r.samples, r.stack))
  end
end

if opts.json then
  io.write("BENCH_JSON " .. vim.json.encode(report) .. "\n")
end
