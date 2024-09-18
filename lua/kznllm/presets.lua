--
-- This module provides the basic feature set from kznllm v0.1 with the addition of exported presets.
-- Your lazy config still wants to define the keymaps to make it work (see the main project README.md for recommended setup)
--
local kznllm = require 'kznllm'
local Path = require 'plenary.path'
local api = vim.api

local M = {}

--TODO: PROMPT_ARGS_STATE is just a bad persistence layer at the moment, I don't really want to write files everywhere...

M.PROMPT_ARGS_STATE = {
  current_buffer_path = nil,
  current_buffer_context = nil,
  current_buffer_filetype = nil,
  visual_selection = nil,
  user_query = nil,
  replace = nil,
  context_files = nil,
  prefill = nil,
}

M.NS_ID = api.nvim_create_namespace 'kznllm_ns'

local group = api.nvim_create_augroup('LLM_AutoGroup', { clear = true })

--- Working implementation of "inline" fill mode
--- Invokes an LLM via a supported API spec defined by
---
--- Must provide the function for constructing cURL arguments and a handler
--- function for processing server-sent events.
---
---@param make_data_fn fun(prompt_args: table, opts: table)
---@param make_curl_args_fn fun(data: table, opts: table)
---@param make_job_fn fun(data: table, writer_fn: fun(content: string), on_exit_fn: fun())
---@param opts { debug: string?, debug_fn: fun(data: table, ns_id: integer, extmark_id: integer, opts: table)?, stop_dir: Path?, context_dir_id: string?, data_params: table, prefill: boolean }
function M._invoke_llm(make_data_fn, make_curl_args_fn, make_job_fn, debug_fn, opts)
  api.nvim_clear_autocmds { group = group }

  local active_job

  local buf = api.nvim_win_get_buf(0)

  kznllm.get_user_input(function(input)
    M.PROMPT_ARGS_STATE.user_query = input
    M.PROMPT_ARGS_STATE.replace = not (api.nvim_get_mode().mode == 'n')

    local visual_selection = kznllm.get_visual_selection(opts)
    M.PROMPT_ARGS_STATE.visual_selection = visual_selection

    local context_dir = kznllm.find_context_directory(opts)
    M.PROMPT_ARGS_STATE.context_files = {}

    if context_dir then
      M.PROMPT_ARGS_STATE.context_files = kznllm.get_project_files(context_dir, opts)
    end

    for mention in input:gmatch('@[%w./]+') do
      local mention_path = vim.fn.getcwd() .. '/' .. mention:sub(2)

      if vim.fn.filereadable(mention_path) == 1 then
        table.insert(M.PROMPT_ARGS_STATE.context_files, {
          path = mention_path,
          content = Path:new(mention_path):read()
        })
      end
    end

    -- don't update current context if scratch buffer is open
    if not vim.b.debug then
      -- similar to rendering a template, but we want to get the context of the file without relying on the changes being saved
      local buf_filetype, buf_path, buf_context = kznllm.get_buffer_context(buf, opts)
      M.PROMPT_ARGS_STATE.current_buffer_filetype = buf_filetype
      M.PROMPT_ARGS_STATE.current_buffer_path = buf_path
      M.PROMPT_ARGS_STATE.current_buffer_context = buf_context

      if not visual_selection then
        local srow, scol, erow, ecol = kznllm.get_visual_selection_pos()
        local cursor_pos = "<CURSOR_POS>"
        local buf_lines = vim.split(buf_context, "\n")
        local new_line = buf_lines[erow+1]:sub(1, ecol) .. "<CURSOR_POS>" .. buf_lines[erow+1]:sub(ecol + 1) 
        buf_lines[erow + 1] = new_line
        buf_context = table.concat(buf_lines, "\n")

        M.PROMPT_ARGS_STATE.current_buffer_context = buf_context
      end
    end
    M.PROMPT_ARGS_STATE.prefill = opts.prefill

    local data = make_data_fn(M.PROMPT_ARGS_STATE, opts)

    local stream_end_extmark_id

    -- open up scratch buffer before setting extmark
    if opts and opts.debug and debug_fn then
      local scratch_buf = kznllm.make_scratch_buffer()
      api.nvim_buf_set_var(scratch_buf, 'debug', true)

      stream_end_extmark_id = api.nvim_buf_set_extmark(scratch_buf, M.NS_ID, 0, 0, {})
      debug_fn(M.PROMPT_ARGS_STATE, data, M.NS_ID, stream_end_extmark_id, opts)
    else
      local _, crow, ccol = unpack(vim.fn.getpos '.')
      stream_end_extmark_id = api.nvim_buf_set_extmark(buf, M.NS_ID, crow - 1, ccol - 1, { strict = false })
    end

    local args = make_curl_args_fn(data, opts)

    -- Make a no-op change to the buffer at the specified extmark to avoid calling undojoin after undo
    kznllm.noop(M.NS_ID, stream_end_extmark_id)

    active_job = make_job_fn(args, function(content)
      kznllm.write_content_at_extmark(content, M.NS_ID, stream_end_extmark_id)
    end, function()
      api.nvim_buf_del_extmark(0, M.NS_ID, stream_end_extmark_id)
    end)

    active_job:start()

    api.nvim_create_autocmd('User', {
      group = group,
      pattern = 'LLM_Escape',
      callback = function()
        if active_job.is_shutdown ~= true then
          active_job:shutdown()
          print 'LLM streaming cancelled'
        end
      end,
    })
  end, opts.prompt)
