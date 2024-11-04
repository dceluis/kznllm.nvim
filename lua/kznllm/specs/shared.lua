local M = {}

local kznllm = require 'kznllm'
local Job = require 'plenary.job'

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

---@param kzn_state table
---@param curl_args table
---@param on_response_fn fun(line: string)
---@param on_content_fn fun(content: string)
---@param on_exit_fn fun(exit_code: integer, message: string)
---@param opts table
function M.make_job(kzn_state, curl_args, on_response_fn, on_content_fn, on_exit_fn, opts)
  local active_job = Job:new {
    command = 'curl',
    args = curl_args,
    enable_recording = true,
    on_stdout = function(_, line)
      local content = on_response_fn(line)
      if content and content ~= nil then
        vim.schedule(function()
          on_content_fn(content)
        end)
      end
    end,
    on_stderr = function(message, _)
      error(message, 1)
    end,
    on_exit = function(job, exit_code)
      local stdout_result = job:result()
      local stdout_message = table.concat(stdout_result, '\n')

      vim.schedule(function()
        if exit_code and exit_code ~= 0 then
          vim.notify('[Curl] (exit code: ' .. exit_code .. ')\n' .. stdout_message, vim.log.levels.ERROR)
        else
          on_exit_fn(exit_code, stdout_message)
        end
      end)
    end,
  }
  return active_job
end

return M
