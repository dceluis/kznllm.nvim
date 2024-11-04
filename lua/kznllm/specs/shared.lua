local M = {}

local kznllm = require 'kznllm'

function M.get_current_file(kzn_state, opts)
  local visual_selection, srow, scol, erow, ecol = kznllm.get_visual_selection(opts)

  -- similar to rendering a template, but we want to get the context of the file without relying on the changes being saved
  local buf_filetype, buf_path, buf_context = kznllm.get_buffer_context(kzn_state.origin_buf_id, opts)

  local cursor_pos = "<CURSOR_POS>"
  local cursor_end = "<CURSOR_END>"
  local buf_lines = vim.split(buf_context, "\n")
  local new_line = buf_lines[srow+1]:sub(1, scol) .. cursor_pos .. buf_lines[srow+1]:sub(scol + 1)
  buf_lines[srow + 1] = new_line
  if visual_selection then
    local epos = ecol
    if srow == erow then
      epos = epos + #cursor_pos
    end

    new_line = buf_lines[erow+1]:sub(1, epos) .. cursor_end .. buf_lines[erow+1]:sub(epos + 1)
    buf_lines[erow + 1] = new_line
  end
  buf_context = table.concat(buf_lines, "\n")

  return buf_filetype, buf_path, buf_context, visual_selection
end

return M
