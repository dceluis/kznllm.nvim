local M = {}

local API_KEY_NAME = 'OPENAI_API_KEY'
local BASE_URL = 'https://api.openai.com'

local API_ERROR_MESSAGE = [[
ERROR: api key is set to %s and is missing from your environment variables.

Load somewhere safely from config `export %s=<api_key>`]]

local kznllm = require 'kznllm'
local shared = require 'kznllm.specs.shared'
local Path = require 'plenary.path'
local Job = require 'plenary.job'
local api = vim.api

local plugin_dir = Path:new(debug.getinfo(1, 'S').source:sub(2)):parents()[4]
local TEMPLATE_DIRECTORY = Path:new(plugin_dir) / 'templates'

--- Constructs arguments for constructing an HTTP request to the OpenAI API
--- using cURL.
---
---@param kzn_state table
---@param curl_data table
---@param opts table
---@return string[]
function M.make_curl_args(kzn_state, curl_data, opts)
  local url = (opts and opts.base_url or BASE_URL) .. (opts and opts.endpoint)
  local api_key_name = opts and opts.api_key_name or API_KEY_NAME
  local api_key = os.getenv(api_key_name)

  if not api_key then
    error(API_ERROR_MESSAGE:format(api_key_name, api_key_name), 1)
  end

  local args = {
    '-s', --silent
    '--fail-with-body',
    '-N', --no buffer
    '-X',
    'POST',
    '-H',
    'Content-Type: application/json',
    '-d',
    vim.json.encode(curl_data),
    '-H',
    'Authorization: Bearer ' .. api_key,
    url,
  }

  return args
end

---@param kzn_state table
---@param opts table
function M.get_current_file(kzn_state, opts)
  return shared.get_current_file(kzn_state, opts)
end

---@param kzn_state table
---@param opts table
---@return table
function M.make_curl_data(kzn_state, opts)
  local template_directory = opts.template_directory or TEMPLATE_DIRECTORY
  local messages = {
    {
      role = 'system',
      content = kznllm.make_prompt_from_template(template_directory / 'nous_research/fill_mode_system_prompt.xml.jinja', kzn_state),
    },
    {
      role = 'user',
      content = kznllm.make_prompt_from_template(template_directory / 'nous_research/fill_mode_user_prompt.xml.jinja', kzn_state),
    },
  }

  local data = {
    messages = messages,
    model = opts.model,
    stream = true,
  }

  if kzn_state.replace and opts.prefill and opts.stop_param then
    table.insert(messages, {
      role = 'assistant',
      content = opts.prefill .. kzn_state.current_buffer_filetype .. '\n',
    })
    data = vim.tbl_extend('keep', data, opts.stop_param)
  end

  data = vim.tbl_extend('keep', data, opts.data_params)

  return data
end

local function debug_fn(kzn_state, curl_data, buf_id, ns_id, extmark_id, opts)
  if opts and opts.debug then
    vim.print("[kznllm] debugging")
  else
    return
  end

  buf_id = kznllm.make_scratch_buffer()
  extmark_id = api.nvim_buf_set_extmark(buf_id, ns_id, 0, 0, {})

  kznllm.write_content_at_extmark('model: ' .. opts.model, buf_id, ns_id, extmark_id)
  for _, message in ipairs(curl_data.messages) do
    kznllm.write_content_at_extmark('\n\n============ ' .. message.role .. ' message: ============ \n\n', buf_id, ns_id, extmark_id)
    kznllm.write_content_at_extmark(message.content, buf_id, ns_id, extmark_id)
  end
  if not (kzn_state.replace and opts.prefill) then
    kznllm.write_content_at_extmark('\n\n============\n\n', buf_id, ns_id, extmark_id)
  end
  vim.cmd 'normal! G'
  vim.cmd 'normal! zz'

  return {stream_buf_id = buf_id, stream_extmark_id = extmark_id}
end

function M.before_request(...)
  return debug_fn(...)
end

--- Process server-sent events based on OpenAI spec
--- [See Documentation](https://platform.openai.com/docs/api-reference/chat/create#chat-create-stream)
---
---@param line string
---@return string
local function on_response(line)
  -- based on sse spec (OpenAI spec uses data-only server-sent events)
  local data = line:match '^data: (.+)$'

  local content = ''

  if data and data:match '"delta":' then
    local json = vim.json.decode(data)
    if json.choices and json.choices[1] and json.choices[1].delta and json.choices[1].delta.content then
      content = json.choices[1].delta.content
    else
      vim.print(data)
    end
  end

  return content
end

---@param kzn_state table
---@param content string
---@param buf_id integer
---@param ns_id integer
---@param extmark_id integer
---@param opts table
function M.on_content(kzn_state, content, buf_id, ns_id, extmark_id, opts)
  kznllm.write_content_at_extmark(content, buf_id, ns_id, extmark_id)
end

---@param kzn_state table
---@param curl_args table
---@param on_content_fn fun(content: string)
function M.make_job(kzn_state, curl_args, on_content_fn)
  local active_job = Job:new {
    command = 'curl',
    args = curl_args,
    enable_recording = true,
    on_stdout = function(_, line)
      local content = on_response(line)
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
        end
      end)
    end,
  }
  return active_job
end

return M
