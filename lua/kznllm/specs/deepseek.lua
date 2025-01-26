local openai = require 'kznllm.specs.openai'

local M = setmetatable({}, { __index = openai })

M.opts = vim.tbl_deep_extend('force', openai.opts, {
  api_key_name = 'DEEPSEEK_API_KEY',
  base_url = 'https://api.deepseek.com/beta',
})

return M
