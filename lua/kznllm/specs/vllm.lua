local M = {}

local API_KEY_NAME = 'VLLM_API_KEY'
local BASE_URL -- must provide this

local API_ERROR_MESSAGE = [[
ERROR: api key is set to %s and is missing from your environment variables.

Load somewhere safely from config `export %s=<api_key>`]]

local kznllm = require 'kznllm'
local Path = require 'plenary.path'
local Job = require 'plenary.job'

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

--- Process server-sent events based on OpenAI spec
--- [See Documentation](https://platform.openai.com/docs/api-reference/chat/create#chat-create-stream)
---
---@param line string
---@return string
local function handle_data(line)
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
  end
  vim.cmd 'normal! G'
  vim.cmd 'normal! zz'
end

-- TODO: create a new spec vllm_completions
-- function M.completions_debug_fn(data, ns_id, extmark_id, opts)
--   kznllm.write_content_at_extmark('model: ' .. opts.model, ns_id, extmark_id)
--   kznllm.write_content_at_extmark('\n\n---\n\n', ns_id, extmark_id)
--   kznllm.write_content_at_extmark(data.prompt, ns_id, extmark_id)
--   kznllm.write_content_at_extmark('\n\n---\n\n', ns_id, extmark_id)
--   vim.cmd 'normal! G'
--   vim.cmd 'normal! zz'
-- end

---@param args table
---@param writer_fn fun(content: string)
function M.make_job(args, writer_fn, on_exit_fn)
  local active_job = Job:new {
    command = 'curl',
    args = args,
    enable_recording = true,
    on_stdout = function(_, line)
      local content = handle_data(line)
      if content and content ~= nil then
        vim.schedule(function()
          writer_fn(content)
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
          on_exit_fn()
        end
      end)
    end,
  }
  return active_job
end

return M
