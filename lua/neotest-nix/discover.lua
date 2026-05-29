local M = {}

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
  return vim.loop.fs_stat(path) ~= nil
end

---@param path string
---@return boolean
local function is_file(path)
  local stat = vim.loop.fs_stat(path)
  return stat ~= nil and stat.type == "file"
end

---@param path string
---@return string
local function dirname(path)
  return vim.fs.dirname(vim.fs.normalize(path))
end

---@param dir string
---@return string?
function M.root(dir)
  local normalized = vim.fs.normalize(dir)
  local start = path_exists(normalized) and normalized or dirname(normalized)
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
  local stat = vim.loop.fs_stat(file_path)
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

  return content:match("%f[%w]expr%f[%W]") ~= nil
    and (
      content:match("%f[%w]expected%f[%W]") ~= nil or content:match("%f[%w]expectedError%f[%W]") ~= nil
    )
end

---@param file_path string
---@return boolean
function M.is_test_file(file_path)
  local filename = vim.fs.basename(file_path)
  if filename == "flake.nix" then
    return true
  end

  if filename:match("%.nix$") == nil or filename:lower():match("test") == nil then
    return false
  end

  return has_nix_unit_assertion(file_path)
end

---@param name string
---@param rel_path string
---@param root string
---@return boolean
function M.filter_dir(name, rel_path, root)
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

  return true
end

return M
