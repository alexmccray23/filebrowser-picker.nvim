# filebrowser-picker.nvim

A file browser for Neovim using snacks.nvim's picker, providing telescope-file-browser.nvim functionality with better performance through async operations.

## Features

- 🚀 **Fast async operations** powered by snacks.nvim picker
- 📁 **Persistent directory navigation** like telescope-file-browser
- 📝 **File operations**: create, rename, move, copy, delete
- 👁️ **Hidden files toggle**

## Requirements

- Neovim >= 0.9.0
- [snacks.nvim](https://github.com/folke/snacks.nvim)

### Optional (for enhanced icons)

- [mini.icons](https://github.com/echasnovski/mini.icons) _(recommended)_
- [nvim-web-devicons](https://github.com/nvim-tree/nvim-web-devicons) _(fallback)_

## Installation

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "alexmccray23/filebrowser-picker.nvim",
  dependencies = { "folke/snacks.nvim" },
  config = function()
    require("filebrowser-picker").setup({
      -- your config here
    })
  end,
}
```

### [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
  "alexmccray23/filebrowser-picker.nvim",
  requires = { "folke/snacks.nvim" },
  config = function()
    require("filebrowser-picker").setup({
      -- your config here
    })
  end,
}
```

## Usage

```lua
-- Basic usage (opens in current buffer's directory, or cwd if no buffer file)
require("filebrowser-picker").file_browser()

-- With specific directory
require("filebrowser-picker").file_browser({
  cwd = vim.fn.expand("~/projects"),
  hidden = true,
})

-- Setup with custom config
require("filebrowser-picker").setup({
  hidden = false,
  respect_gitignore = true,
  keymaps = {
    ["<CR>"] = "confirm",
    ["<C-g>"] = "goto_parent", 
    -- ... more keymaps
  }
})
```

## Default Keymaps

| Key | Action | Description |
|-----|--------|-------------|
| `<CR>` | confirm | Open file/navigate to directory |
| `<C-v>` | edit_vsplit | Open in vertical split |
| `<C-x>` | edit_split | Open in horizontal split |
| `<A-t>` | edit_tab | Open in new tab |
| `<bs>` | conditional_backspace | Goes to parent dir if prompt is empty |
| `<C-g>` | goto_parent | Go to parent directory |
| `<C-e>` | goto_home | Go to home directory |
| `<C-r>` | goto_cwd | Go to working directory |
| `<C-t>` | set_pwd | Sets current working directory |
| `<A-h>` | toggle_hidden | Toggle hidden files |
| `<A-c>` | create_file | Create new file/directory |
| `<A-r>` | rename | Rename selected item |
| `<A-m>` | move | Move selected item |
| `<A-y>` | copy | Copy selected item |
| `<A-d>` | delete | Delete selected item |


## Configuration

```lua
require("filebrowser-picker").setup({
  -- Starting directory (default: current working directory)
  cwd = nil,
  
  -- Show hidden files (default: false)
  hidden = false,
  
  -- Follow symbolic links (default: false) 
  follow_symlinks = false,
  
  -- Respect .gitignore (default: true)
  respect_gitignore = true,
  
  -- Show git status icons (default: true)
  git_status = true,
  
  -- Icon configuration (uses mini.icons or nvim-web-devicons when available)
  -- Individual files get icons from icon libraries automatically
  -- These are fallback icons when libraries are not available
  icons = {
    folder_closed = "󰉋 ",
    folder_open = "󰝰 ",
    file = "󰈔 ",           -- fallback for files without specific icons
    symlink = "󰌷 ",
  },
  
  -- Custom keymaps
  keymaps = {
    -- override defaults here
  }
})
```

## Keybindings

Add keybindings to your Neovim config:

```lua
vim.keymap.set("n", "<leader>fb", function()
  require("filebrowser-picker").file_browser()
end, { desc = "File Browser" })
```

## Acknowledgments

This plugin is heavily inspired by and builds upon the excellent work of:

- [nvim-telescope/telescope-file-browser.nvim](https://github.com/nvim-telescope/telescope-file-browser.nvim)
- [folke/snacks.nvim](https://github.com/folke/snacks.nvim)
