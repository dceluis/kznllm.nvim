local M = {}

local API_KEY_NAME = 'GROQ_API_KEY'
local BASE_URL = 'https://api.groq.com/openai'
local ENDPOINT = '/v1/chat/completions'

local API_ERROR_MESSAGE = [[
ERROR: api key is set to %s and is missing from your environment variables.

Load somewhere safely from config `export %s=<api_key>`]]

local kznllm = require 'kznllm'
local shared = require 'kznllm.specs.shared'

--- Constructs arguments for constructing an HTTP request to the OpenAI API
--- using cURL.
---
---@param kzn_state table
---@param curl_data table
---@param opts table
---@return string[]
function M.make_curl_args(kzn_state, curl_data, opts)
  local url = (opts and opts.base_url or BASE_URL) .. (opts and opts.endpoint or ENDPOINT)
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
  kzn_state.prefill = opts.prefill

  local system_template = shared.get_template_path('system_prompt.xml.jinja', opts)
  local user_template = shared.get_template_path('user_prompt.xml.jinja', opts)

  local messages = {
    {
      role = 'system',
      content = kznllm.make_prompt_from_template(system_template, kzn_state),
    },
    {
      role = 'user',
      content = kznllm.make_prompt_from_template(user_template, kzn_state),
    },
  }

  local data = {
    messages = messages,
    model = opts.model,
    stream = true,
  }

  if kzn_state.visual_selection and opts.prefill and opts.stop_param then
    table.insert(messages, {
      role = 'assistant',
      content = opts.prefill .. kzn_state.current_buffer_filetype .. '\n',
    })
    data = vim.tbl_extend('keep', data, opts.stop_param)
  end

  data = vim.tbl_extend('keep', data, opts.data_params)

  return data
end

--- Process server-sent events based on OpenAI spec
--- [See Documentation](https://platform.openai.com/docs/api-reference/chat/create#chat-create-stream)
---
---@param kzn_state table
---@param line string
---@param opts table
---@return string|nil
function M.on_response(kzn_state, line, opts)
  -- based on sse spec (OpenAI spec uses data-only server-sent events)
  local data = line:match '^data: (.+)$'

  if data and data:match '"delta":' then
    local json = vim.json.decode(data)
    local content = ''

    if json.choices and json.choices[1] and json.choices[1].delta and json.choices[1].delta.content then
      content = json.choices[1].delta.content
    end

    return content
  end
end

function M.on_content(...)
  return shared.on_content(...)
end

function M.before_request(...)
  return shared.before_request(...)
end

function M.make_job(...)
  return shared.make_job(...)
end

function M.after_request(...)
  return shared.after_request(...)
end

M.opts = {
  template_scope = 'nous_research'
}

return M
