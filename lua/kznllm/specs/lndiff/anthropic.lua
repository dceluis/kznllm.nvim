local M = {}

local API_KEY_NAME = 'ANTHROPIC_API_KEY'
local BASE_URL = 'https://api.anthropic.com'
local ENDPOINT = '/v1/messages'

local API_ERROR_MESSAGE = [[
ERROR: anthropic api key is set to %s and is missing from your environment variables.

Load somewhere safely from config `export %s=<api_key>`]]

local kznllm = require 'kznllm'
local shared = require 'kznllm.specs.lndiff.shared'
local Coder = require 'kznllm.lndiff.coder'
local ContentMap = require 'kznllm.lndiff.content_map'
local api = vim.api
local current_event_state = nil

--- Constructs arguments for constructing an HTTP request to the OpenAI API
--- using cURL.
---
---@param curl_data table
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
    'x-api-key: ' .. api_key,
    '-H',
    'anthropic-version: 2023-06-01',
    '-H',
    'anthropic-beta: max-tokens-3-5-sonnet-2024-07-15',
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

  local data = {
    system = kznllm.make_prompt_from_template(system_template, kzn_state),
    messages = {
      {
        role = 'user',
        content = kznllm.make_prompt_from_template(user_template, kzn_state),
      },
    },
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
end

--- Anthropic SSE Specification
--- [See Documentation](https://docs.anthropic.com/en/api/messages-streaming#event-types)
---
--- Each server-sent event includes a named event type and associated JSON
--- data. Each event will use an SSE event name (e.g. event: message_stop),
--- and include the matching event type in its data.
---
--- Each stream uses the following event flow:
---
--- 1. `message_start`: contains a Message object with empty content.
---
--- 2. A series of content blocks, each of which have a `content_block_start`,
---    one or more `content_block_delta` events, and a `content_block_stop`
---    event. Each content block will have an index that corresponds to its
---    index in the final Message content array.
---
--- 3. One or more `message_delta` events, indicating top-level changes to the
---    final Message object.
--- 4. `message_stop` event
---
--- event types: `[message_start, content_block_start, content_block_delta, content_block_stop, message_delta, message_stop, error]`
---@param kzn_state table
---@param line string
---@param opts table
---@return string|nil
function M.on_response(kzn_state, line, opts)
    if line == '' then
      return
    end

    -- based on sse spec (Anthropic spec has several distinct events)
    -- Anthropic's sse spec requires you to manage the current event state
    local event = line:match '^event: (.+)$'

    if event then
      current_event_state = event
      return
    end

    if current_event_state == 'content_block_delta' then
      local data = line:match '^data: (.+)$'

      local content = ''
      if data then
        local json = vim.json.decode(data)

        if json.delta and json.delta.text then
          content = json.delta.text
        end
      end

      return content
    elseif current_event_state == 'message_start' then
      -- local data = line:match '^data: (.+)$'
      -- vim.print(data)
    elseif current_event_state == 'message_delta' then
      -- local data = line:match '^data: (.+)$'
      -- vim.print(data)
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
