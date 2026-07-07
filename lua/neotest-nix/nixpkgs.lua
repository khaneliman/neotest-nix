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

-- Roots already resolved this session. Every file in a checkout shares one
-- root, so a prefix check here collapses tens of thousands of upward walks
-- (each of which normalizes and dirname-walks the whole path) into one.
---@type string[]
local known_roots = {}

---@type table<string, string|boolean>
local directory_root_cache = {}

---Walk upward from a file (or directory) to the nearest Nixpkgs root.
---@param file_path string
---@return string?
function M.detect_root(file_path)
  -- Fast path: paths from Neotest are already clean absolute paths, so try a
  -- raw prefix match against known roots before paying for vim.fs.normalize
  -- (which splits and rejoins the whole path) on every file.
  for _, root in ipairs(known_roots) do
    local len = #root
    local byte = string.byte(file_path, len + 1)
    if file_path == root or ((byte == 47 or byte == 92) and file_path:find(root, 1, true) == 1) then
      return root
    end
  end

  local normalized = vim.fs.normalize(file_path)

  for _, root in ipairs(known_roots) do
    local len = #root
    local byte = string.byte(normalized, len + 1)
    if
      normalized == root or ((byte == 47 or byte == 92) and normalized:find(root, 1, true) == 1)
    then
      return root
    end
  end

  local stat = uv.fs_stat(normalized)
  local dir = (stat ~= nil and stat.type == "directory") and normalized
    or vim.fs.dirname(normalized)

  if dir == nil or dir == "" then
    return nil
  end

  local cached = directory_root_cache[dir]
  if cached ~= nil then
    if cached == false then
      return nil
    end
    ---@cast cached string
    return cached
  end

  local current = dir
  local resolved_root = nil
  while current ~= nil and current ~= "" do
    if has_markers(current) then
      resolved_root = current
      known_roots[#known_roots + 1] = current
      break
    end
    local parent = vim.fs.dirname(current)
    if parent == current then
      break
    end
    current = parent
  end

  directory_root_cache[dir] = resolved_root or false
  return resolved_root
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

---@type table<string, table<string, boolean>>
local is_root_cache = {}

---Whether an adapter root is a Nixpkgs root in nixpkgs mode. Used by the
---directory filter, which receives the root but not a file path.
---@param root string
---@param opts neotest-nix.Config?
---@return boolean
function M.is_root(root, opts)
  local mode = opts and opts.nixpkgs_mode
  local root_cache = is_root_cache[root]
  if root_cache == nil then
    root_cache = {}
    is_root_cache[root] = root_cache
  end

  local mode_key
  if mode == nil then
    mode_key = "auto"
  elseif mode then
    mode_key = "true"
  else
    mode_key = "false"
  end
  local cached = root_cache[mode_key]
  if cached ~= nil then
    return cached
  end

  local result
  if mode == false then
    result = false
  elseif mode == true then
    result = true
  else
    result = has_markers(root)
  end

  root_cache[mode_key] = result
  return result
end

---@param file_path string
---@param root string
---@return string?
local function relpath(file_path, root)
  if file_path == root then
    return ""
  end
  local len_root = #root
  local byte = string.byte(file_path, len_root + 1)
  if (byte == 47 or byte == 92) and file_path:find(root, 1, true) == 1 then
    return file_path:sub(len_root + 2)
  end

  local normalized = vim.fs.normalize(file_path)
  local normalized_root = vim.fs.normalize(root)
  if normalized == normalized_root then
    return ""
  end
  local len_norm_root = #normalized_root
  local norm_byte = string.byte(normalized, len_norm_root + 1)
  if (norm_byte == 47 or norm_byte == 92) and normalized:find(normalized_root, 1, true) == 1 then
    return normalized:sub(len_norm_root + 2)
  end
  return nil
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

-- nixos/tests/*.nix entries that are infrastructure, not runnable VM tests.
local nixos_non_tests = {
  ["default"] = true,
  ["all-tests"] = true,
  ["make-test-python"] = true,
  ["make-test"] = true,
  ["common"] = true,
}

-- Top-level runnable lib tests. Helper inputs under lib/tests (for example
-- maintainer-module.nix and test-with-nix.nix) are intentionally skipped because
-- they require arguments or are exercised by release.nix/nix-unit.nix.
local lib_eval_tests = {
  ["fetchers.nix"] = true,
  ["misc.nix"] = true,
  ["systems.nix"] = true,
}

local lib_build_tests = {
  ["maintainers.nix"] = true,
  ["nix-unit.nix"] = true,
  ["release.nix"] = true,
  ["teams.nix"] = true,
}

---@param rel string
---@return "build"|"eval"|nil
local function lib_test_runner(rel)
  local name = rel:match("^lib/tests/([^/]+%.nix)$")
  if name == nil then
    return nil
  end
  if lib_eval_tests[name] then
    return "eval"
  end
  if lib_build_tests[name] then
    return "build"
  end
  return nil
end

---Classify a file under a Nixpkgs root by how it is run, or nil when it is not a
---recognized test file. Pure path matching, cheap enough for the discovery walk.
---@param file_path string
---@param root string
---@return "by-name"|"lib"|"nixos"|nil
function M.test_file_kind(file_path, root)
  local filename = file_path:match("[^/\\]+$") or file_path

  if filename == "package.nix" then
    local rel = relpath(file_path, root)
    if rel ~= nil and rel:match("^pkgs/by%-name/[^/]+/[^/]+/package%.nix$") ~= nil then
      return "by-name"
    end
    return nil
  end

  local rel = relpath(file_path, root)
  if rel == nil then
    return nil
  end

  if lib_test_runner(rel) ~= nil then
    return "lib"
  end

  local nixos = rel:match("^nixos/tests/([^/]+)%.nix$")
  if nixos ~= nil and not nixos_non_tests[nixos] then
    return "nixos"
  end

  return nil
end

---Whether a file under a Nixpkgs root is a recognized test file. Kept cheap (no
---evaluation) so it is safe to call during Neotest's discovery walk.
---@param file_path string
---@param root string
---@return boolean
function M.is_nixpkgs_test_file(file_path, root)
  return M.test_file_kind(file_path, root) ~= nil
end

---@param a string
---@param b string
---@return boolean
local function is_lineage(a, b)
  local len_a = #a
  local len_b = #b
  if len_a == len_b then
    return a == b
  elseif len_a > len_b then
    return a:find(b, 1, true) == 1 and string.byte(a, len_b + 1) == 47
  else
    return b:find(a, 1, true) == 1 and string.byte(b, len_a + 1) == 47
  end
end

-- Subtrees the discovery walk descends into on a Nixpkgs root. Everything else
-- (the ~80k package dirs under pkgs/development, applications, ...) is pruned so
-- the recursive scan stays usable. Later phases add lib/tests and nixos/tests.
local allowed_prefixes = {
  "pkgs/by-name",
  "lib/tests",
  "nixos/tests",
}

---Whether the discovery walk should descend into a directory (given relative to
---the Nixpkgs root). A directory is kept when it lies on the path to an allowed
---subtree, in either direction (an ancestor of it, or inside it).
---@param rel_path string
---@return boolean
function M.should_descend(rel_path)
  local rel = rel_path
  if rel:find("\\", 1, true) then
    rel = rel:gsub("\\", "/")
  end
  local len = #rel
  if len >= 2 and string.byte(rel, 1) == 46 and string.byte(rel, 2) == 47 then
    rel = rel:sub(3)
    len = #rel
  end
  if len >= 1 then
    local last_byte = string.byte(rel, len)
    if last_byte == 47 or last_byte == 92 then
      rel = rel:sub(1, len - 1)
    end
  end
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

---@param binding TSNode
---@return TSNode?
local function binding_expression(binding)
  local expressions = binding:field("expression")
  return expressions and expressions[1] or nil
end

---Decode an attrpath element: an identifier verbatim, or a quoted key
---(`"1.0"`) without interpolation. Returns nil for anything dynamic.
---@param node TSNode
---@param source string
---@return string?
local function attr_element_name(node, source)
  local kind = node:type()
  if kind == "identifier" then
    return vim.treesitter.get_node_text(node, source)
  end
  if kind == "string_expression" then
    local text = vim.treesitter.get_node_text(node, source)
    if text:find("${", 1, true) == nil then
      local ok, decoded = pcall(vim.json.decode, text)
      if ok and type(decoded) == "string" then
        return decoded
      end
    end
  end
  return nil
end

---Quote an attribute-path segment for splicing into a legacy `-A` argument.
---Bare Nix identifiers pass through; anything else (dots, leading digits, ...)
---is double-quoted with Nix string escaping so `1.0` becomes `"1.0"` instead
---of parsing as two nested attrs.
---@param segment string
---@return string
local function quote_attr_segment(segment)
  if segment:match("^[a-zA-Z_][a-zA-Z0-9_'%-]*$") ~= nil then
    return segment
  end
  local escaped = segment:gsub('[\\"]', "\\%0"):gsub("%${", "\\${")
  return '"' .. escaped .. '"'
end

---Join attribute-path segments into a `-A`-safe dotted path.
---@param segments string[]
---@return string
local function join_attr_path(segments)
  local quoted = {}
  for index, segment in ipairs(segments) do
    quoted[index] = quote_attr_segment(segment)
  end
  return table.concat(quoted, ".")
end

---@param node TSNode
---@return boolean
local function is_attrset_node(node)
  local node_type = node:type()
  return node_type == "attrset_expression" or node_type == "rec_attrset_expression"
end

---Collect the names of a package's tests by static parse. Any binding whose
---full attribute path runs through `tests` or `passthru.tests` contributes the
---segment immediately after `tests`, covering the attrset (`passthru.tests = {
---a = ...; }` and `passthru = { tests = { a = ...; }; }`), dotted
---(`passthru.tests.a = ...;`), direct inherit (`inherit (nixosTests) a;`), and
---selected attr (`tests = nixosTests.a;`) spellings alike. More dynamic members
---are invisible to a static parse; eval-based enumeration is a later phase.
---@param root_node TSNode
---@param source string
---@return string[] names, table<string, integer[]> ranges, integer[]? tests_range
local function collect_tests(root_node, source)
  local positions = require("neotest-nix.positions")
  local order = {}
  local ranges = {}
  -- Range of the `tests` container binding itself (e.g. `passthru.tests = ...`),
  -- used to anchor eval-discovered names when the value is computed and has no
  -- per-member source location.
  local tests_range

  ---@param name string?
  ---@param node TSNode?
  local function add(name, node)
    if name ~= nil and name ~= "tests" and ranges[name] == nil then
      ranges[name] = node ~= nil and { node:range() } or { 0, 0, 0, 0 }
      order[#order + 1] = name
    end
  end

  ---Name of the attr a select expression picks: the last attrpath element,
  ---identifier or quoted (`drv.tests."foo-bar"`). Reads only the attrpath
  ---field so an `or` default (`nixosTests.foo or fallback`) is ignored.
  ---@param node TSNode
  ---@return string?, TSNode?
  local function select_leaf(node)
    if node:type() ~= "select_expression" then
      return nil, nil
    end

    local attrpath = node:field("attrpath")
    attrpath = attrpath and attrpath[1] or nil
    if attrpath == nil then
      return nil, nil
    end

    local attrs = attrpath:field("attr")
    local last = attrs and attrs[#attrs] or nil
    if last == nil then
      return nil, nil
    end

    local name = attr_element_name(last, source)
    if name == nil then
      return nil, nil
    end
    return name, last
  end

  ---@param attrset TSNode
  local function add_direct_inherits(attrset)
    if not is_attrset_node(attrset) then
      return
    end

    for child in attrset:iter_children() do
      if child:type() == "binding_set" then
        for member in child:iter_children() do
          local kind = member:type()
          if kind == "inherit" or kind == "inherit_from" then
            for inherit_child in member:iter_children() do
              if inherit_child:type() == "inherited_attrs" then
                for identifier in inherit_child:iter_children() do
                  if identifier:type() == "identifier" then
                    add(vim.treesitter.get_node_text(identifier, source), identifier)
                  end
                end
              end
            end
          end
        end
      end
    end
  end

  ---@param binding TSNode
  ---@return boolean
  local function has_tests_attrpath(binding)
    local attrpath = binding:field("attrpath")
    attrpath = attrpath and attrpath[1] or nil
    if attrpath == nil then
      return false
    end

    for child in attrpath:iter_children() do
      if
        child:type() == "identifier" and vim.treesitter.get_node_text(child, source) == "tests"
      then
        return true
      end
    end
    return false
  end

  ---@param binding TSNode
  ---@return boolean
  local function crosses_function_before_tests(binding)
    ---@type TSNode?
    local current = binding
    while current ~= nil do
      if current:type() == "binding" and has_tests_attrpath(current) then
        return false
      end
      if current ~= binding and current:type() == "function_expression" then
        return true
      end
      current = current:parent()
    end
    return false
  end

  ---@param binding TSNode
  local function consider(binding)
    if crosses_function_before_tests(binding) then
      return
    end

    local parts = positions.full_attrpath_parts(binding, source)
    for index, segment in ipairs(parts) do
      if segment == "tests" then
        local prefix_ok = index == 1 or (index == 2 and parts[1] == "passthru")
        if prefix_ok then
          local name = parts[index + 1]
          if name ~= nil then
            add(name, binding)
          else
            if tests_range == nil then
              tests_range = { binding:range() }
            end

            local expression = binding_expression(binding)
            if expression ~= nil then
              add_direct_inherits(expression)
              local leaf, node = select_leaf(expression)
              add(leaf, node)
            end
          end
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
  return order, ranges, tests_range
end

---@param binding TSNode
---@param source string
---@return string?, TSNode?
local function binding_name(binding, source)
  local attrpath = binding:field("attrpath")
  attrpath = attrpath and attrpath[1] or nil
  if attrpath == nil then
    return nil, nil
  end

  for child in attrpath:iter_children() do
    local name = attr_element_name(child, source)
    if name ~= nil then
      return name, child
    end
  end

  return nil, nil
end

---@param node TSNode
---@return TSNode[]
local function node_children(node)
  local children = {}
  for child in node:iter_children() do
    children[#children + 1] = child
  end
  return children
end

---@param node TSNode
---@param source string
---@return TSNode?
local function run_tests_argument(node, source)
  if node:type() ~= "apply_expression" then
    return nil
  end

  local children = node_children(node)
  local callee = children[1]
  local argument = children[2]
  if callee == nil or argument == nil then
    return nil
  end

  local text = vim.treesitter.get_node_text(callee, source)
  if text == "runTests" or text:match("%.runTests$") ~= nil then
    return argument
  end

  return nil
end

---@param attrset TSNode
---@param source string
---@param add fun(name: string, node: TSNode)
local function collect_run_tests_attrset(attrset, source, add)
  if not is_attrset_node(attrset) then
    return
  end

  for child in attrset:iter_children() do
    if child:type() == "binding_set" then
      for binding in child:iter_children() do
        if binding:type() == "binding" then
          local name, node = binding_name(binding, source)
          if name ~= nil and name:sub(1, 4) == "test" then
            add(name, node or binding)
          end
        end
      end
    end
  end
end

---Collect statically named members passed to `lib.runTests`. This intentionally
---looks only inside the runTests argument so helper functions such as
---`genTests = n: ...` do not appear as runnable cases.
---@param root_node TSNode
---@param source string
---@return string[] names, table<string, integer[]> ranges
local function collect_run_tests(root_node, source)
  local order = {}
  local ranges = {}

  ---@param name string
  ---@param node TSNode
  local function add(name, node)
    if ranges[name] == nil then
      ranges[name] = { node:range() }
      order[#order + 1] = name
    end
  end

  ---@param node TSNode
  local function collect_arg(node)
    local kind = node:type()
    if kind == "function_expression" then
      return
    end
    if is_attrset_node(node) then
      collect_run_tests_attrset(node, source, add)
      return
    end

    for child in node:iter_children() do
      collect_arg(child)
    end
  end

  ---@param node TSNode
  local function walk(node)
    local argument = run_tests_argument(node, source)
    if argument ~= nil then
      collect_arg(argument)
      return
    end

    for child in node:iter_children() do
      walk(child)
    end
  end

  walk(root_node)
  return order, ranges
end

-- Eval-discovered test names cached per file and invalidated by mtime, so
-- re-discovery (e.g. on save) does not re-run nix-instantiate unless the file
-- changed. Failures are also cached so false positives do not trigger retries
-- on every discovery event.
---@type table<string, { mtime: integer, names: string[]|false }>
local eval_names_cache = {}

---@param file_path string
---@param root string
---@param attr string
---@return string[]?
local function eval_test_names(file_path, root, attr)
  local stat = uv.fs_stat(file_path)
  local mtime = (stat ~= nil and stat.mtime ~= nil) and stat.mtime.sec or 0

  local cached = eval_names_cache[file_path]
  if cached ~= nil and cached.mtime == mtime then
    return cached.names or nil
  end

  local log = require("neotest-nix.log")
  local start = log.enabled() and uv.hrtime() or nil
  local names = require("neotest-nix.eval").nixpkgs_test_names(root, attr)
  if start ~= nil then
    log.debug(
      ("eval tests %s -> %s %.2fms"):format(
        file_path,
        names ~= nil and #names or "nil",
        (uv.hrtime() - start) / 1e6
      )
    )
  end

  eval_names_cache[file_path] = { mtime = mtime, names = names or false }
  return names
end

---Parse a Nix file into its tree-sitter root node and source text.
---@param file_path string
---@param opts neotest-nix.Config?
---@return TSNode? root_node, string? source
local function parse_file(file_path, opts)
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

  return root_node, source
end

---@param data table
---@return neotest.Tree
local function tree_from(data)
  local Tree = require("neotest.types").Tree
  return Tree.from_list(data, function(node)
    return node.id
  end)
end

---Build a position tree for a `pkgs/by-name` package file. The file node and a
---`tests` namespace both target `<pkg>.tests` (build the whole suite); each
---member targets `<pkg>.tests.<name>`. Returns nil when the file is not a
---by-name package or cannot be parsed.
---@param file_path string
---@param root string
---@param opts neotest-nix.Config?
---@return neotest.Tree?
local function by_name_positions(file_path, root, opts)
  local attr = M.attr_for_by_name(file_path, root)
  if attr == nil then
    return nil
  end

  local root_node, source = parse_file(file_path, opts)
  if root_node == nil or source == nil then
    return nil
  end

  local log = require("neotest-nix.log")
  local start = log.enabled() and uv.hrtime() or nil
  local order, ranges, tests_range = collect_tests(root_node, source)
  if start ~= nil then
    log.debug(
      ("discover_positions %s -> %d tests %.2fms"):format(
        file_path,
        #order,
        (uv.hrtime() - start) / 1e6
      )
    )
  end

  -- Static parse found nothing, but the file declares passthru.tests (it passed
  -- is_test_file): the entries are computed (e.g. `callPackages ./tests`). Fall
  -- back to a legacy eval to enumerate them, when the user opts in.
  if #order == 0 and opts ~= nil and opts.discover_nixpkgs_eval_tests then
    local names = eval_test_names(file_path, root, attr)
    if names ~= nil then
      for _, name in ipairs(names) do
        ranges[name] = tests_range or { 0, 0, 0, 0 }
        order[#order + 1] = name
      end
    end
  end

  local tests_attr = join_attr_path({ attr, "tests" })
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
          nixpkgs_attr = tests_attr .. "." .. quote_attr_segment(name),
        },
      })
    end
    table.insert(list, namespace)
  end

  return tree_from(list)
end

---Build a single file position for a runnable `lib/tests` entry. Build-style
---files are derivations; eval-style files return a lib.runTests failure list.
---@param file_path string
---@param root string
---@param opts neotest-nix.Config?
---@return neotest.Tree?
local function lib_positions(file_path, root, opts)
  local rel = relpath(file_path, root)
  if rel == nil then
    return nil
  end

  local runner = lib_test_runner(rel)
  local data = {
    id = file_path,
    name = vim.fs.basename(file_path),
    path = file_path,
    type = "file",
    range = { 0, 0, 0, 0 },
  }
  if runner == "eval" then
    data.runner = "nix-eval"
    data.nixpkgs_file_eval = rel
  else
    data.runner = "nix"
    data.nixpkgs_file_build = rel
  end

  local list = { data }
  if runner == "eval" then
    local root_node, source = parse_file(file_path, opts)
    local order, ranges = {}, {}
    if root_node ~= nil and source ~= nil then
      order, ranges = collect_run_tests(root_node, source)
    end

    if #order > 0 then
      local namespace = {
        {
          id = file_path .. "::tests",
          name = "tests",
          path = file_path,
          type = "namespace",
          range = { 0, 0, 0, 0 },
          runner = "nix-eval",
          nixpkgs_file_eval = rel,
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
            runner = "nix-eval",
            nixpkgs_file_eval = rel,
            nixpkgs_eval_test = name,
          },
        })
      end
      table.insert(list, namespace)
    end
  end

  return tree_from(list)
end

---Build a file position for a `nixos/tests/<name>.nix` VM test, targeting
---`nixosTests.<name>`. A statically findable `testScript` range is recorded so
---Python-traceback failures map back onto the script (see vm.lua / results.lua).
---@param file_path string
---@param root string
---@param opts neotest-nix.Config?
---@return neotest.Tree?
local function nixos_positions(file_path, root, opts)
  local name = (relpath(file_path, root) or ""):match("^nixos/tests/([^/]+)%.nix$")
  if name == nil then
    return nil
  end

  local test_script_range
  local root_node, source = parse_file(file_path, opts)
  if root_node ~= nil and source ~= nil then
    test_script_range = require("neotest-nix.positions").test_script_range(root_node, source)
  end

  return tree_from({
    {
      id = file_path,
      name = vim.fs.basename(file_path),
      path = file_path,
      type = "file",
      range = { 0, 0, 0, 0 },
      runner = "nix",
      nixpkgs_attr = join_attr_path({ "nixosTests", name }),
      test_script_range = test_script_range,
    },
  })
end

---Build a position tree for a recognized Nixpkgs test file.
---@param file_path string
---@param root string
---@param opts neotest-nix.Config?
---@return neotest.Tree?
function M.discover_positions(file_path, root, opts)
  local kind = M.test_file_kind(file_path, root)
  if kind == "by-name" then
    return by_name_positions(file_path, root, opts)
  elseif kind == "lib" then
    return lib_positions(file_path, root, opts)
  elseif kind == "nixos" then
    return nixos_positions(file_path, root, opts)
  end
  return nil
end

---Legacy command and result runner for a Nixpkgs position. `--no-out-link`
---avoids littering `result` symlinks (which the directory filter also ignores).
---All commands are legacy (no flakes, evaluate the working tree in place).
---@param position neotest-nix.Position
---@return string[] command, string runner
function M.build_command(position)
  if position.nixpkgs_file_build ~= nil then
    return { "nix-build", position.nixpkgs_file_build, "--no-out-link" }, "nix"
  end
  if position.nixpkgs_file_eval ~= nil then
    if position.nixpkgs_eval_test ~= nil then
      local name =
        require("neotest-nix.eval").nix_string_literal(vim.json.encode(position.nixpkgs_eval_test))
      local expr = ([[
let
  failures = import ./%s;
  name = builtins.fromJSON %s;
in
builtins.filter (failure: (failure.name or null) == name) failures
]]):format(position.nixpkgs_file_eval, name)
      return { "nix-instantiate", "--eval", "--strict", "--json", "--expr", expr }, "nix-eval"
    end
    return { "nix-instantiate", "--eval", "--strict", "--json", position.nixpkgs_file_eval },
      "nix-eval"
  end
  -- `nixpkgs_attr` segments are quoted at construction (join_attr_path), so the
  -- dotted string is already a valid attrpath for `-A`.
  return { "nix-build", "-A", position.nixpkgs_attr, "--no-out-link" }, "nix"
end

function M.clear_cache()
  marker_cache = {}
  known_roots = {}
  directory_root_cache = {}
  is_root_cache = {}
  eval_names_cache = {}
end

return M
