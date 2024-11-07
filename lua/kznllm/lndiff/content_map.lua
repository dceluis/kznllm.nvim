local kzn = require 'kznllm'

local ContentMap = {
    __pairs = function(self)
        return pairs(self._map)
    end
}

ContentMap.__index = ContentMap

local function prep(content)
  if content and not content:match("\n$") then
    content = content .. "\n"
  end
  local lines = kzn.splitlines(content, true)
  return content, lines
end

function ContentMap.new(content, numbered)
  numbered = numbered or false
  local obj = setmetatable({}, ContentMap)

  obj._map = {}
  obj._editblocks = {}

  if content then
    local content_lines
    content, content_lines = prep(content)

    local res = {}

    for ln, line in ipairs(content_lines) do
      local parsed_number, parsed_line = obj:parse_line(line)

      if numbered and parsed_number then
        res[parsed_number] = parsed_line
      else
        if numbered == 'force' then
          error("Could not parse numbered line `" .. line .. "`")
        end
        res[ln] = parsed_line
      end
    end

    obj._map = res
  end

  return obj
end

function ContentMap:len()
  return vim.tbl_count(self._map)
end

function ContentMap:digits()
  local keys = self:keys()
  local max = math.max(unpack(keys))
  max = math.max(max, self:len())

  return math.ceil(math.log10(max + 1))
end

function ContentMap:parse_line(line)
  local line_separator = '│'

  -- If no separator in line, return nil with whole line
  if not line:find(line_separator) then
    return nil, line
  end

  -- Split on first separator only
  local prefix, content = line:match('^(.-)' .. line_separator .. '(.*)$')

  -- Check if prefix is just whitespace and numbers
  local cleaned = prefix:gsub('%s', '')
  if not cleaned or not cleaned:match('^%d+$') then
    return nil, content
  end

  return tonumber(cleaned), content
end

function ContentMap:editblock_apply(editblock)
  table.insert(self._editblocks, editblock)
end

function ContentMap:editblock_applied(other_editblock)
  local removed_other = other_editblock:remove_map():as_content({numbered=true})
  local inserted_other = other_editblock:insert_map():as_content()

  for _, editblock in ipairs(self._editblocks) do
    local removed = editblock:remove_map():as_content({numbered=true})
    local inserted = editblock:insert_map():as_content()

    if removed == removed_other then
      if inserted == inserted_other then
        return true
      end
    end
  end
  return false
end

function ContentMap:as_numbered_line(line, number)
  return string.format("%0" .. self:digits() .. "d│%s", number, line)
end

function ContentMap:as_padded_line(line)
  return string.format("%s│%s", string.rep(" ", self:digits()), line)
end

function ContentMap:do_apply()
  local res = {}

  for _, editblock in ipairs(self._editblocks) do
    local insert_idx

    local remove_len = editblock:remove_map():len()
    if remove_len == 0 then
      -- Append at end
      insert_idx = math.max(unpack(self:keys())) + 1
      local offset = 0
      for _, line in editblock:insert_map():iter() do
        self:set(insert_idx + offset, line)
        offset = offset + 1
      end
    else
      -- Replace existing lines
      insert_idx = math.min(unpack(editblock:remove_map():keys()))

      -- Remove existing lines
      for num, _ in editblock:remove_map():iter() do
        self:set(num, {})
      end

      -- Insert new lines
      local new_lines = {}
      for _, line in editblock:insert_map():iter() do
        table.insert(new_lines, line)
      end

      self:set(insert_idx, new_lines)
    end
  end

  -- Reconstruct the map
  local i = 1
  for _, value in self:iter() do
    if type(value) == 'table' then
      for _, line in ipairs(value) do
        res[i] = line
        i = i + 1
      end
    else
      res[i] = value
      i = i + 1
    end
  end

  local new_content_map = ContentMap.new()
  new_content_map._map = res

  return new_content_map
end

function ContentMap:as_content(options)
  local apply = options and options.apply or false
  local numbered = options and options.numbered or false
  local padded = options and options.padded or false

  local content_map = apply and self:do_apply() or self
  local lines = {}

  if numbered then
    for i, line in content_map:iter() do
      table.insert(lines, content_map:as_numbered_line(line, i))
    end
  elseif padded then
    for _, line in content_map:iter() do
      table.insert(lines, content_map:as_padded_line(line))
    end
  else
    for _, line in content_map:iter() do
      table.insert(lines, line)
    end
  end

  return table.concat(lines)
end

function ContentMap:keys()
  return vim.tbl_keys(self._map)
end

function ContentMap:values()
  return vim.tbl_values(self._map)
end

function ContentMap:iter()
  local sorted_keys = vim.tbl_keys(self._map)
  table.sort(sorted_keys)

  local i = 0
  return function()
      i = i + 1
      if sorted_keys[i] then
          return sorted_keys[i], self:get(sorted_keys[i])
      end
  end
end

function ContentMap:get(key, default)
  return self._map[key] or default
end

function ContentMap:set(key, value)
  self._map[key] = value
end

function ContentMap:copy()
  local other = ContentMap.new()
  other._editblocks = self._editblocks
  other._map = vim.tbl_extend('force', other._map, self._map)
  return other
end

return ContentMap
