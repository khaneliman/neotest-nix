-- Increasing-size probe for generic streaming diagnostics. Each run feeds
-- fixed-size chunks, verifies the final diagnostic, and reports elapsed time.
local results = require("neotest-nix.results")
local uv = vim.uv

local Tree = {}
Tree.__index = Tree

function Tree:new(data, children)
  return setmetatable({ _data = data, _children = children or {} }, self)
end

function Tree:data()
  return self._data
end

function Tree:get_key(key)
  if self._data.id == key then
    return self
  end
  for _, child in ipairs(self._children) do
    if child:data().id == key then
      return child
    end
  end
end

function Tree:iter()
  local nodes = { self }
  for _, child in ipairs(self._children) do
    nodes[#nodes + 1] = child
  end
  local index = 0
  return function()
    index = index + 1
    local node = nodes[index]
    return node and index, node and node:data()
  end
end

local root = vim.fn.tempname()
vim.fn.mkdir(vim.fs.joinpath(root, "checks"), "p")
local source = vim.fs.joinpath(root, "checks", "unit.nix")
vim.fn.writefile({ "first", "second" }, source)
local tree = Tree:new({ id = root, path = root, type = "file" }, {
  Tree:new({ id = "unit", name = "unit", path = source, range = { 0, 0, 1, 0 }, type = "test" }),
})

local sizes = { 1024, 64 * 1024, 1024 * 1024 }
for _, size in ipairs(sizes) do
  local prefix = string.rep("trace: evaluation progress\n", math.ceil(size / 27)):sub(1, size)
  local output = prefix .. "\nerror: assertion failed\n       at " .. source .. ":2:3:\n"
  local offset = 1
  local chunks = 0
  local stream = results.stream({ command = { "true" }, cwd = root, context = {} }, tree)(function()
    if offset > #output then
      return nil
    end
    local chunk = output:sub(offset, offset + 4095)
    offset = offset + #chunk
    chunks = chunks + 1
    return chunk
  end)

  local started = uv.hrtime()
  local parsed
  while true do
    local update = stream()
    if update == nil then
      break
    end
    parsed = update.unit or parsed
  end
  local elapsed_ms = (uv.hrtime() - started) / 1e6
  assert(parsed and parsed.errors)
  assert(parsed.errors[1].message == "assertion failed")
  io.write(
    ("mode=generic bytes=%d chunks=%d elapsed_ms=%.3f\n"):format(#output, chunks, elapsed_ms)
  )
end

local dense_sizes = { 500, 1000, 2000 }
for _, count in ipairs(dense_sizes) do
  local index = 0
  local stream = results.stream({ command = { "true" }, cwd = root, context = {} }, tree)(function()
    index = index + 1
    if index > count then
      return nil
    end
    return {
      ("error: failure %d"):format(index),
      ("       at %s:2:3:"):format(source),
    }
  end)

  local started = uv.hrtime()
  local updates = 0
  local parsed
  while true do
    local update = stream()
    if update == nil then
      break
    end
    parsed = update.unit
    updates = updates + 1
  end
  local elapsed_ms = (uv.hrtime() - started) / 1e6
  assert(parsed and parsed.errors)
  assert(parsed.errors[1].message == ("failure %d"):format(count))
  assert(updates == count)
  io.write(
    ("mode=generic-dense diagnostics=%d updates=%d elapsed_ms=%.3f\n"):format(
      count,
      updates,
      elapsed_ms
    )
  )
end

for _, size in ipairs(sizes) do
  local marker = "\226\156\133 systems.x86_64-linux.unit\n"
  local output = string.rep(marker, math.ceil(size / #marker)):sub(1, size - 1) .. "\n"
  local offset = 1
  local chunks = 0
  local stream = results.stream(
    { command = { "true" }, cwd = root, context = { runner = "nix-unit" } },
    tree
  )(function()
    if offset > #output then
      return nil
    end
    local chunk = output:sub(offset, offset + 4095)
    offset = offset + #chunk
    chunks = chunks + 1
    return chunk
  end)

  local started = uv.hrtime()
  local parsed
  while true do
    local update = stream()
    if update == nil then
      break
    end
    parsed = update.unit or parsed
  end
  local elapsed_ms = (uv.hrtime() - started) / 1e6
  assert(parsed and parsed.status == "passed")
  io.write(
    ("mode=nix-unit bytes=%d chunks=%d elapsed_ms=%.3f\n"):format(#output, chunks, elapsed_ms)
  )
end

for _, count in ipairs(dense_sizes) do
  local index = 0
  local stream = results.stream(
    { command = { "true" }, cwd = root, context = { runner = "nix-unit" } },
    tree
  )(function()
    index = index + 1
    if index == 1 then
      return "\226\157\140 unit\n"
    end
    if index <= count + 1 then
      return ("detail %d\n"):format(index - 1)
    end
    if index == count + 2 then
      return "\240\159\152\162 0/1 successful\n"
    end
    return nil
  end)

  local started = uv.hrtime()
  local updates = 0
  local parsed
  while true do
    local update = stream()
    if update == nil then
      break
    end
    parsed = update.unit
    updates = updates + 1
  end
  local elapsed_ms = (uv.hrtime() - started) / 1e6
  assert(parsed and parsed.status == "failed")
  assert(parsed.short:find(("detail %d"):format(count), 1, true))
  assert(updates == 2)
  io.write(
    ("mode=nix-unit-detail lines=%d updates=%d elapsed_ms=%.3f\n"):format(
      count,
      updates,
      elapsed_ms
    )
  )
end

vim.fn.delete(root, "rf")
