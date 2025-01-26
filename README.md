# kznllm.nvim

The only main command is `leader + k`, it does nothing more than fill in some LLM completion into the text buffer. It has two main behaviors:
1. If you made a visual selection, it will attempt to replace your selection with a valid code fragment. 
2. If you make no visual selection, it can yap freely (or do something else specified by a good template).

> [!NOTE]
> project-mode is also available when you have a directory named `.kzn`. It will use the folder closest to your current working directory and traverse backwards until it finds a `.kzn` directory or reaches your home directory and exits.

It's easy to hack on and implement customize behaviors without understanding much about nvim plugins. Try the default preset configuration provided below, but I recommend you fork the repo and using the preset as a reference for implementing your own features.

- **close-to-natty** coding experience
- add custom prompt templates
- pipe any context into template engine
- extend with custom features/modes

https://github.com/user-attachments/assets/406fc75f-c204-42ec-80a0-0f9e186c34c7

## Installation

> [!NOTE]
> This plugin depends on [minijinja-cli](https://github.com/mitsuhiko/minijinja) - way easier to compose prompts.

1. Install `minijinja-cli` (required for prompt templating):
```bash
   cargo install minijinja-cli
```

2.1 Add the plugin to your Neovim configuration using [Lazy.nvim](https://github.com/folke/lazy.nvim):
```lua
   {
     'chottolabs/kznllm.nvim',
     dependencies = { 'nvim-lua/plenary.nvim' },
     config = function()
       -- Add your configuration here (see Configuration section below)
     end
   }
```

2.2 Or, add the plugin to your Neovim configuration using [plug.vim](https://github.com/junegunn/vim-plug):
```vim
   Plug 'nvim-lua/plenary.nvim'
   Plug 'chottolabs/kznllm.nvim'
```

   Then, in your `init.vim` or `init.lua`, add the following configuration:
```lua
   require('kznllm').setup({
     -- Add your configuration here (see Configuration section below)
   })
```

## Configuration

Make your API keys available via environment variables
```
export LAMBDA_API_KEY=secret_...
export ANTHROPIC_API_KEY=sk-...
export OPENAI_API_KEY=sk-proj-...
export GROQ_API_KEY=gsk_...
export DEEPSEEK_API_KEY=vllm_...
export VLLM_API_KEY=vllm_...
```

Full config with a preset switcher mechanism and optional debugging:

```lua
{
  'chottolabs/kznllm.nvim',
  -- dev = true,
  -- dir = /path/to/your/fork,
  dependencies = {
    { 'nvim-lua/plenary.nvim' }
  },
  config = function(self)
    local presets = require 'kznllm.presets'

    -- bind a key to the preset switcher
    vim.keymap.set({ 'n', 'v' }, '<leader>m', presets.switch_presets, { desc = 'switch between presets' })

    local function llm_fill()
      local selected_preset = presets.load()

      presets.invoke_llm(selected_preset)
    end

    vim.keymap.set({ 'n', 'v' }, '<leader>k', llm_fill, { desc = 'Send current selection to LLM llm_fill' })

    -- optional for debugging purposes
    local function debug()
      local selected_preset = presets.load()

      presets.invoke_llm(selected_preset, { debug = true })
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

---

## Contributing

See [CONTRIBUTING](CONTRIBUTING.md) to understand the typical development workflow for Neovim plugins using `Lazy` and some straightforward ways you can modify the plugin to suit your needs

---

## Additional Notes

Originally based on [dingllm.nvim](https://github.com/yacineMTB/dingllm.nvim) - but diverged quite a bit

- prompts user for additional context before filling
- structured to make the inherent coupling between neovim logic, LLM streaming spec, and model-specific templates more explicit
- uses jinja as templating engine for ensuring correctness in more complex prompts
- preset defaults + simple approach for overriding them
- free cursor movement during generation
- avoids "undojoin after undo" error

## Alternative Configurations

Minimal configuration with no preset switcher and a custom template directory

```lua
local Path = require 'plenary.path'
local TEMPLATE_DIRECTORY = Path:new(vim.fn.expand('~') .. '/templates')

local function llm_fill()
    presets.invoke_llm({
        id = 'r1-llama-70B-ln-or',
        -- prompt = 'ask claude' -- optional. set an alternative input prompt
        spec = 'openai', -- required. 'openai' | 'anthropic' | 'lndiff/openai' | 'lndiff/anthropic'
        opts = {
            model = 'deepseek/deepseek-r1-distill-llama-70b',
            data_params = {
                max_tokens = 8192,
                temperature = 0.7,
            },
            api_key_name = 'OPENROUTER_API_KEY', -- optional
            base_url = 'https://openrouter.ai/api', -- optional
            -- endpoint = '/v1/chat/completions', -- optional
            -- template_directory = TEMPLATE_DIRECTORY, -- optional. set an alternative template directory
            -- template_scope = 'openrouter', -- optional. set an alternative template scope (template will be searched in `template_directory/template_scope/..` )
        }
    })
end

vim.keymap.set({ 'n', 'v' }, '<leader>f', llm_fill, { desc = 'Send current selection to LLM llm_fill' })
```

Minimal VLLM configuration with no preset switcher

```lua
local function llm_fill()
    presets.invoke_llm({
        id = 'qwen-2.5-1.5b-vllm',
        spec = 'vllm',
        opts = {
            model = 'Qwen/Qwen2.5-1.5B-Instruct',
            data_params = {
                max_tokens = 512,
                temperature = 0.7,
            },
            api_key_name = 'VLLM_API_KEY',
            base_url = 'http://localhost:8000/v1'
        }
    })
end

vim.keymap.set({ 'n', 'v' }, '<leader>f', llm_fill, { desc = 'Send current selection to VLLM' })
```
