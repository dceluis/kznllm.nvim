local M = {}

local API_KEY_NAME = 'VLLM_API_KEY'
local BASE_URL -- must provide this

local API_ERROR_MESSAGE = [[
ERROR: api key is set to %s and is missing from your environment variables.

Load somewhere safely from config `export %s=<api_key>`]]

local kznllm = require 'kznllm'
local shared = require 'kznllm.specs.shared'
local Path = require 'plenary.path'
local api = vim.api

local plugin_dir = Path:new(debug.getinfo(1, 'S').source:sub(2)):parents()[4]
local TEMPLATE_DIRECTORY = Path:new(plugin_dir) / 'templates'

--- Constructs arguments for constructing an HTTP request to the OpenAI API
--- using cURL.
---
---@param data table
---@return string[]
function M.make_curl_args(data, opts)
  local url = (opts and opts.base_url or BASE_URL) .. (opts and opts.endpoint)
  local api_key_name = opts and opts.api_key_name or API_KEY_NAME
  local api_key = os.getenv(api_key_name)

  if not api_key then
    error(API_ERROR_MESSAGE:format(api_key_name, api_key_name), 1)
  end

  local args = {
    '-s', --silent
    '--fail-with-body', --silent
    '-N', --no buffer
    '-X',
    'POST',
    '-H',
    'Content-Type: application/json',
    '-d',
    vim.json.encode(data),
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

---Example implementation of a `make_curl_data` compatible with `kznllm.invoke_llm` for anthropic spec
---@param kzn_state table
---@param opts table
---@return table
function M.make_curl_data(kzn_state, opts)
  local template_directory = opts.template_directory or TEMPLATE_DIRECTORY
  local data = {
    system = kznllm.make_prompt_from_template(template_directory / 'anthropic/fill_mode_system_prompt.xml.jinja', kzn_state),
    messages = {
      {
        role = 'user',
        content = kznllm.make_prompt_from_template(template_directory / 'anthropic/fill_mode_user_prompt.xml.jinja', kzn_state),
      },
    },
    model = opts.model,
    stream = true,
  }
  data = vim.tbl_extend('keep', data, opts.data_params)

  return data
end

function M.debug_fn(kzn_state, curl_data, buf_id, ns_id, extmark_id, opts)
  if opts and opts.debug then
    vim.print("[kznllm] debugging")
  else
    return
  end

  buf_id = kznllm.make_scratch_buffer()
  extmark_id = api.nvim_buf_set_extmark(buf_id, ns_id, 0, 0, {})

  kznllm.write_content_at_extmark('model: ' .. opts.model, buf_id, ns_id, extmark_id)
  kznllm.write_content_at_extmark('\n\n---\n\n', buf_id, ns_id, extmark_id)

  kznllm.write_content_at_extmark('system' .. ':\n\n', buf_id, ns_id, extmark_id)
  kznllm.write_content_at_extmark(curl_data.system, buf_id, ns_id, extmark_id)
  kznllm.write_content_at_extmark('\n\n---\n\n', buf_id, ns_id, extmark_id)
  for _, message in ipairs(curl_data.messages) do
    kznllm.write_content_at_extmark(message.role .. ':\n\n', buf_id, ns_id, extmark_id)
    kznllm.write_content_at_extmark(message.content, buf_id, ns_id, extmark_id)
    kznllm.write_content_at_extmark('\n\n---\n\n', buf_id, ns_id, extmark_id)
  end
  vim.cmd 'normal! G'
  vim.cmd 'normal! zz'

  return {stream_buf_id = buf_id, stream_extmark_id = extmark_id}
end

function M.before_request(...)
  return debug_fn(...)
end

function M.after_request(kzn_state, curl_args, stream_buf_id, ns_id, stream_extmark_id, opts)
  vim.api.nvim_buf_del_extmark(stream_buf_id, ns_id, stream_extmark_id)
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

---@param kzn_state table
---@param content string
---@param buf_id integer
---@param ns_id integer
---@param extmark_id integer
---@param opts table
function M.on_content(kzn_state, content, buf_id, ns_id, extmark_id, opts)
  kznllm.write_content_at_extmark(content, buf_id, ns_id, extmark_id)
end

function M.make_job(...)
  return shared.make_job(...)
end

return M
