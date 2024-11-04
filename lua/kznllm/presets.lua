--
-- This module provides the basic feature set from kznllm v0.1 with the addition of exported presets.
-- Your lazy config still wants to define the keymaps to make it work (see the main project README.md for recommended setup)
--
local kznllm = require 'kznllm'
---@class Path
local Path = require 'plenary.path'
local api = vim.api

local M = {}
local presets = {}

local group = api.nvim_create_augroup('LLM_AutoGroup', { clear = true })

--- Working implementation of "inline" fill mode
--- Invokes an LLM via a supported API spec defined by
---
--- Must provide the function for constructing cURL arguments and a handler
--- function for processing server-sent events.
---
---@param get_current_file_fn fun(kzn_state: table, opts: table)
---@param make_curl_data_fn fun(kzn_state: table, opts: table)
---@param make_curl_args_fn fun(kzn_state: table, curl_data: table, opts: table)
---@param make_job_fn fun(kzn_state: table, args: table, on_response_fn: fun(line: string), on_content_fn: fun(content: string), on_exit_fn: fun(message: string), opts: table)
---@param on_response_fn fun(kzn_state: table, line: string, opts)
---@param on_content_fn fun(kzn_state: table, content: string, buf_id: integer, ns_id: integer, extmark_id: integer, opts)
---@param before_request_fn fun(kzn_state: table, curl_data: table, buf_id: integer, ns_id: integer, extmark_id: integer, opts: table)
---@param after_request_fn fun(kzn_state: table, curl_data: table, buf_id: integer, ns_id: integer, extmark_id: integer, opts: table)
---@param opts { stop_dir: Path?, context_dir_id: string?, data_params: table, prefill: boolean, prompt: string }
function M._invoke_llm(get_current_file_fn, make_curl_data_fn, make_curl_args_fn, make_job_fn, on_response_fn, on_content_fn, before_request_fn, after_request_fn, opts)
  local KZN_STATE = {
    current_buffer_path = nil,
    current_buffer_context = nil,
    current_buffer_filetype = nil,
    visual_selection = nil,
    user_query = nil,
    context_files = nil,
    prefill = nil,

    origin_buf_id = nil,
    stream_buf_id = nil,
    ns_id = nil,
    stream_extmark_id = nil,

    curl_args = nil,
    curl_data = nil,
  }

  api.nvim_clear_autocmds { group = group }

  local active_job

  kznllm.get_user_input(function(input)
    KZN_STATE.origin_buf_id = api.nvim_win_get_buf(0)
    KZN_STATE.user_query = input
    KZN_STATE.ns_id = api.nvim_create_namespace 'kznllm_ns'

    local context_dir = kznllm.find_context_directory(opts)
    KZN_STATE.context_files = {}

    if context_dir then
      KZN_STATE.context_files = kznllm.get_project_files(context_dir, opts)
    end

    local buf_filetype, buf_path, buf_context, visual_selection = get_current_file_fn(KZN_STATE, opts)

    KZN_STATE.visual_selection = visual_selection
    KZN_STATE.current_buffer_filetype = buf_filetype
    KZN_STATE.current_buffer_path = buf_path
    KZN_STATE.current_buffer_context = buf_context

    KZN_STATE.prefill = opts.prefill

    -- TODO: move this to an injectable function
    local _, srow, scol, _, _ = kznllm.get_visual_selection(opts)

    KZN_STATE.stream_buf_id = KZN_STATE.origin_buf_id
    KZN_STATE.stream_extmark_id = api.nvim_buf_set_extmark(KZN_STATE.stream_buf_id, KZN_STATE.ns_id, srow, scol, { strict = false })

    KZN_STATE.curl_data = make_curl_data_fn(KZN_STATE, opts) or {}
    KZN_STATE.curl_args = make_curl_args_fn(KZN_STATE, KZN_STATE.curl_data, opts) or {}

    -- open up scratch buffer before setting extmark
    if before_request_fn then
      local new_state = before_request_fn(
        KZN_STATE,
        KZN_STATE.curl_data,
        KZN_STATE.stream_buf_id,
        KZN_STATE.ns_id,
        KZN_STATE.stream_extmark_id,
        opts
      )
      if new_state then
        KZN_STATE = vim.tbl_extend('force', KZN_STATE, new_state)
      end
    end

    -- Make a no-op change to the buffer at the specified extmark to avoid calling undojoin after undo
    kznllm.noop(
      KZN_STATE.stream_buf_id,
      KZN_STATE.ns_id,
      KZN_STATE.stream_extmark_id
    )

    if make_job_fn then
      active_job = make_job_fn(
        KZN_STATE,
        KZN_STATE.curl_args,
        function (line)
          return on_response_fn(KZN_STATE, line, opts)
        end,
        function (content)
          return on_content_fn(KZN_STATE, content, KZN_STATE.stream_buf_id, KZN_STATE.ns_id, KZN_STATE.stream_extmark_id, opts)
        end,
        function (message)
          if after_request_fn then
            after_request_fn(
              KZN_STATE,
              KZN_STATE.curl_args,
              KZN_STATE.stream_buf_id,
              KZN_STATE.ns_id,
              KZN_STATE.stream_extmark_id,
              opts
            )
          end
        end,
        opts
      )

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

      api.nvim_buf_set_keymap(KZN_STATE.stream_buf_id, 'n', '<Esc>', '', {
        noremap = true,
        silent = true,
        callback = function()
          api.nvim_exec_autocmds('User', { pattern = 'LLM_Escape' })
          api.nvim_buf_del_keymap(KZN_STATE.stream_buf_id, 'n', '<Esc>')
        end,
      })

      active_job:start()
    end
  end, opts.prompt)