end

function M.invoke_llm(param1, param2, param3, param4)
  if type(param1) == 'table' and param1.spec then
    local preset = param1
    local opts = param2

    local spec = require(('kznllm.specs.%s'):format(preset.spec))

    local default_opts = {}
    if preset.id then
      default_opts.prompt = preset.id
    end

    local merged_opts = vim.tbl_extend('force', default_opts, preset.opts or {})
    merged_opts = vim.tbl_extend('force', merged_opts, opts or {})

    return M._invoke_llm(
      spec.make_data_fn,
      spec.make_curl_args,
      spec.make_job,
      spec.debug_fn,
      merged_opts
    )
  else
    return M._invoke_llm(param1, param2, param3, param4)
  end
end

-- for vllm, add openai w/ kwargs (i.e. url + api_key)
-- { id = 'openai', opts = { api_key_name = 'VLLM_API_KEY', url = 'http://research.local:8000/v1/chat/completions' } }
local presets = {
  {
    id = 'deepseek-v2.5',
    provider = 'openrouter',
    spec = 'openai',
    make_data_fn = make_data_for_openai_chat,
    opts = {
      model = 'deepseek/deepseek-chat',
      data_params = {
        -- max_tokens = 8192,
        temperature = 0.7,
      },
      api_key_name = 'OPENROUTER_API_KEY',
      base_url = 'https://openrouter.ai',
      endpoint = '/api/v1/chat/completions',
    },
  },
  {
    id = 'claude-3.5-sonnet',
    provider = 'anthropic',
    spec = 'anthropic',
    make_data_fn = make_data_for_anthropic_chat,
    opts = {
      model = 'claude-3-5-sonnet-20240620',
      data_params = {
        max_tokens = 8192,
        temperature = 0.7,
      },
      base_url = 'https://api.anthropic.com',
      endpoint = '/v1/messages',
    },
  },
  {
    id = 'gpt-4o-mini',
    provider = 'openrouter',
    spec = 'openai',
    make_data_fn = make_data_for_openai_chat,
    opts = {
      model = 'openai/gpt-4o-mini',
      data_params = {
        -- max_tokens = 8192,
        temperature = 0.7,
      },
      api_key_name = 'OPENROUTER_API_KEY',
      base_url = 'https://openrouter.ai',
      endpoint = '/api/v1/chat/completions',
    },
  },
  {
    id = 'chat-model',
    provider = 'groq',
    spec = 'groq',
    make_data_fn = make_data_for_openai_chat,
    opts = {
      model = 'llama-3.1-70b-versatile',
      data_params = {
        -- max_tokens = 8192,
        temperature = 0.7,
      },
      -- doesn't support prefill
      -- stop_param = { stop = { '```' } },
      -- prefill = '```',
      base_url = 'https://api.groq.com',
      endpoint = '/openai/v1/chat/completions',
    },
  },
  {
    id = 'chat-model',
    provider = 'lambda',
    spec = 'lambda',
    make_data_fn = make_data_for_openai_chat,
    opts = {
      model = 'hermes-3-llama-3.1-405b-fp8',
      data_params = {
        -- max_tokens = 8192,
        -- temperature = 2.1,
        temperature = 1.5,
        min_p = 0.05,
        logprobs = 1,
      },
      -- stop_param = { stop_token_ids = { 74694 } },
      -- prefill = '```',
      base_url = 'https://api.lambdalabs.com',
      endpoint = '/v1/chat/completions',
    },
  },
  {
    id = 'chat-model',
    provider = 'anthropic',
    spec = 'anthropic',
    make_data_fn = make_data_for_anthropic_chat,
    opts = {
      model = 'claude-3-5-sonnet-20240620',
      data_params = {
        max_tokens = 8192,
        temperature = 0.7,
      },
      base_url = 'https://api.anthropic.com',
      endpoint = '/v1/messages',
    },
  },
  {
    id = 'chat-model',
    provider = 'openai',
    spec = 'openai',
    make_data_fn = make_data_for_openai_chat,
    opts = {
      model = 'gpt-4o-mini',
      data_params = {
        max_tokens = 16384,
        temperature = 0.7,
      },
      base_url = 'https://api.openai.com',
      endpoint = '/v1/chat/completions',
    },
  },
  {
    id = 'chat-model',
    provider = 'deepseek',
    spec = 'deepseek',
    make_data_fn = make_data_for_deepseek_chat,
    opts = {
      model = 'deepseek-chat',
      data_params = {
        max_tokens = 8192,
        temperature = 0,
      },
      stop_param = { stop = { '```' } },
      prefill = '```',
      base_url = 'https://api.deepseek.com',
      endpoint = '/beta/v1/chat/completions',
    },
  },
  {
    id = 'completion-model',
    provider = 'vllm',
    spec = 'vllm',
    make_data_fn = make_data_for_openai_chat,
    opts = {
      model = 'meta-llama/Meta-Llama-3.1-8B-Instruct',
      data_params = {
        max_tokens = 8192,
        min_p = 0.9,
        temperature = 2.1,
      },
      endpoint = '/v1/chat/completions',
    },
  },
}

function M.load_selected_preset()
  local selected_preset_idx = vim.g.KZNLLM_SELECTED_PRESET_IDX or 1
  return presets[selected_preset_idx]
end

function M.save_selected_preset(index)
  vim.g.KZNLLM_SELECTED_PRESET_IDX = index
end

return vim.tbl_extend('keep', M, presets)
