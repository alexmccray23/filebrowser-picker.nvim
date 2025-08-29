# filebrowser-picker.nvim

Yet another file browser for Neovim, providing telescope-file-browser.nvim's functionality/UX with snacks.nvim's picker.

## Features

- 🚀 **Fast async operations** powered by snacks.nvim picker
- 📁 **Persistent directory navigation** like telescope-file-browser
- 🌳 **Multi-root support** with dynamic workspace management
- ⚡ **High-performance file discovery** using fd, ripgrep, or fallback scanning
- 📝 **File operations**: create, rename, move, copy, delete with multi-file selection support
- 👁️ **Hidden files toggle**
- 🔄 **Root cycling** and smart workspace discovery
- 📊 **Git status integration** with async status loading and caching

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

### Basic Usage

```lua
-- Basic usage (opens in current buffer's directory, or cwd if no buffer file)
require("filebrowser-picker").file_browser()

-- With specific directory
require("filebrowser-picker").file_browser({
  cwd = vim.fn.expand("~/projects"),
  hidden = true,
})
```

### Multi-Root Usage

```lua
-- Multiple root directories with fast cross-root file discovery
require("filebrowser-picker").file_browser({
  roots = { "~/projects", "~/dotfiles", "/etc/nixos" },
  use_file_finder = true,  -- Enable high-performance scanning
  hidden = true,
})

-- Single root with explicit file finder mode
require("filebrowser-picker").file_browser({
  roots = { "~/large-monorepo" },
  use_file_finder = true,  -- Better for large directories
})
```

### Setup Configuration

```lua
require("filebrowser-picker").setup({
  hidden = false,
  respect_gitignore = true,
  roots = { "~/projects", "~/work" },  -- Default roots
  use_fd = true,  -- Prefer fd over ripgrep
  keymaps = {
    ["<CR>"] = "confirm",
    ["<C-g>"] = "goto_parent", 
    ["<C-n>"] = "cycle_roots",
    -- ... more keymaps
  }
})
```

## Default Keymaps

### Navigation & File Operations
| Key | Action | Description |
|-----|--------|-------------|
| `<CR>` | confirm | Open file/navigate to directory |
| `<C-v>` | edit_vsplit | Open in vertical split |
| `<C-x>` | edit_split | Open in horizontal split |
| `<A-t>` | edit_tab | Open in new tab |
| `<bs>` | conditional_backspace | Goes to parent dir if prompt is empty |

### Directory Navigation
| Key | Action | Description |
|-----|--------|-------------|
| `<C-g>` | goto_parent | Go to parent directory |
| `<C-e>` | goto_home | Go to home directory |
| `<C-r>` | goto_cwd | Go to working directory |
| `~` | goto_home | Go to home directory (alternative) |
| `-` | goto_previous_dir | Go to previous directory |
| `=` | goto_project_root | Go to git project root |
| `<C-t>` | set_pwd | Sets current working directory |

### Multi-Root Management & List Navigation
| Key | Action | Description |
|-----|--------|-------------|
| `<C-n>` | cycle_roots / list_down | Cycle to next root (multi-root) or move down list (single root) |
| `<C-p>` | cycle_roots_prev / list_up | Cycle to previous root (multi-root) or move up list (single root) |
| `gr` | root_add_here | Add current directory as root |
| `gR` | root_add_path | Add custom path as root |
| `<leader>wr` | root_pick_suggested | Pick from suggested workspace roots |
| `<leader>wR` | root_remove | Remove current root |

**Smart Navigation**: `<C-n>` and `<C-p>` adapt their behavior dynamically:
- **Multiple roots**: Navigate between different root directories
- **Single root**: Navigate up/down the file list (standard picker navigation)

### File Operations
| Key | Action | Description |
|-----|--------|-------------|
| `<A-h>` | toggle_hidden | Toggle hidden files |
| `<A-l>` | toggle_detailed_view | Toggle detailed file information (ls -l style) |
| `<A-c>` | create_file | Create new file/directory |
| `<A-r>` | rename | Rename selected item |
| `<A-m>` | move | Move selected item(s) |
| `<A-y>` | yank | Yank (copy to register) selected items |
| `<A-p>` | paste | Paste files from register |
| `<A-d>` | delete | Delete selected item |

**Multi-file Operations**: Use visual selection or `<Tab>` to select multiple files, then use move/yank/paste/delete operations on the entire selection.


## Configuration

