Based on [dingllm.nvim](https://github.com/yacineMTB/dingllm.nvim) - but diverge quite a bit

- prompts user for additional context before filling
- structured to make the inherent coupling between neovim logic, LLM streaming spec, and model-specific templates more explicit
- uses jinja as templating engine for ensuring correctness in more complex prompts
- preset defaults + simple approach for overriding them
- free cursor movement during generation

> [!NOTE]
> This plugin depends on [minijinja-cli](https://github.com/mitsuhiko/minijinja) (`cargo install minijinja-cli`, but double-check) - way easier to compose prompts.

The only supported command is `leader + k`, it does nothing more than fill in some LLM completion into the text buffer. It has two main behaviors:
1. If you made a visual selection, it will attempt to replace your selection with a valid code fragment. 
2. If you make no visual selection, it can yap freely (or do something else specified by a good template).

By default (in supported templates), it also pipes in the contents of your current buffer.

---

It's easy to hack on and implement customize behaviors without actually understanding much about nvim plugins at all. I recommend you fork the repo and make it work for you.

See [CONTRIBUTING](CONTRIBUTING.md) to understand the typical development workflow for Neovim plugins using `Lazy` and some straightforward ways you can modify the plugin to suit your needs

By keeping the plugin simple with some QOL features, you get **close-to-natty** coding experience because it can keep generating code while you are free to do whatever you want (almost) without getting in the way too much.

https://github.com/user-attachments/assets/406fc75f-c204-42ec-80a0-0f9e186c34c7

_editing code while it generates when 405b is too slow_

## Configuration

Make your API keys available via environment variables
```
export LAMBDA_API_KEY=secret_...
export ANTHROPIC_API_KEY=sk-...
export GROQ_API_KEY=gsk_...
export DEEPSEEK_API_KEY=vllm_...
export VLLM_API_KEY=vllm_...
```

for lambda

> [!NOTE]
> project-mode is available when you have a directory named `.kzn`. It will
> use the folder closest to your current working directory and traverse backwards
> until it finds a `.kzn` directory or reaches your home directory and exits.
> 
> DON'T PUT ANYTHING OTHER THAN TEXT FILES IN THE DIRECTORY
> 
> A simple way to add specific files to context would've been to symlink another directory
> like this `ln -s $(readlink -f <path>) .kzn/code`... but scandir doesn't do
> that... use my fork of plenary.nvim to resolve symlinks in the directory [see patch](https://github.com/chottolabs/plenary.nvim/commit/7b0bf11bd3c286d6a45d8f5270369626b2ec6505)

for local openai server (e.g. `vllm serve` w/ `--api-key <token>` and `--served-model-name meta-llama/Meta-Llama-3.1-8B-Instruct`) set `VLLM_API_KEY=<token>`

full config w/ supported presets and a switch mechanism and provider-specific debug functions

Set the default `SELECTED_PRESET` based on [presets.lua](https://github.com/chottolabs/kznllm.nvim/blob/main/lua/kznllm/presets.lua#L279)

(i.e. `1 - groq`, `2 - lambda`, `3 - anthropic`, `4 - openai`, `5 - deepseek`, `6 - vllm (local)` or implement your own)

```lua
{
  'chottolabs/kznllm.nvim',
  dependencies = {
    { 'nvim-lua/plenary.nvim' }
    -- { 'chottolabs/plenary.nvim' }, -- patched to resolve symlinked directories
  },
  config = function(self)
    local presets = require 'kznllm.presets'

    -- edit this to change the selected preset (or just fork the repo and add your own)
    local SELECTED_PRESET = presets[1]
    local spec = require(('kznllm.specs.%s'):format(SELECTED_PRESET.provider))

    local function switch_presets()
      table.sort(presets, function(a, _)
        return a == SELECTED_PRESET
      end)
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
          return ('%-20s %10s | %s'):format(item.id, item.provider, table.concat(options, ' '))
        end,
      }, function(choice)
        if not choice then
          return
        end
        spec = require(('kznllm.specs.%s'):format(choice.provider))
        SELECTED_PRESET = choice
        print(('%-15s provider: %-10s'):format(choice.id, choice.provider))
      end)
    end

    vim.keymap.set({ 'n', 'v' }, '<leader>m', switch_presets, { desc = 'switch between presets' })

    local function llm_fill()
      presets.invoke_llm(
        SELECTED_PRESET.make_data_fn,
        spec.make_curl_args,
        spec.make_job,
        vim.tbl_extend('keep', SELECTED_PRESET.opts, {})
      )
    end

    vim.keymap.set({ 'n', 'v' }, '<leader>k', llm_fill, { desc = 'Send current selection to LLM llm_fill' })

    -- optional for debugging purposes
    local function debug()
      presets.invoke_llm(
        SELECTED_PRESET.make_data_fn,
        spec.make_curl_args,
        spec.make_job,
        vim.tbl_extend('keep', SELECTED_PRESET.opts, {
          debug = true,
        })
      )
    end

    vim.keymap.set({ 'n', 'v' }, '<leader>d', debug, { desc = 'Send current selection to LLM debug' })

    vim.api.nvim_set_keymap('n', '<Esc>', '', {
      noremap = true,
      silent = true,
      callback = function()
        vim.api.nvim_exec_autocmds('User', { pattern = 'LLM_Escape' })
      end,
    })
  end
},
```

minimal configuration with custom `make_data_fn` and no preset switcher. As you can see, the `make_data_fn` is simply building the `data` portion of the API call and will accept anything supported by the associated provider.

```lua
local presets = require 'kznllm'
local presets = require 'kznllm.presets'
local Path = require 'plenary.path'

local TEMPLATE_DIRECTORY = Path:new(vim.fn.expand(self.dir) .. '/templates')

---Example implementation of a `make_data_fn` compatible with `kznllm.invoke_llm` for groq spec
---@param prompt_args any
---@param opts { model: string, temperature: number, template_directory: Path, debug: boolean }
---@return table
---
local function make_data_for_openai_chat(prompt_args, opts)
  return {
    messages = {
      {
        role = 'system',
        content = kznllm.make_prompt_from_template(opts.template_directory / 'nous_research/fill_mode_system_prompt.xml.jinja', prompt_args),
      },
      {
        role = 'user',
        content = kznllm.make_prompt_from_template(opts.template_directory / 'nous_research/fill_mode_user_prompt.xml.jinja', prompt_args),
      },
    },
    model = opts.model,
    temperature = opts.temperature,
    stream = true,
  }
end

-- set initial preset on load
local spec = require('kznllm.specs.groq')

local function llm_fill()
  presets.invoke_llm(
    make_data_for_openai_chat,
    spec.make_curl_args,
    spec.make_job,
    {
      model = 'llama-3.1-70b-versatile',
      max_tokens = 8192,
      temperature = 0.7,
      base_url = 'https://api.groq.com',
      endpoint = '/openai/v1/chat/completions',
      template_directory = TEMPLATE_DIRECTORY,
    })
  )
end

vim.keymap.set({ 'n', 'v' }, '<leader>k', llm_fill, { desc = 'Send current selection to LLM llm_fill' })
```
