local M = {}

local API_KEY_NAME = 'OPENAI_API_KEY'
local BASE_URL = 'https://api.openai.com'

local API_ERROR_MESSAGE = [[
ERROR: OpenAI API key is set to %s and is missing from your environment variables.

Load somewhere safely from config `export %s=<api_key>`]]

local kznllm = require 'kznllm'
local shared = require 'kznllm.specs.lndiff.shared'
local Coder = require 'kznllm.lndiff.coder'
local ContentMap = require 'kznllm.lndiff.content_map'
local api = vim.api


--- Construct cURL arguments for OpenAI API
---@param kzn_state table
---@param curl_data table
---@param opts table
---@return string[]
function M.make_curl_args(kzn_state, curl_data, opts)
  local url = (opts and opts.base_url or BASE_URL) .. (opts and opts.endpoint or '/v1/chat/completions')
  local api_key_name = opts and opts.api_key_name or API_KEY_NAME
  local api_key = os.getenv(api_key_name)

  if not api_key then
    error(API_ERROR_MESSAGE:format(api_key_name, api_key_name), 1)
  end

  local args = {
    '-s', -- silent
    '--fail-with-body',
    '-N', -- no buffer
    '-X', 'POST',
    '-H', 'Content-Type: application/json',
    '-H', 'Authorization: Bearer ' .. api_key,
    '-d', vim.json.encode(curl_data),
    url
  }

  return args
end

---@param kzn_state table
---@param opts table
function M.get_current_file(kzn_state, opts)
  return shared.get_current_file(kzn_state, opts)
end

--- Generate OpenAI-compatible request data
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
      content = kznllm.make_prompt_from_template(system_template, kzn_state)
    },
    {
      role = 'user',
      content = kznllm.make_prompt_from_template(user_template, kzn_state)
    }
  }

  return {
    messages = messages,
    model = opts.model,
    stream = true,
    temperature = opts.data_params.temperature or 0.3,
    max_tokens = opts.data_params.max_tokens or 4096
  }
end

--- Process OpenAI streaming response
---@param kzn_state table
---@param line string
---@param opts table
---@return string|nil
function M.on_response(kzn_state, line, opts)
  local data = line:match '^data: (.+)$'
  if data and data ~= '[DONE]' then
    local json = vim.json.decode(data)
    if json.choices and json.choices[1] and json.choices[1].delta and json.choices[1].delta.content then
      return json.choices[1].delta.content
    end
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
      local new_lines = kznllm.splitlines(new_source_map:as_content({apply = true}))
      
      if vim.api.nvim_buf_is_valid(buf_id) then
        vim.api.nvim_buf_set_lines(buf_id, 0, -1, false, new_lines)
      end
      
      if vim.api.nvim_win_is_valid(win_id) then
        local last_line = new_lines[#new_lines] or ''
        local cursor_row = math.min(#new_lines, kzn_state.srow + 1)
        local cursor_col = math.min(#last_line, kzn_state.scol)
        vim.api.nvim_win_set_cursor(win_id, {cursor_row, cursor_col})
      end
    end
  end

  return shared.after_request(kzn_state, ...)
end

M.opts = {
  template_scope = 'lndiff/anthropic',
  debug_fn = function(kzn_state, curl_data, opts)
    local buf_id = kzn_state.stream_buf_id
    local ns_id = api.nvim_create_namespace 'kznllm_ns'
    local extmark_id = kzn_state.stream_extmark_id

    kznllm.write_content_at_extmark('model: ' .. opts.model, buf_id, ns_id, extmark_id)
    for _, message in ipairs(curl_data.messages) do
      kznllm.write_content_at_extmark('\n\n============ ' .. message.role .. ' message: ============ \n\n', 
        buf_id, ns_id, extmark_id)
      kznllm.write_content_at_extmark(message.content, buf_id, ns_id, extmark_id)
    end
    vim.cmd 'normal! G'
    vim.cmd 'normal! zz'
  end
}

return M