```lua
require("filebrowser-picker").setup({
  -- Starting directory (default: current working directory)
  cwd = nil,
  
  -- Multiple root directories for workspace browsing
  roots = nil,  -- e.g., { "~/projects", "~/dotfiles", "/etc" }
  
  -- Show hidden files (default: false)
  hidden = false,
  
  -- Show detailed file information like ls -l (default: false)
  detailed_view = false,
  
  -- Configure which stats to show in detailed view (default: all enabled)
  display_stat = {
    mode = true,  -- File permissions (drwxrwxrwx)
    size = true,  -- File size (1.2K, 3.4M, etc.)
    date = true,  -- Last modified date (Jan 15 14:23)
  },
  
  -- Follow symbolic links (default: false) 
  follow_symlinks = false,
  
  -- Replace netrw with file browser for all directory operations (default: false)
  replace_netrw = false,
  
  -- Respect .gitignore (default: true)
  respect_gitignore = true,
  
  -- Show git status icons (default: true)
  git_status = true,
  
  -- Customize git status highlight groups
  git_status_hl = {
    staged = "DiagnosticHint",
    added = "Added", 
    deleted = "Removed",
    ignored = "NonText",
    modified = "DiagnosticWarn", 
    renamed = "Special",
    unmerged = "DiagnosticError",
    untracked = "NonText",
    copied = "Special",
  },
  
  -- Enable fast file discovery across roots (auto-detected by default)
  use_file_finder = nil,  -- true for multiple roots, false for single root
  
  -- File discovery tool preferences
  use_fd = true,          -- Prefer fd (fastest)
  use_rg = true,          -- Fallback to ripgrep
  
  -- Additional exclude patterns (beyond .gitignore)
  excludes = {},          -- e.g., { "*.tmp", "build/*" }
  
  -- Dynamic layout switching based on window width
  dynamic_layout = true,
  layout_width_threshold = 120,  -- Switch to vertical layout below this width
  
  -- Icon configuration (uses mini.icons or nvim-web-devicons when available)
  icons = {
    folder_closed = "󰉋 ",
    folder_open = "󰝰 ",
    file = "󰈔 ",
    symlink = "󰌷 ",
  },
  
  -- Custom keymaps
  keymaps = {
    -- override defaults here
    -- ["<C-custom>"] = "action_name"
  }
})
```

## Advanced Features

### Git Status Integration

The plugin displays git status indicators for files and directories when inside a git repository:

```lua
require("filebrowser-picker").setup({
  git_status = true,  -- Enable git status display (default: true)
  git_status_hl = {   -- Customize colors
    staged = "DiagnosticHint",
    modified = "DiagnosticWarn", 
    untracked = "NonText",
    -- ... more customizations
  },
})
```

**Features:**
- **Async git status loading**: Non-blocking `git status --porcelain` calls
- **Smart caching**: 15-minute TTL cache to avoid excessive git operations
- **Right-aligned indicators**: Git status appears as colored icons on the right
- **Repository-aware**: Automatically detects git repositories and shows relative paths
- **Performance optimized**: Preloads git status when scanning directories

**Supported status indicators:**
- `●` Staged changes (always takes priority)
- `○` Modified files
- `?` Untracked files
- `` Added files
- `` Deleted files
- `` Renamed files
- `` Unmerged conflicts
- ` ` Ignored files

### Symlink Following

Enable `follow_symlinks = true` to treat symbolic links as their target type:

```lua
require("filebrowser-picker").setup({
  follow_symlinks = true,  -- Follow symlinks when scanning and navigating
})
```

When enabled:
- Symlinked directories appear and behave as regular directories
- Can navigate into symlinked directories seamlessly
- File scanners (fd, rg, uv) will follow symlinks when discovering files
- Includes infinite loop protection for circular symlinks

### Netrw Replacement

Replace Neovim's built-in netrw file explorer completely:

```lua
require("filebrowser-picker").setup({
  replace_netrw = true,     -- Replace netrw with file browser
  follow_symlinks = true,   -- Recommended when replacing netrw
})

-- Or enable directly without full setup
require("filebrowser-picker").replace_netrw()
```

## Performance

The plugin uses intelligent file discovery for optimal performance:

### Scanner Selection
- **fd** (`fd-find`): Preferred for speed and excellent .gitignore support
- **ripgrep** (`rg --files`): Fallback with good performance and filtering
- **vim.uv**: Built-in Lua scanner with bounded concurrency as final fallback

### Performance Features
- **Streaming results**: Files appear as they're discovered, no waiting for full scan
- **Cancellation**: Scans are properly cancelled when switching directories or closing
- **Batch updates**: UI refreshes every 100 items to prevent blocking
- **Multi-root optimization**: Efficiently scans multiple directory trees in parallel

### External Dependencies (Optional)
For best performance, install these tools:
```bash
# On most systems
brew install fd ripgrep  # macOS
sudo apt install fd-find ripgrep  # Ubuntu/Debian
sudo pacman -S fd ripgrep  # Arch Linux
```

## Keybindings

Add keybindings to your Neovim config:

```lua
vim.keymap.set("n", "<leader>fb", function()
  require("filebrowser-picker").file_browser()
end, { desc = "File Browser" })

-- Multi-root example
vim.keymap.set("n", "<leader>fw", function()
  require("filebrowser-picker").file_browser({
    roots = { "~/projects", "~/work", "~/.config" },
    use_file_finder = true,
  })
end, { desc = "File Browser (Workspaces)" })
```

## Acknowledgments

This plugin is heavily inspired by and builds upon the excellent work of:

- [nvim-telescope/telescope-file-browser.nvim](https://github.com/nvim-telescope/telescope-file-browser.nvim)
- [folke/snacks.nvim](https://github.com/folke/snacks.nvim)
