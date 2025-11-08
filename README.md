# filebrowser-picker.nvim

Yet another file browser for Neovim, providing telescope-file-browser.nvim's functionality/UX with snacks.nvim's picker.

## Features

- 🚀 **Fast async operations** powered by snacks.nvim picker
- 📁 **Persistent directory navigation** like telescope-file-browser
- 🌳 **Multi-root support** with dynamic workspace management
- ⚡ **High-performance file discovery** using ripgrep, fd, or fallback scanning
- 📝 **Cross-platform file operations**: create, rename, move, copy, delete using libuv with multi-file selection support
- 🛡️ **Safe deletion** with trash support and configurable confirmation levels
- 👁️ **Hidden files toggle**
- 🔄 **Root cycling** and smart workspace discovery
- 📊 **Git status integration** with async status loading and intelligent caching
- 🔧 **Netrw replacement** with telescope-file-browser compatibility (`hijack_netrw`)
- ⚡ **Performance optimizations** with optional UI and refresh batching modules
- 🔌 **Extensible API** with composable functions for custom workflows
- 📊 **Performance profiling** with built-in scanner benchmarking command

## Requirements

- Neovim >= 0.9.4
- [snacks.nvim](https://github.com/folke/snacks.nvim)

### Optional Dependencies

**For enhanced icons:**
- [mini.icons](https://github.com/echasnovski/mini.icons) _(recommended)_
- [nvim-web-devicons](https://github.com/nvim-tree/nvim-web-devicons) _(fallback)_

**For enhanced file discovery:**
- [`ripgrep`](https://github.com/BurntSushi/ripgrep) _(excellent filtering capabilities)_
- [`fd`](https://github.com/sharkdp/fd) _(advanced .gitignore support and exclude patterns)_

**For safe deletion:**
- [`trash-cli`](https://github.com/andreafrancia/trash-cli) _(Linux)_
- `trash` _(macOS, built-in)_

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

-- Composable API for custom workflows
require("filebrowser-picker").open_at("~/dotfiles")
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
  use_rg = true,  -- Default scanner
  
  -- Safety features
  use_trash = true,       -- Use trash for deletions (default: true)
  confirm_rm = "always",  -- "always", "multi", or "never"
  
  -- Telescope-file-browser compatibility
  hijack_netrw = false,   -- Alternative to replace_netrw
  
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

### File Operations & View Options
| Key | Action | Description |
|-----|--------|-------------|
| `<A-h>` | toggle_hidden | Toggle hidden files |
| `<A-l>` | toggle_detailed_view | Toggle detailed file information (ls -l style) |
| `<A-s>` | toggle_sort_by | Cycle sort field (name → size → mtime) |
| `<A-S>` | toggle_sort_reverse | Toggle sort direction (ascending ⇄ descending) |
| `<A-f>` | toggle_size_format | Toggle size format (auto ⇄ bytes) |
| `<A-c>` | create_file | Create new file/directory |
| `<A-r>` | rename | Rename selected item |
| `<A-v>` | move | Move selected item(s) |
| `<A-y>` | yank | Yank (copy to register) selected items |
| `<A-p>` | paste | Paste files from register |
| `<A-d>` | delete | Delete selected item (with trash support) |

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
  
  -- Size display format (default: "auto")
  size_format = "auto",  -- "auto" (1.2K, 3.4M) or "bytes" (1234, 3456789)
  
  -- Date format string for strftime (default: "%b %d %H:%M")
  date_format = "%b %d %H:%M",  -- Jan 15 14:23
  
  -- Sorting options
  sort_by = "name",       -- "name", "size", or "mtime"
  sort_reverse = false,   -- Reverse sort order
  
  -- Follow symbolic links (default: false) 
  follow_symlinks = false,
  
  -- Replace netrw with file browser for all directory operations (default: false)
  replace_netrw = false,
  
  -- Telescope-file-browser compatibility alias (default: false)
  hijack_netrw = false,
  
  -- Safe deletion options
  use_trash = true,        -- Use trash command when available (default: true)
  confirm_rm = "always",   -- "always", "multi" (>1 files), or "never" (default: "always")
  
  -- Resume functionality
  resume_last = false,     -- Resume at last visited directory (default: false)
  history_file = vim.fn.stdpath("data") .. "/filebrowser-picker/history",  -- History file path
  
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
  use_rg = true,
  use_fd = true,
  
  -- Additional exclude patterns (beyond .gitignore)
  excludes = {},          -- e.g., { "*.tmp", "build/*" }
  
  -- Extra arguments to pass to file scanner commands
  extra_rg_args = {},     -- e.g., { "--max-depth", "3" }
  extra_fd_args = {},     -- e.g., { "--max-depth", "3" }
  
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
  
  -- Performance optimizations (optional)
  performance = {
    ui_optimizations = false,     -- Enable for large directories, detailed view
    refresh_batching = false,     -- Enable for file finder mode, large codebases
    refresh_rate_ms = 16,         -- Refresh rate (~60fps)
  },
  
  -- Event callbacks
  on_dir_change = function(new_dir) end,        -- Called when directory changes
  on_confirm = function(item) end,              -- Called when file/directory is confirmed
  on_roots_change = function(roots) end,        -- Called when roots configuration changes
  on_enter = function(picker_opts) end,         -- Called when filebrowser enters
  on_leave = function() end,                    -- Called when filebrowser exits
  
  -- Custom keymaps
  keymaps = {
    -- override defaults here
    -- ["<C-custom>"] = "action_name"
  }
})
```

## Advanced Features

### Safe Deletion with Trash Support

The plugin provides safe deletion with trash integration and configurable confirmation:

```lua
require("filebrowser-picker").setup({
  use_trash = true,         -- Use trash command when available (default)
  confirm_rm = "always",    -- Confirmation level: "always", "multi", "never"
})
```

**Features:**
- **Trash integration**: Automatically detects `trash-put`, `trash`, `gtrash`, or `rmtrash`
- **Fallback safety**: Falls back to permanent deletion with clear warnings
- **Smart confirmation**: Different prompts for files vs directories with contents
- **Multi-file support**: Handles bulk operations with appropriate confirmations
- **Recursive handling**: Special prompts for directories containing files

### Git Status Integration

The plugin displays git status indicators with intelligent caching:

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
- **Async git status loading**: Non-blocking `git status --porcelain=v1 -z` calls
- **Intelligent caching**: TTL cache with `.git/index` mtime invalidation
- **Repository-aware**: Uses realpath normalization for consistent cache keys
- **Performance optimized**: Preloads git status when scanning directories
- **Priority-based display**: Staged changes always take precedence

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
  -- OR for telescope-file-browser compatibility:
  hijack_netrw = true,      -- Same functionality, different name
  follow_symlinks = true,   -- Recommended when replacing netrw
})

-- Or enable directly without full setup
require("filebrowser-picker").replace_netrw()
-- OR using telescope-file-browser compatible API:
require("filebrowser-picker").hijack_netrw()
```

**Features:**
- **Seamless integration**: Opening directories with `nvim /path/to/dir` launches the file browser
- **Proper focus handling**: Input goes to picker prompt, not background buffer
- **Clean navigation**: All keybindings work correctly, including `<Esc>` to exit
- **No flickering**: Buffer cleanup happens without visual artifacts

## Performance

The plugin uses intelligent file discovery for optimal performance:

### Scanner Selection
- **ripgrep** (`rg --files`): Excellent performance and regex-based exclusions  
- **fd** (`fd-find`): Advanced .gitignore support and sophisticated filtering
- **vim.uv**: Built-in scanner with no external dependencies

### Performance Features
- **Streaming results**: Files appear as they're discovered, no waiting for full scan
- **Cancellation**: Scans are properly cancelled when switching directories or closing
- **Batch updates**: UI refreshes every 100 items to prevent blocking
- **Multi-root optimization**: Efficiently scans multiple directory trees in parallel

### External Dependencies (Optional)
For enhanced features, install these tools:
```bash
# On most systems
brew install ripgrep fd            # macOS
sudo apt install ripgrep fd-find   # Ubuntu/Debian
sudo pacman -S ripgrep fd          # Arch Linux
```

## Performance Optimizations

The plugin includes optional performance modules for enhanced responsiveness in demanding scenarios.

### Enable via Configuration

```lua
require("filebrowser-picker").setup({
  -- Enable performance optimizations
  performance = {
    ui_optimizations = true,    -- Icon caching, formatting optimizations
    refresh_batching = true,    -- Debounced refreshes for file finder
    refresh_rate_ms = 16,       -- ~60fps refresh rate (optional)
  },
  -- your other config...
})
```

### UI Optimizations

**When to enable:** `ui_optimizations = true`
- Large directories, detailed view, or frequent navigation

**Benefits:**
- **Icon caching**: Eliminates repeated plugin lookups (30-50% faster icon rendering)
- **Window width caching**: Reduces API calls during layout calculations
- **Optimized formatting**: Custom alignment with intelligent truncation
- **Permission fast-path**: Uses cached file modes to avoid redundant stat calls

### Refresh Batching

**When to enable:** `refresh_batching = true`
- File finder mode with large codebases or slow filesystems

**Benefits:**
- **Debounced refreshes**: Prevents UI thrashing during rapid file discovery
- **Configurable refresh rate**: Balance responsiveness with system resources
- **Smart batching**: Only refreshes when new items are actually added

### Legacy Usage (Still Supported)

If you prefer manual control, the original approach still works:
```lua
require("filebrowser-picker").setup({
  -- your config
})

-- Manual installation
require("filebrowser-picker.perf").install()
require("filebrowser-picker.perf_batch").install({ refresh_ms = 16 })
```

### Performance Scenarios

| Scenario | Recommended Configuration |
|----------|---------------------------|
| **Large monorepos** | Both `ui_optimizations = true` + `refresh_batching = true` |
| **Network filesystems** | `ui_optimizations = true` with appropriate scanner |
| **Detailed view usage** | `ui_optimizations = true` for formatting optimizations |  
| **Multi-root workflows** | `refresh_batching = true` for smooth file discovery |
| **General usage** | Default settings work well for most cases |

## Events System

The plugin provides a comprehensive event system for integration with other plugins and custom workflows:

### Event Callbacks

Configure event callbacks in your setup:

```lua
require("filebrowser-picker").setup({
  on_enter = function(picker_opts)
    print("File browser opened with options:", vim.inspect(picker_opts))
  end,
  
  on_leave = function()
    print("File browser closed")
  end,
  
  on_dir_change = function(new_dir)
    print("Changed to directory:", new_dir)
  end,
  
  on_confirm = function(item)
    print("Confirmed file:", item.file)
  end,
  
  on_roots_change = function(roots)
    print("Root configuration changed:", vim.inspect(roots))
  end,
})
```

### User Autocommands

The plugin emits User autocommands for all major events:

```lua
vim.api.nvim_create_autocmd("User", {
  pattern = "FilebrowserEnter",
  callback = function(ev)
    print("File browser entered:", vim.inspect(ev.data))
  end,
})

vim.api.nvim_create_autocmd("User", {
  pattern = "FilebrowserDirChanged", 
  callback = function(ev)
    print("Directory changed to:", ev.data.dir)
  end,
})

vim.api.nvim_create_autocmd("User", {
  pattern = "FilebrowserFileDeleted",
  callback = function(ev)
    print("Files deleted:", ev.data.deleted_count)
    if ev.data.use_trash then
      print("Used trash for deletion")
    end
  end,
})
```

### Available Events

| Event | Description | Data |
|-------|-------------|------|
| `FilebrowserEnter` | Picker opened | `picker_opts` |
| `FilebrowserLeave` | Picker closed | none |
| `FilebrowserDirChanged` | Directory navigation | `{ dir = string }` |
| `FilebrowserFileConfirmed` | File/directory confirmed | `{ item = table }` |
| `FilebrowserRootsChanged` | Root configuration changed | `{ roots = table }` |
| `FilebrowserFileCreated` | File/directory created | `{ path = string, is_dir = boolean }` |
| `FilebrowserFileRenamed` | File/directory renamed | `{ old_path = string, new_path = string }` |
| `FilebrowserFileDeleted` | Files deleted | `{ items = table, deleted_count = number, use_trash = boolean }` |

### Resume Functionality

Enable resume functionality to automatically return to your last visited directory:

```lua
require("filebrowser-picker").setup({
  resume_last = true,  -- Resume at last visited directory
  history_file = vim.fn.stdpath("data") .. "/filebrowser-picker/history",  -- Custom history location
})
```

**Features:**
- **Persistent history**: Remembers visited directories across Neovim sessions
- **Root configurations**: Tracks multi-root setups for quick recall
- **JSON storage**: Human-readable format in `stdpath("data")/filebrowser-picker/history`
- **Automatic cleanup**: Maintains reasonable history file size
- **Privacy aware**: Only stores directory paths, no file contents

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

## API Reference

The plugin provides a composable API for advanced usage:

```lua
local fb = require("filebrowser-picker")

-- Core functions
fb.file_browser(opts)           -- Main file browser function
fb.open_at(path, opts)          -- Open at specific directory
fb.setup(opts)                  -- Configure plugin

-- Configuration management
fb.toggle_hidden(show)          -- Toggle hidden files globally

-- Netrw replacement
fb.replace_netrw()              -- Enable netrw replacement
fb.hijack_netrw()               -- Telescope-file-browser compatible alias

-- Module access
fb.actions                      -- Access to all picker actions
fb.config                       -- Current configuration
```

### Migration from telescope-file-browser.nvim

Most telescope-file-browser configurations work with minimal changes:

```lua
-- Before (telescope-file-browser)
require("telescope").setup({
  extensions = {
    file_browser = {
      hijack_netrw = true,
      hidden = true,
      -- ... other options
    }
  }
})

-- After (filebrowser-picker)
require("filebrowser-picker").setup({
  hijack_netrw = true,  -- Same option name!
  hidden = true,
  -- ... other options work similarly
})
```

## Commands

filebrowser-picker.nvim provides the following user commands:

- `:FileBrowser [path]` - Open file browser (optionally at specific path)
- `:FileBrowserPickerProfile [path]` - Profile scanner performance for the given directory (or current directory)

### Performance Profiling

Use `:FileBrowserPickerProfile` to benchmark scanner performance and get optimization recommendations:

```vim
:FileBrowserPickerProfile ~/large-project
```

This will test fd, ripgrep, and uv scanners, showing:
- Execution time for each scanner
- File counts discovered
- Files per second processed
- Recommendations for optimal scanner selection

## Development & Tooling

The project includes comprehensive tooling for development:

### Static Analysis

- **StyLua**: Code formatting with `stylua.toml` configuration
- **Selene**: Lua linting with `selene.toml` configuration
- **GitHub Actions**: Automated CI running `stylua --check` and selene linting

### Cross-Platform File Operations

All file operations (move, copy, delete) use libuv for cross-platform reliability:
- `uv.fs_rename()` for file moves (instead of `os.rename`)
- `uv.fs_copyfile()` for file copying
- Recursive directory copying with proper error handling

## Acknowledgments

This plugin is heavily inspired by and builds upon the excellent work of:

- [nvim-telescope/telescope-file-browser.nvim](https://github.com/nvim-telescope/telescope-file-browser.nvim)
- [folke/snacks.nvim](https://github.com/folke/snacks.nvim)
