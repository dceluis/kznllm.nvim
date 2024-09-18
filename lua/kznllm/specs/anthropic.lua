local M = {}

local API_KEY_NAME = 'ANTHROPIC_API_KEY'
local BASE_URL = 'https://api.anthropic.com'

local API_ERROR_MESSAGE = [[
ERROR: anthropic api key is set to %s and is missing from your environment variables.

Load somewhere safely from config `export %s=<api_key>`]]

local kznllm = require 'kznllm'
local Path = require 'plenary.path'
local Job = require 'plenary.job'
local current_event_state = nil

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
    '--fail-with-body',
    '-N', --no buffer
    '-X',
    'POST',
    '-H',
    'Content-Type: application/json',
    '-d',
    vim.json.encode(data),
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
---@param data string
---@return string
local function handle_data(data)
  local content = ''
  if data then
    local json = vim.json.decode(data)

    if json.delta and json.delta.text then
      content = json.delta.text
    end
  end

  return content
end

---Example implementation of a `make_data_fn` compatible with `kznllm.invoke_llm` for anthropic spec
---@param prompt_args any
---@param opts any
---@return table
function M.make_data_fn(prompt_args, opts)
  local template_directory = opts.template_directory or TEMPLATE_DIRECTORY
  local data = {
    system = kznllm.make_prompt_from_template(template_directory / 'anthropic/fill_mode_system_prompt.xml.jinja', prompt_args),
    messages = {
      {
        role = 'user',
        content = kznllm.make_prompt_from_template(template_directory / 'anthropic/fill_mode_user_prompt.xml.jinja', prompt_args),
      },
    },
    model = opts.model,
    stream = true,
  }
  data = vim.tbl_extend('keep', data, opts.data_params)

  return data
end

function M.debug_fn(prompt_args, data, ns_id, extmark_id, opts)
  kznllm.write_content_at_extmark('model: ' .. opts.model, ns_id, extmark_id)
  kznllm.write_content_at_extmark('\n\n---\n\n', ns_id, extmark_id)

  kznllm.write_content_at_extmark('system' .. ':\n\n', ns_id, extmark_id)
  kznllm.write_content_at_extmark(data.system, ns_id, extmark_id)
  kznllm.write_content_at_extmark('\n\n---\n\n', ns_id, extmark_id)
  for _, message in ipairs(data.messages) do
    kznllm.write_content_at_extmark(message.role .. ':\n\n', ns_id, extmark_id)
    kznllm.write_content_at_extmark(message.content, ns_id, extmark_id)
    kznllm.write_content_at_extmark('\n\n---\n\n', ns_id, extmark_id)
    vim.cmd 'normal! G'
  end
end

function M.make_job(args, writer_fn, on_exit_fn)
  local active_job = Job:new {
    command = 'curl',
    args = args,
    enable_recording = true,
    on_stdout = function(_, line)
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

        local content = handle_data(data)
        if content and content ~= nil then
          vim.schedule(function()
            writer_fn(content)
          end)
        end
      elseif current_event_state == 'message_start' then
        local data = line:match '^data: (.+)$'
        vim.print(data)
      elseif current_event_state == 'message_delta' then
        local data = line:match '^data: (.+)$'
        vim.print(data)
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
          on_exit_fn()
        end
      end)
    end,
  }
  return active_job
end

return M
