local M = {}

local max_captures = 32

---@param pattern string
---@param start_index integer
---@return integer?, string?
local function scan_character_class(pattern, start_index)
  local pattern_length = #pattern
  local current_index = start_index + 1

  if pattern:sub(current_index, current_index) == "^" then
    current_index = current_index + 1
  end
  if pattern:sub(current_index, current_index) == "]" then
    current_index = current_index + 1
  end

  while current_index <= pattern_length do
    local character = pattern:sub(current_index, current_index)
    if character == "]" then
      return current_index + 1
    end
    if character == "%" then
      if current_index == pattern_length then
        return nil,
          ("escape in character class at byte %d cannot terminate pattern"):format(current_index)
      end
      current_index = current_index + 2
    else
      current_index = current_index + 1
    end
  end

  return nil, ("unclosed character class at byte %d"):format(start_index)
end

---@param pattern string
---@return boolean, string?
local function scan_pattern(pattern)
  local pattern_length = #pattern
  local current_index = 1
  local capture_count = 0
  ---@type { index: integer, position: integer }[]
  local capture_stack = {}
  ---@type table<integer, boolean>
  local closed_captures = {}

  while current_index <= pattern_length do
    local character = pattern:sub(current_index, current_index)
    if character == "[" then
      local next_index, err = scan_character_class(pattern, current_index)
      if next_index == nil then
        return false, err
      end
      current_index = next_index
    elseif character == "%" then
      if current_index == pattern_length then
        return false, ("escape at byte %d cannot terminate pattern"):format(current_index)
      end

      local escaped = pattern:sub(current_index + 1, current_index + 1)
      if escaped == "b" then
        if current_index + 3 > pattern_length then
          return false, ("%%b at byte %d requires two delimiters"):format(current_index)
        end
        current_index = current_index + 4
      elseif escaped == "f" then
        local class_index = current_index + 2
        if pattern:sub(class_index, class_index) ~= "[" then
          return false,
            ("%%f at byte %d must be followed by a character class"):format(current_index)
        end
        local next_index, err = scan_character_class(pattern, class_index)
        if next_index == nil then
          return false, err
        end
        current_index = next_index
      elseif escaped:match("%d") then
        local capture_index = tonumber(escaped)
        if capture_index == nil or closed_captures[capture_index] ~= true then
          return false,
            ("capture reference %%%s at byte %d has no closed capture"):format(
              escaped,
              current_index
            )
        end
        current_index = current_index + 2
      else
        current_index = current_index + 2
      end
    elseif character == "(" then
      capture_count = capture_count + 1
      if capture_count > max_captures then
        return false,
          ("too many captures at byte %d (maximum %d)"):format(current_index, max_captures)
      end

      if pattern:sub(current_index + 1, current_index + 1) == ")" then
        closed_captures[capture_count] = true
        current_index = current_index + 2
      else
        table.insert(capture_stack, { index = capture_count, position = current_index })
        current_index = current_index + 1
      end
    elseif character == ")" then
      local capture = table.remove(capture_stack)
      if capture == nil then
        return false, ("unmatched ')' at byte %d"):format(current_index)
      end
      closed_captures[capture.index] = true
      current_index = current_index + 1
    else
      current_index = current_index + 1
    end
  end

  local capture = capture_stack[#capture_stack]
  if capture ~= nil then
    return false, ("unclosed capture at byte %d"):format(capture.position)
  end

  return true
end

---@param pattern string
---@return boolean, string?
function M.validate_pattern(pattern)
  if type(pattern) ~= "string" then
    return false, ("pattern must be a string, got %s"):format(type(pattern))
  end

  return scan_pattern(pattern)
end

return M
