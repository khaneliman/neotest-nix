local M = {}

local uv = vim.uv

local excluded_dirs = {
  [".git"] = true,
  [".direnv"] = true,
  ["node_modules"] = true,
  ["result"] = true,
}

local output_dir_patterns = {
  "^result%-",
}

---@param path string
---@return boolean
local function path_exists(path)
  return uv.fs_stat(path) ~= nil
end

---@param path string
---@return boolean
local function is_file(path)
  local stat = uv.fs_stat(path)
  return stat ~= nil and stat.type == "file"
end

---@param path string
---@return string
local function dirname(path)
  return vim.fs.dirname(vim.fs.normalize(path))
end

---@param path string
---@return boolean
local function is_absolute_path(path)
  return path:match("^/") ~= nil or path:match("^[A-Za-z]:[/\\]") ~= nil
end

---@param content string
---@return string
local function strip_nix_comments_and_strings(content)
  local out = {}
  local i = 1
  local len = #content

  local function append_space(count)
    for _ = 1, count do
      out[#out + 1] = " "
    end
  end

  while i <= len do
    local char = content:sub(i, i)
    local next_two = content:sub(i, i + 1)

    if char == "#" then
      append_space(1)
      i = i + 1
      while i <= len and content:sub(i, i) ~= "\n" do
        append_space(1)
        i = i + 1
      end
      if i <= len then
        append_space(1)
        i = i + 1
      end
    elseif next_two == "/*" then
      append_space(2)
      i = i + 2
      while i <= len and content:sub(i, i + 1) ~= "*/" do
        append_space(1)
        i = i + 1
      end
      if i <= len then
        append_space(2)
        i = i + 2
      end
    elseif char == '"' then
      append_space(1)
      i = i + 1
      while i <= len do
        local quoted = content:sub(i, i)
        if quoted == "\\" then
          if i < len then
            append_space(2)
            i = i + 2
          else
            append_space(1)
            i = i + 1
          end
        elseif quoted == '"' then
          append_space(1)
          i = i + 1
          break
        else
          append_space(1)
          i = i + 1
        end
      end
    elseif next_two == "''" then
      append_space(2)
      i = i + 2
      while i <= len do
        if content:sub(i, i + 1) == "''" then
          local escaped = content:sub(i + 2, i + 2)
          if escaped == "'" or escaped == "$" then
            append_space(3)
            i = i + 3
          else
            append_space(2)
            i = i + 2
            break
          end
        else
          append_space(1)
          i = i + 1
        end
      end
    else
      out[#out + 1] = char
      i = i + 1
    end
  end

  return table.concat(out)
end

---@param dir string
---@return string?
function M.root(dir)
  local normalized = vim.fs.normalize(dir)
  local start
  if path_exists(normalized) then
    start = normalized
  else
    if not is_absolute_path(normalized) then
      local parent = dirname(normalized)
      if parent == nil or parent == "" or not path_exists(parent) then
        return nil
      end
      start = parent
    else
      start = dirname(normalized)
    end

    while start ~= nil and start ~= "" and not path_exists(start) do
      local parent = dirname(start)
      if parent == nil or parent == start then
        start = nil
        break
      end
      start = parent
    end

    if start == nil or start == "" then
      return nil
    end
  end

  if is_file(start) then
    start = dirname(start)
  end

  local marker = vim.fs.find("flake.nix", {
    path = start,
    upward = true,
    type = "file",
  })[1]

  if marker == nil then
    return nil
  end

  return vim.fs.dirname(marker)
end

---@param file_path string
---@return boolean
local function has_nix_unit_assertion(file_path)
  local stat = uv.fs_stat(file_path)
  if stat == nil or stat.type ~= "file" then
    return false
  end

  local file = io.open(file_path, "r")
  if file == nil then
    return false
  end
  local content = file:read("*a")
  file:close()
  if content == nil then
    return false
  end

  local search = strip_nix_comments_and_strings(content)
  return search:match("%f[%w]expr%f[%W]") ~= nil
    and (
      search:match("%f[%w]expected%f[%W]") ~= nil
      or search:match("%f[%w]expectedError%f[%W]") ~= nil
    )
end

---Whether package source declares `passthru.tests`. This runs for every one of
---Nixpkgs' ~21k by-name packages, so it must stay on raw `string.find` (C-level)
---rather than the O(n) Lua comment/string stripper. A false positive (the word
---`tests` inside a comment or string) only yields a node that parses to zero
---tests, which is harmless; the authoritative parse happens in
---nixpkgs.discover_positions.
---@param content string
---@return boolean
local function source_has_passthru_tests(content)
  if content:find("tests", 1, true) == nil then
    return false
  end
  if content:find("passthru%s*%.%s*tests") ~= nil then
    return true
  end
  -- A `passthru = { ... }` block that binds `tests`.
  return content:find("passthru", 1, true) ~= nil and content:find("tests%s*=") ~= nil
end

-- Gate results cached per file and invalidated by mtime. Neotest re-runs
-- discovery on many events; without this every pass re-reads all ~21k packages.
---@type table<string, { mtime: integer, result: boolean }>
local passthru_cache = {}

---Cheap gate for a Nixpkgs `package.nix`: does it declare `passthru.tests`? The
---tree-sitter parse in nixpkgs.discover_positions is authoritative for the
---actual entries; this exists only to avoid turning every one of Nixpkgs' ~21k
---testless packages into a parsed Neotest node (the difference between a usable
---summary and a multi-second freeze on expand).
---@param file_path string
---@return boolean
local function has_passthru_tests(file_path)
  local stat = uv.fs_stat(file_path)
  if stat == nil or stat.type ~= "file" then
    return false
  end

  local mtime = stat.mtime ~= nil and stat.mtime.sec or 0
  local cached = passthru_cache[file_path]
  if cached ~= nil and cached.mtime == mtime then
    return cached.result
  end

  local file = io.open(file_path, "r")
  if file == nil then
    return false
  end
  local content = file:read("*a")
  file:close()
  if content == nil then
    return false
  end

  local result = source_has_passthru_tests(content)
  passthru_cache[file_path] = { mtime = mtime, result = result }
  return result
end

---@param file_path string
---@param opts neotest-nix.Config?
---@return boolean
function M.is_test_file(file_path, opts)
  local filename = vim.fs.basename(file_path)
  if filename == "flake.nix" then
    return true
  end

  if filename:match("%.nix$") == nil then
    return false
  end

  -- Nixpkgs-style test files (e.g. a `pkgs/by-name` package's tests). Gated on
  -- the basename so the marker walk only runs for plausible candidates.
  if filename == "package.nix" then
    local nixpkgs = require("neotest-nix.nixpkgs")
    local nixpkgs_root = nixpkgs.resolve_root(file_path, opts)
    if
      nixpkgs_root ~= nil
      and nixpkgs.is_nixpkgs_test_file(file_path, nixpkgs_root)
      and has_passthru_tests(file_path)
    then
      return true
    end
  end

  -- A file qualifies as test-named when either the file itself or its
  -- immediate parent directory is test-named (e.g. `tests/default.nix`).
  local parent = vim.fs.basename(dirname(file_path))
  if
    filename:lower():match("test") == nil and (parent == nil or parent:lower():match("test") == nil)
  then
    return false
  end

  return has_nix_unit_assertion(file_path)
end

---@param name string
---@param rel_path string
---@param root string
---@param opts neotest-nix.Config?
---@return boolean
function M.filter_dir(name, rel_path, root, opts)
  if name == nil or name == "" then
    return false
  end

  local absolute = vim.fs.normalize(vim.fs.joinpath(root, rel_path))
  if absolute:match("^/nix/store/") then
    return false
  end

  if excluded_dirs[name] then
    return false
  end

  for _, pattern in ipairs(output_dir_patterns) do
    if name:match(pattern) then
      return false
    end
  end

  -- On a Nixpkgs root, prune everything outside the supported subtrees; the
  -- full tree is far too large to walk exhaustively.
  local nixpkgs = require("neotest-nix.nixpkgs")
  if nixpkgs.is_root(root, opts) and not nixpkgs.should_descend(rel_path) then
    return false
  end

  return true
end

return M
