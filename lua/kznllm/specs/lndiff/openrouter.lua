local M = {}

local API_KEY_NAME = 'OPENROUTER_API_KEY'
local BASE_URL = 'https://openrouter.ai'

local API_ERROR_MESSAGE = [[
ERROR: anthropic api key is set to %s and is missing from your environment variables.

Load somewhere safely from config `export %s=<api_key>`]]

local kznllm = require 'kznllm'
local shared = require 'kznllm.specs.lndiff.shared'
local Coder = require 'kznllm.lndiff.coder'
local ContentMap = require 'kznllm.lndiff.content_map'
local api = vim.api

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

---Example implementation of a `make_curl_data` compatible with `kznllm.invoke_llm` for anthropic spec
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

  data = vim.tbl_extend('keep', data, opts.data_params)

  return data
end

---@param kzn_state table
---@param curl_data table
---@param opts table
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

function M.after_request(kzn_state, ...)
  local content = kzn_state.response

  if content then
    local edits = {}

    for filename, removed, inserted in Coder.find_edits(content) do
      edits[filename] = edits[filename] or {}
      table.insert(edits[filename], {filename, removed, inserted})
    end

    local source_map = ContentMap.new(kzn_state.current_buffer_context, true)
    local source_edits = edits[kzn_state.current_buffer_path]
    local new_source_map, passed, _, _ = Coder.apply_edits(source_map, source_edits)

    if #passed > 0 then
      local buf_id = kzn_state.origin_buf_id
      local win_id = kzn_state.origin_win_id
      local new_lines = kznllm.splitlines(new_source_map:as_content({apply=true}))
      local last_line = new_lines[#new_lines]
      local cursor_row = math.min(#new_lines, kzn_state.srow + 1) -- nvim_win_set_cursor col argument is 1-indexed (!)
      local cursor_col = math.min(#last_line, kzn_state.scol)

      if vim.api.nvim_buf_is_valid(buf_id) then
        vim.api.nvim_buf_set_lines(buf_id, 0, -1, false, new_lines)
      end

      if vim.api.nvim_win_is_valid(win_id) then
        vim.api.nvim_win_set_cursor(win_id, { cursor_row, cursor_col })
      end
    end
  end

  return shared.after_request(kzn_state, ...)
end

M.opts = {
  debug_fn = debug,
  template_scope = 'lndiff/anthropic'
}

return M
