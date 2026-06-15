-- Nixpkgs-style discovery and legacy `nix-build` command construction.
--
-- The rest of the adapter assumes a flake project: `discover.root` resolves a
-- `flake.nix`, and `spec.build_spec` emits `.#installable` commands. Nixpkgs has
-- a `flake.nix` at its root too, but hacking on it is built around the legacy
-- commands (`nix-build -A`), which evaluate the working tree in place instead of
-- copying it to the store on every edit. This module owns everything specific to
-- that mode so the flake paths stay untouched.
--
-- Phase 1 covers packages under `pkgs/by-name/`: the directory name is the
-- attribute by convention, so `pkgs/by-name/he/hello/package.nix` maps to
-- `hello`, and its `passthru.tests` run with `nix-build -A hello.tests.<name>`.

local M = {}

local uv = vim.uv

---@param path string
---@return boolean
local function path_exists(path)
  return uv.fs_stat(path) ~= nil
end

-- Marker results are stable for a session and the upward walk re-checks the
-- same ancestors for every one of Nixpkgs' tens of thousands of package files,
-- so cache them. Without this, discovery spends most of its time re-stat-ing
-- `pkgs`, `pkgs/by-name`, and the root over and over.
---@type table<string, boolean>
local marker_cache = {}

---True when `dir` is the root of a Nixpkgs-shaped tree. The combination is
---required to avoid claiming an ordinary flake repo that merely has a `lib/`.
---@param dir string
---@return boolean
local function has_markers(dir)
  local cached = marker_cache[dir]
  if cached ~= nil then
    return cached
  end

  local function exists(rel)
    return path_exists(vim.fs.joinpath(dir, rel))
  end

  local result = exists("pkgs/by-name")
    and exists("lib")
    and (exists("nixos") or exists("pkgs/top-level/all-packages.nix"))
  marker_cache[dir] = result
  return result
end

---Walk upward from a file (or directory) to the nearest Nixpkgs root.
---@param file_path string
---@return string?
function M.detect_root(file_path)
  local normalized = vim.fs.normalize(file_path)
  local stat = uv.fs_stat(normalized)
  local dir = (stat ~= nil and stat.type == "directory") and normalized
    or vim.fs.dirname(normalized)

  while dir ~= nil and dir ~= "" do
    if has_markers(dir) then
      return dir
    end
    local parent = vim.fs.dirname(dir)
    if parent == dir then
      break
    end
    dir = parent
  end

  return nil
end

---Resolve how a Nixpkgs root should be treated.
---  `nixpkgs_mode == false` -> always flake (escape hatch for a real flake).
---  `nixpkgs_mode == true`  -> always nixpkgs.
---  unset                   -> nixpkgs when the root carries the markers.
---@param root string
---@param opts neotest-nix.Config?
---@return "nixpkgs"|"flake"
function M.mode_for(root, opts)
  opts = opts or {}
  if opts.nixpkgs_mode == false then
    return "flake"
  end
  if opts.nixpkgs_mode == true then
    return "nixpkgs"
  end
  return has_markers(root) and "nixpkgs" or "flake"
end

---The Nixpkgs root that applies to a file, or nil when nixpkgs mode does not
---apply. Auto-detection finds the root by markers; `nixpkgs_mode = true` forces
---the mode even on a tree without markers by falling back to the flake root.
---@param file_path string
---@param opts neotest-nix.Config?
---@return string?
function M.resolve_root(file_path, opts)
  opts = opts or {}
  if opts.nixpkgs_mode == false then
    return nil
  end

  local root = M.detect_root(file_path)
  if root ~= nil then
    return root
  end

  if opts.nixpkgs_mode == true then
    return require("neotest-nix.discover").root(file_path)
  end

  return nil
end

---Whether an adapter root is a Nixpkgs root in nixpkgs mode. Used by the
---directory filter, which receives the root but not a file path.
---@param root string
---@param opts neotest-nix.Config?
---@return boolean
function M.is_root(root, opts)
  opts = opts or {}
  if opts.nixpkgs_mode == false then
    return false
  end
  if opts.nixpkgs_mode == true then
    return true
  end
  return has_markers(root)
end

