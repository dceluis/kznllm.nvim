local M = {}

local kznllm = require 'kznllm'
local Job = require 'plenary.job'
local Path = require 'plenary.path'
local api = vim.api
local group = vim.api.nvim_create_augroup('LLM_AutoGroup', { clear = true })

local TEMPLATE_DIRECTORY = kznllm.get_plugin_root() / 'templates'

function M.get_current_file(kzn_state, opts)
  local visual_selection, srow, scol, erow, ecol = kznllm.get_visual_selection(opts)
  kzn_state.visual_selection = visual_selection
  kzn_state.srow = srow
  kzn_state.scol = scol
  kzn_state.erow = erow
  kzn_state.ecol = ecol

  -- similar to rendering a template, but we want to get the context of the file without relying on the changes being saved
  local buf_filetype, buf_path, buf_context = kznllm.get_buffer_context(kzn_state.origin_buf_id, opts)

  local numbered_lines
  local buf_lines = vim.split(buf_context, "\n")

  numbered_lines = {}
  for i, line in ipairs(buf_lines) do
    table.insert(numbered_lines, string.format("%02d│%s", i, line))
  end

  buf_context = table.concat(numbered_lines, "\n")

  local selection_lines = {unpack(numbered_lines, srow + 1, erow + 1)}

  visual_selection = table.concat(selection_lines, "\n")

  return buf_filetype, buf_path, buf_context, visual_selection
end

---@param template_name string
---@param opts table
---@return Path
function M.get_template_path(template_name, opts)
  local template_directory = Path:new(opts.template_directory or TEMPLATE_DIRECTORY)
  local template_scope = Path:new(opts.template_scope or 'base')

  return (template_directory / template_scope / template_name)
end

local function debug(kzn_state, curl_data, opts)
  local buf_id = kzn_state.stream_buf_id
  local ns_id = api.nvim_create_namespace 'kznllm_ns'
  local extmark_id = kzn_state.stream_extmark_id

  kznllm.write_content_at_extmark('model: ' .. opts.model, buf_id, ns_id, extmark_id)

  for _, message in ipairs(curl_data.messages) do
    kznllm.write_content_at_extmark('\n\n============ ' .. message.role .. ' message: ============ \n\n', buf_id, ns_id, extmark_id)
    kznllm.write_content_at_extmark(message.content, buf_id, ns_id, extmark_id)
  end

  if not (kzn_state.visual_selection and opts.prefill) then
    kznllm.write_content_at_extmark('\n\n============\n\n', buf_id, ns_id, extmark_id)
  end
  vim.cmd 'normal! G'
  vim.cmd 'normal! zz'
end

function M.before_request(kzn_state, curl_data, opts)
  local stream_buf_id, stream_win_id = kznllm.make_floating_buffer()
  local ns_id = api.nvim_create_namespace 'kznllm_ns'
  local stream_extmark_id = api.nvim_buf_set_extmark(stream_buf_id, ns_id, 0, 0, {})

  kzn_state.stream_buf_id = stream_buf_id
  kzn_state.stream_win_id = stream_win_id
  kzn_state.ns_id = ns_id
  kzn_state.stream_extmark_id = stream_extmark_id

  if opts and opts.debug then
    local debug_fn = opts.debug_fn or debug
    debug_fn(kzn_state, curl_data, opts)
  end

  -- Make a no-op change to the buffer at the specified extmark to avoid calling undojoin after undo
  kznllm.noop(kzn_state.stream_buf_id, kzn_state.ns_id, kzn_state.stream_extmark_id)

  api.nvim_buf_set_keymap(kzn_state.stream_buf_id, 'n', '<Esc>', '', {
    noremap = false,
    silent = true,
    callback = function()
      api.nvim_exec_autocmds('User', { pattern = 'LLM_Escape' })
      api.nvim_buf_del_keymap(kzn_state.stream_buf_id, 'n', '<Esc>')
    end,
  })

  api.nvim_buf_set_keymap(kzn_state.stream_buf_id, 'n', 'u', '', {
    noremap = false,
    silent = true,
    callback = function()
      api.nvim_exec_autocmds('User', { pattern = 'LLM_Escape' })
      api.nvim_buf_del_keymap(kzn_state.stream_buf_id, 'n', 'u')
    end,
  })
end

function M.after_request(kzn_state, curl_args, opts)
  -- Check if the buffer is still valid before attempting to delete the extmark
  if vim.api.nvim_buf_is_valid(kzn_state.stream_buf_id) then
    vim.api.nvim_buf_del_extmark(kzn_state.stream_buf_id, kzn_state.ns_id, kzn_state.stream_extmark_id)
  end
end

---@param kzn_state table
---@param curl_args table
---@param on_start_fn fun()
---@param on_response_fn fun(line: string)
---@param on_content_fn fun(content: string)
---@param on_exit_fn fun(exit_code: integer, message: string)
---@param opts table
function M.make_job(kzn_state, curl_args, on_start_fn, on_response_fn, on_content_fn, on_exit_fn, opts)
  local active_job = Job:new {
    command = 'curl',
    args = curl_args,
    enable_recording = true,
    on_start = function()
      on_start_fn()
    end,
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

  api.nvim_clear_autocmds { group = group }

  vim.api.nvim_create_autocmd('User', {
    group = group,
    pattern = 'LLM_Escape',
    callback = function()
      if active_job.is_shutdown ~= true then
        active_job:shutdown()
        print 'LLM streaming cancelled'
      end
    end,
  })

  return active_job
end

return M
