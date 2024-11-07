local kzn = require 'kznllm'

local ContentMap = require('kznllm.lndiff.content_map')
local EditBlock = require('kznllm.lndiff.edit_block')

local Path = require 'plenary.path'

local Coder = {}
Coder.__index = Coder

-- Constants matching the Python implementation
local HEAD    = "^<<<<<<?<?<?<? REMOVE%s*$"
local DIVIDER = "^======?=?=?=?%s*$"
local UPDATED = "^>>>>>>?>?>?>? INSERT%s*$"

local HEAD_ERR = "<<<<<<< REMOVE"
local DIVIDER_ERR = "======="
local UPDATED_ERR = ">>>>>>> INSERT"

local default_fence = {"<editblock>", "</editblock>"}

local function prep(content)
  if content and not content:match("\n$") then
    content = content .. "\n"
  end
  local lines = kzn.splitlines(content, true)
  return content, lines
end

--- Find original and update blocks in a given content
---@param content string The text content to parse
---@param fence? table Optional fence markers
---@return function Iterator function that yields filename, original text, and updated text
function Coder.find_edits(content, fence)
  content = content or ''
  fence = fence or default_fence

  local i = 1
  local current_filename = nil

  local lines = kzn.splitlines(content, true)

  return function()
    while i <= #lines do
      local line = lines[i]

      -- Check for REMOVE/INSERT blocks
      if line:match(HEAD) then
        local filename = nil

        -- Try to find filename in previous lines
        for j = i - 1, math.max(1, i - 3), -1 do
          filename = Coder.strip_filename(lines[j], fence)
          if filename then break end
        end

        -- Fallback to current filename or error
        if not filename then
          if current_filename then
            filename = current_filename
          else
            error("Bad/missing filename")
          end
        end

        current_filename = filename

        -- Collect original text
        local removed_lines = {}
        i = i + 1
        while not lines[i]:match(DIVIDER) do
          table.insert(removed_lines, lines[i])
          i = i + 1

          if i > #lines then
            error("Expected `" .. DIVIDER_ERR .. "`")
          end
        end

        -- Collect updated text
        local inserted_lines = {}
        i = i + 1
        while not (lines[i]:match(UPDATED) or lines[i]:find(fence[2])) do
          table.insert(inserted_lines, lines[i])
          i = i + 1

          if i > #lines then
            error("Expected `" .. UPDATED_ERR .. "`")
          end
        end

        local removed_text = table.concat(removed_lines)
        local inserted_text = table.concat(inserted_lines)

        return filename, removed_text, inserted_text
      end

      i = i + 1
    end
  end
end

--- Apply edit blocks to files
---@param content_map table The content_map to apply edits to
---@param edits table A list of edit blocks to apply
---@return table Content map after applying edits
---@return table List of successfully applied edit blocks
---@return table List of failed edit blocks
---@return string Error message (if any)
function Coder.apply_edits(content_map, edits)
  content_map = content_map or ContentMap.new()
  edits = edits or {}

  local failed = {}
  local passed = {}

  for _, edit in ipairs(edits) do
    local full_path, removed, replaced = unpack(edit)

    -- Create maps for removed and replaced content
    local removed_map = ContentMap.new(removed, "force")
    local replaced_map = ContentMap.new(replaced)

    -- Create EditBlock
    local editblock = EditBlock.new(full_path, content_map, removed_map, replaced_map)

    -- Check if block already applied
    if content_map:editblock_applied(editblock) then
      table.insert(passed, editblock)
    else
      -- Attempt to apply the edit block
      local success, new_content_map, new_editblock = Coder.do_replace(content_map, editblock)

      if success then
        content_map = new_content_map
        table.insert(passed, editblock)
      else
        editblock = new_editblock
        table.insert(failed, editblock)
      end
    end
  end

  local error_msg = ''
  -- Prepare error report if there are failed edits
  if #failed > 0 then
    error_msg = string.format("# %d *edit blocks* failed to match!\n", #failed)

    for _, editblock in ipairs(failed) do
      error_msg = error_msg .. string.format("## EditblockNoExactMatch: This *editblock* failed to exactly match lines in %s\n", editblock._path)
      error_msg = error_msg .. editblock:as_content({numbered = true, mismatch = true})
    end

    if #passed > 0 then
      error_msg = error_msg .. string.format("\n# The other %d *editblocks* were applied successfully.", #passed)
    end

    error_msg = error_msg .. "Reply with new *editblocks* based off the latest code version.\n"
  end

  return content_map, passed, failed, error_msg
end

--- Attempt to replace content in a file with numbered line matching
---@param content_map table Content map of the original file
---@param editblock table Edit block to apply
---@return boolean, table, table Success status, new content map, potentially modified editblock
function Coder.do_replace(content_map, editblock)
  local offsets = {0, -1, 1}

  -- Create a copy of the content map to work with
  local whole_map_copy = content_map:copy()

  local remove_map = editblock:remove_map()
  local insert_map = editblock:insert_map()

  local remove_len = #remove_map:keys()
  local content_len = #whole_map_copy:keys()

  -- If remove map is empty or content is empty, append to the end
  if remove_len == 0 or content_len == 0 then
    whole_map_copy:editblock_apply(editblock)
    return true, whole_map_copy, editblock
  end

  -- Get line number range
  local min_line = math.min(unpack(whole_map_copy:keys()))
  local max_line = math.max(unpack(whole_map_copy:keys()))

  for _, offset in ipairs(offsets) do
    local mismatch = nil

    -- Check each line in the remove map
    for num, line in remove_map:iter() do
      local num_o = num + offset

      -- Check if line number is out of range
      if num_o > max_line or num_o < min_line then
        mismatch = num
        break
      end

      -- Check if line exists and matches
      local original_line = whole_map_copy:get(num_o)
      if not original_line or original_line ~= line then
        mismatch = num
        break
      end
    end

    -- If no mismatch found, apply the edit block
    if not mismatch then
      local offset_remove_map = ContentMap.new()
      for num, line in remove_map:iter() do
        offset_remove_map:set(num + offset, line)
      end

      local offset_editblock = EditBlock.new(editblock._path,
        whole_map_copy, offset_remove_map, insert_map
      )
      offset_editblock:mismatch(editblock:mismatch())
      whole_map_copy:editblock_apply(offset_editblock)

      return true, whole_map_copy, offset_editblock
    else
      -- If offset is 0, set the mismatch
      if offset == 0 then
        editblock:mismatch(mismatch)
      end
    end
  end

  -- If no successful offset found, return false
  return false, whole_map_copy, editblock
end

--- Strip filename from a line
---@param filename string The line to strip
---@param fence table Optional fence markers
---@return string|nil Stripped filename or nil
function Coder.strip_filename(filename, fence)
  fence = fence or default_fence
  filename = filename:gsub("^%s*", ""):gsub("%s*$", "")

  if filename == "..." then
    return nil
  end

  if filename:find("^" .. fence[1]) then
    return nil
  end

  filename = filename:gsub(":$", "")
  filename = filename:gsub("^#", "")
  filename = filename:gsub("^%s*", ""):gsub("%s*$", "")
  filename = filename:gsub("^`", ""):gsub("`$", "")
  filename = filename:gsub("^%*", ""):gsub("%*$", "")

  return filename ~= "" and filename or nil
end

return Coder