---@param file_path string
---@param root string
---@return string?
local function relpath(file_path, root)
  local normalized = vim.fs.normalize(file_path)
  local normalized_root = vim.fs.normalize(root)
  if normalized == normalized_root then
    return ""
  end
  local prefix = normalized_root .. "/"
  if normalized:sub(1, #prefix) ~= prefix then
    return nil
  end
  return normalized:sub(#prefix + 1)
end

---Attribute name for a `pkgs/by-name` package file. The by-name convention
---guarantees the leaf directory equals the attribute, so this is a pure path
---match with no evaluation.
---@param file_path string
---@param root string
---@return string?
function M.attr_for_by_name(file_path, root)
  local rel = relpath(file_path, root)
  if rel == nil then
    return nil
  end
  local _, name = rel:match("^pkgs/by%-name/([^/]+)/([^/]+)/package%.nix$")
  return name
end

---Whether a file under a Nixpkgs root is a recognized test file. Kept cheap (no
---evaluation) so it is safe to call during Neotest's discovery walk.
---@param file_path string
---@param root string
---@return boolean
function M.is_nixpkgs_test_file(file_path, root)
  return M.attr_for_by_name(file_path, root) ~= nil
end

---@param a string
---@param b string
---@return boolean
local function is_lineage(a, b)
  return a == b or a:sub(1, #b + 1) == b .. "/" or b:sub(1, #a + 1) == a .. "/"
end

-- Subtrees the discovery walk descends into on a Nixpkgs root. Everything else
-- (the ~80k package dirs under pkgs/development, applications, ...) is pruned so
-- the recursive scan stays usable. Later phases add lib/tests and nixos/tests.
local allowed_prefixes = {
  "pkgs/by-name",
}

---Whether the discovery walk should descend into a directory (given relative to
---the Nixpkgs root). A directory is kept when it lies on the path to an allowed
---subtree, in either direction (an ancestor of it, or inside it).
---@param rel_path string
---@return boolean
function M.should_descend(rel_path)
  local rel = vim.fs.normalize(rel_path)
  rel = rel:gsub("^%./", ""):gsub("^/", ""):gsub("/$", "")
  if rel == "" or rel == "." then
    return true
  end

  for _, prefix in ipairs(allowed_prefixes) do
    if is_lineage(rel, prefix) then
      return true
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

---Collect the names of a package's tests by static parse. Any binding whose
---full attribute path runs through `tests` or `passthru.tests` contributes the
---segment immediately after `tests`, covering the attrset (`passthru.tests = {
---a = ...; }` and `passthru = { tests = { a = ...; }; }`) and dotted
---(`passthru.tests.a = ...;`) spellings alike. Computed or `inherit`-ed members
---are invisible to a static parse; eval-based enumeration is a later phase.
---@param root_node TSNode
---@param source string
---@return string[] names, table<string, integer[]> ranges
local function collect_tests(root_node, source)
  local positions = require("neotest-nix.positions")
  local order = {}
  local ranges = {}

  ---@param binding TSNode
  local function consider(binding)
    local parts = positions.full_attrpath_parts(binding, source)
    for index, segment in ipairs(parts) do
      if segment == "tests" then
        local prefix_ok = index == 1 or (index == 2 and parts[1] == "passthru")
        local name = parts[index + 1]
        if prefix_ok and name ~= nil and ranges[name] == nil then
          ranges[name] = { binding:range() }
          order[#order + 1] = name
        end
        break
      end
    end
  end

  ---@param node TSNode
  local function walk(node)
    for child in node:iter_children() do
      if child:type() == "binding" then
        consider(child)
      end
      walk(child)
    end
  end

  walk(root_node)
  return order, ranges
end

---Build a position tree for a `pkgs/by-name` package file. The file node and a
---`tests` namespace both target `<pkg>.tests` (build the whole suite); each
---member targets `<pkg>.tests.<name>`. Returns nil when the file is not a
---by-name package or cannot be parsed.
---@param file_path string
---@param root string
---@param opts neotest-nix.Config?
---@return neotest.Tree?
function M.discover_positions(file_path, root, opts)
  local attr = M.attr_for_by_name(file_path, root)
  if attr == nil then
    return nil
  end

  require("neotest-nix.parser").ensure_nix_parser(opts and opts.parser_runtime_paths)

  local source = read_file(file_path)
  if source == nil then
    return nil
  end

  local ok, root_node = pcall(function()
    local parser = vim.treesitter.get_string_parser(source, "nix")
    return parser:parse()[1]:root()
  end)
  if not ok or root_node == nil then
    vim.notify(
      ("neotest-nix: failed to parse %s: %s"):format(file_path, root_node),
      vim.log.levels.WARN
    )
    return nil
  end

  local log = require("neotest-nix.log")
  local start = log.enabled() and uv.hrtime() or nil
  local order, ranges = collect_tests(root_node, source)
  if start ~= nil then
    log.debug(
      ("discover_positions %s -> %d tests %.2fms"):format(
        file_path,
        #order,
        (uv.hrtime() - start) / 1e6
      )
    )
  end

  local tests_attr = attr .. ".tests"
  local list = {
    {
      id = file_path,
      name = vim.fs.basename(file_path),
      path = file_path,
      type = "file",
      range = { 0, 0, 0, 0 },
      runner = "nix",
      nixpkgs_attr = tests_attr,
    },
  }

  if #order > 0 then
    local namespace = {
      {
        id = file_path .. "::tests",
        name = "tests",
        path = file_path,
        type = "namespace",
        range = { 0, 0, 0, 0 },
        runner = "nix",
        nixpkgs_attr = tests_attr,
      },
    }
    for _, name in ipairs(order) do
      table.insert(namespace, {
        {
          id = file_path .. "::tests::" .. name,
          name = name,
          path = file_path,
          type = "test",
          range = ranges[name],
          runner = "nix",
          nixpkgs_attr = tests_attr .. "." .. name,
        },
      })
    end
    table.insert(list, namespace)
  end

  local Tree = require("neotest.types").Tree
  return Tree.from_list(list, function(data)
    return data.id
  end)
end

---Legacy `nix-build` command for a Nixpkgs position. `--no-out-link` avoids
---littering `result` symlinks (which the directory filter also ignores).
---@param position neotest-nix.Position
---@return string[]
function M.build_command(position)
  return { "nix-build", "-A", position.nixpkgs_attr, "--no-out-link" }
end

return M