end

function M.invoke_llm(get_current_file_fn, make_curl_data_fn, make_curl_args_fn, make_job_fn, on_response_fn, on_content_fn, before_request_fn, after_request_fn, opts)
  if type(get_current_file_fn) == 'table' and get_current_file_fn.spec then
    local preset = get_current_file_fn
    opts = make_curl_data_fn

    local spec
    if type(preset.spec) == 'table' then
      spec = preset.spec
    elseif type(preset.spec) == 'string' then
      spec = require(('kznllm.specs.%s'):format(preset.spec))
    else
      error('Invalid spec type. Expected table or string.')
    end

    local default_opts = {}
    if preset.id then
      default_opts.prompt = preset.id
    end

    local merged_opts = vim.tbl_extend('force', default_opts, preset.opts or {})
    merged_opts = vim.tbl_extend('force', merged_opts, opts or {})

    return M._invoke_llm(
      spec.get_current_file,
      spec.make_curl_data,
      spec.make_curl_args,
      spec.make_job,
      spec.on_response,
      spec.on_content,
      spec.before_request,
      spec.after_request,
      merged_opts
    )
  else
    return M._invoke_llm(get_current_file_fn, make_curl_data_fn, make_curl_args_fn, make_job_fn, on_response_fn, on_content_fn, before_request_fn, after_request_fn, opts)
  end
end

function M.switch_presets()
  local selected_preset = M.load()

  vim.ui.select(presets, {
    format_item = function(item)
      local options = {}
      for k, v in pairs(item.opts.data_params or {}) do
        if type(v) == 'number' then
          local k_parts = {}
          local k_split = vim.split(k, '_')
          for i, term in ipairs(k_split) do
            if i > 1 then
              table.insert(k_parts, term:sub(0, 3))
            else
              table.insert(k_parts, term:sub(0, 4))
            end
          end
          table.insert(options, ('%-5s %-5s'):format(table.concat(k_parts, '_'), v))
        end
      end
      table.sort(options)
      return ('%-20s %10s │ %s'):format(item.id .. (item == selected_preset and ' *' or '  '), item.provider, table.concat(options, ' '))
    end,
  }, function(choice, idx)
    if not choice then
      return
    end
    vim.g.PRESET_IDX = idx
    print(('%-15s provider: %-10s'):format(choice.id, choice.provider))
  end)
end

function M.load()
  local idx = vim.g.PRESET_IDX or 1
  return presets[idx]
end

-- for vllm, add openai w/ kwargs (i.e. url + api_key)
presets = {
  {
    id = 'deepseek-v2.5',
    provider = 'openrouter',
    spec = 'openai',
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
    opts = {
      model = 'claude-3-5-sonnet-20241022',
      data_params = {
        max_tokens = 8192,
        temperature = 0.7,
      },
      base_url = 'https://api.anthropic.com',
      endpoint = '/v1/messages',
    },
  },
  {
    id = 'claude-3-haiku',
    provider = 'anthropic',
    spec = 'anthropic',
    opts = {
      model = 'claude-3-haiku-20240307',
      data_params = {
        max_tokens = 4096,
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
    id = 'gpt-4o',
    provider = 'openrouter',
    spec = 'openai',
    opts = {
      model = 'openai/gpt-4o',
      data_params = {
        -- max_tokens = 8192,
        temperature = 1.2,
      },
      api_key_name = 'OPENROUTER_API_KEY',
      base_url = 'https://openrouter.ai',
      endpoint = '/api/v1/chat/completions',
    },
  },
  {
    id = 'o1-mini',
    provider = 'openrouter',
    spec = 'openai',
    opts = {
      model = 'openai/o1-mini',
      data_params = {
        -- max_tokens = 8192,
        temperature = 1.2,
      },
      api_key_name = 'OPENROUTER_API_KEY',
      base_url = 'https://openrouter.ai',
      endpoint = '/api/v1/chat/completions',
    },
  },
  {
    id = 'o1-preview',
    provider = 'openrouter',
    spec = 'openai',
    opts = {
      model = 'openai/o1-preview',
      data_params = {
        -- max_tokens = 8192,
        temperature = 1.2,
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
    opts = {
      model = 'claude-3-5-sonnet-20241022',
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
    id = 'chat-model',
    provider = 'vllm',
    spec = 'vllm',
    opts = {
      model = 'meta-llama/Llama-3.2-3B-Instruct',
      data_params = {
        max_tokens = 8192,
        min_p = 0.9,
        temperature = 2.1,
      },
      base_url = 'http://worker.local:8000',
      endpoint = '/v1/chat/completions',
    },
  },
}

return vim.tbl_extend('keep', M, presets)
