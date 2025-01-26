# Contributing

For development, you want to install the plugin locally and update your lazy config like this (same as the main project README with `dev = true` and `dir = path/to/plugin`):

```lua
{
  'chottolabs/kznllm.nvim',
  dev = true,
  dir = '$HOME/.config/nvim/plugins/kznllm.nvim',
  dependencies = {
    { 'nvim-lua/plenary.nvim' },
  },
  config = function(self)
  ...
  end
},
```

or if using vim-plug

```vim
Plug 'nvim-lua/plenary.nvim'
Plug '~/path/kznllm.nvim'
```

and then you can edit the plugin to your liking.
