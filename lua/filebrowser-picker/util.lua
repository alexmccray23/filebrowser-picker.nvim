---@class filebrowser-picker.util
local M = {}

local uv = vim.uv or vim.loop
local notify = require "filebrowser-picker.notify"

-- Cache for git root lookups to avoid repeated shell calls
local git_root_cache = {}
local cache_expiry = 30000 -- 30 seconds in milliseconds

--- Get an icon from `mini.icons` or `nvim-web-devicons`, similar to snacks.nvim
--- Returns icon, highlight_group
---@param name string
---@param cat? string defaults to "file"
---@param opts? { fallback?: {dir?:string, file?:string} }
---@return string, string?
function M.icon(name, cat, opts)
  opts = opts or {}
  opts.fallback = opts.fallback or {}
  local try = {
    function()
      return require("mini.icons").get(cat or "file", name)
    end,
    function()
      if cat == "directory" then
        return opts.fallback.dir or "󰉋", "Directory"
      end
      local Icons = require "nvim-web-devicons"
      if cat == "filetype" then
        return Icons.get_icon_by_filetype(name, { default = false })
      elseif cat == "file" then
        local ext = name:match "%.(%w+)$"
        return Icons.get_icon(name, ext, { default = false }) --[[@as string, string]]
      elseif cat == "extension" then
        return Icons.get_icon(nil, name, { default = false }) --[[@as string, string]]
      end
    end,
  }
  for _, fn in ipairs(try) do
    local ret = { pcall(fn) }
    if ret[1] and ret[2] then
      return ret[2], ret[3]
    end
  end
  return opts.fallback.file or "󰈔"
end

--- Get default icons using icon libraries when available
---@return table
function M.get_default_icons()
  local folder_icon = M.icon("folder", "directory", { fallback = { dir = "󰉋" } })
  return {
    folder_closed = folder_icon, -- just the icon string
    folder_open = "󰝰", -- keep simple for open folders
    file = "󰈔", -- fallback for files without specific icons
    symlink = "󰌷", -- symlinks are less common, keep simple fallback
    -- Git status icons (following Snacks.nvim conventions)
    git = {
      staged = "●", -- always overrides other icons when staged
      added = "●",
      deleted = " ",
      ignored = " ",
      modified = "○",
      renamed = " ",
      unmerged = " ",
      untracked = "?",
      copied = " ",
    },
  }
end

-- ========================================================================
-- Filesystem Utilities (extracted from duplicated code)
-- ========================================================================

---@class FileBrowserItem
---@field file string Absolute path to the file/directory
---@field text string Display text
---@field dir boolean Whether this is a directory
---@field hidden boolean Whether this is a hidden file/directory
---@field size number File size in bytes
---@field mtime number Last modified time
---@field type string File type (file, directory, symlink)

---Check if a path is a directory
---@param path string
---@return boolean
function M.is_directory(path)
  local stat = uv.fs_stat(path)
  return stat and stat.type == "directory" or false
end

---Check if a file is hidden (starts with .)
---@param name string
---@return boolean
function M.is_hidden(name)
  return name:sub(1, 1) == "."
end

---Bitwise AND operation (fallback if bit module not available)
---@param a number
---@param b number
---@return number
local function band(a, b)
  if bit and bit.band then
    return bit.band(a, b)
  end
  -- Fallback implementation
  local result = 0
  local bit_value = 1
  while a > 0 or b > 0 do
    if (a % 2) == 1 and (b % 2) == 1 then
      result = result + bit_value
    end
    a = math.floor(a / 2)
    b = math.floor(b / 2)
    bit_value = bit_value * 2
  end
  return result
end

---Format file permissions from mode
---@param mode number File mode from uv.fs_stat
---@return string
function M.format_permissions(mode)
  if not mode then
    return "----------"
  end

  local perms = ""

  -- File type - properly mask to get just file type bits
  local file_type = band(mode, 0xF000)
  if file_type == 0x4000 then
    perms = "d" -- directory
  elseif file_type == 0xA000 then
    perms = "l" -- symlink
  else
    perms = "." -- regular file (using '.' instead of '-')
  end

  -- Owner permissions
  perms = perms .. (band(mode, 0x100) ~= 0 and "r" or "-")
  perms = perms .. (band(mode, 0x80) ~= 0 and "w" or "-")
  perms = perms .. (band(mode, 0x40) ~= 0 and "x" or "-")

  -- Group permissions
  perms = perms .. (band(mode, 0x20) ~= 0 and "r" or "-")
  perms = perms .. (band(mode, 0x10) ~= 0 and "w" or "-")
  perms = perms .. (band(mode, 0x8) ~= 0 and "x" or "-")

  -- Other permissions
  perms = perms .. (band(mode, 0x4) ~= 0 and "r" or "-")
  perms = perms .. (band(mode, 0x2) ~= 0 and "w" or "-")
  perms = perms .. (band(mode, 0x1) ~= 0 and "x" or "-")

  return perms
end

---Format file size in human readable format
---@param size number Size in bytes
---@param format? "auto"|"bytes" Format type (default: "auto")
---@return string
function M.format_size(size, format)
  if not size then
    return "0"
  end

  format = format or "auto"

  if format == "bytes" then
    return tostring(size) .. "B"
  end

  -- Auto format (human readable)
  local units = { "B", "K", "M", "G", "T" }
  local unit_idx = 1
  local file_size = size

  while file_size >= 1024 and unit_idx < #units do
    file_size = file_size / 1024
    unit_idx = unit_idx + 1
  end

  if unit_idx == 1 then
    return string.format("%d%s", file_size, units[unit_idx])
  else
    return string.format("%.1f%s", file_size, units[unit_idx])
  end
end

---Format timestamp with customizable format
---@param timestamp number Unix timestamp
---@param format? string Date format string (default: auto-detect)
---@return string
function M.format_timestamp(timestamp, format)
  if not timestamp then
    return ""
  end

  if format then
    -- Use custom format string
    return os.date(format, timestamp)
  end

  -- Default ls -l style behavior
  local now = os.time()
  local diff = now - timestamp

  -- If older than 6 months, show year
  if diff > 6 * 30 * 24 * 3600 then
    return os.date("%b %d  %Y", timestamp)
  else
    return os.date("%b %d %H:%M", timestamp)
  end
end

---Safe dirname function that works in async context
---@param path string
---@return string
function M.safe_dirname(path)
  if path == "/" then
    return "/"
  end
  local parts = {}
  for part in path:gmatch "[^/]+" do
    table.insert(parts, part)
  end
  if #parts <= 1 then
    return "/"
  end
  table.remove(parts) -- Remove last part
  return "/" .. table.concat(parts, "/")
end

---Async directory scanner based on oil.nvim pattern for network filesystem reliability
---@param dir string Directory path
---@param opts table Options
---@param callback function(items: FileBrowserItem[]) Callback with results
function M.scan_directory_async(dir, opts, callback)
  local items = {}
  
  -- Preload git status for this directory if enabled
  if opts.git_status then
    local git = require "filebrowser-picker.git"
    git.preload_status(dir, opts._git_refresh_callback)
  end

  -- Use fs_opendir + fs_readdir like oil.nvim for better network FS support
  uv.fs_opendir(dir, function(open_err, fd)
    if open_err then
      if open_err:match("^ENOENT: no such file or directory") then
        -- If the directory doesn't exist, treat as success with empty results
        return callback({})
      else
        notify.warn("Failed to scan directory: " .. dir .. " (" .. open_err .. ")")
        return callback({})
      end
    end
    
    local function read_entries()
      uv.fs_readdir(fd, function(err, entries)
        if err then
          uv.fs_closedir(fd, function()
            notify.warn("Error reading directory: " .. dir .. " (" .. err .. ")")
            callback(items) -- Return what we have so far
          end)
          return
        elseif entries then
          -- Process entries in parallel with async stat calls
          local pending = #entries
          local function complete_entry()
            pending = pending - 1
            if pending == 0 then
              read_entries() -- Continue reading more entries
            end
          end
          
          for _, entry in ipairs(entries) do
            local name = entry.name
            local entry_type = entry.type
            local path = dir .. "/" .. name
            local hidden = M.is_hidden(name)
            
            -- Skip hidden files if not configured to show them
            if not opts.hidden and hidden then
              complete_entry()
              goto continue
            end
            
            -- Async stat call to avoid blocking on network filesystems
            uv.fs_stat(path, function(stat_err, stat)
              if stat then
                -- Use stat.type as primary source of truth (better for network FS)
                -- For sshfs/network filesystems, uv.fs_readdir() type may be unreliable,
                -- so also check stat.type as fallback
                local is_dir = stat.type == "directory" or entry_type == "directory"
                if not is_dir and entry_type == "link" and opts.follow_symlinks then
                  -- For symlinks, check what they actually point to
                  is_dir = stat.type == "directory"
                end
                
                -- Use stat.type as primary source of truth, with readdir type as fallback
                local actual_type = stat.type or entry_type or "file"
                
                table.insert(items, {
                  file = path,
                  text = name,
                  dir = is_dir,
                  hidden = hidden,
                  size = stat.size or 0,
                  mtime = stat.mtime and stat.mtime.sec or 0,
                  type = actual_type,
                  mode = stat.mode,
                })
              end
              complete_entry()
            end)
            
            ::continue::
          end
        else
          -- Done reading all entries
          uv.fs_closedir(fd, function()
            -- Sort and return final results
            M.sort_items(items, opts)
            callback(items)
          end)
        end
      end)
    end
    
    read_entries()
  end, 10000) -- 10 second timeout like oil.nvim
end

---Scan directory and return items (synchronous version kept for compatibility)
---@param dir string Directory path
---@param opts table Options
---@return FileBrowserItem[]
function M.scan_directory(dir, opts)
  local items = {}
  local handle = uv.fs_scandir(dir)

  -- Preload git status for this directory if enabled
  if opts.git_status then
    local git = require "filebrowser-picker.git"
    git.preload_status(dir, opts._git_refresh_callback)
  end

  if not handle then
    notify.warn("Failed to scan directory: " .. dir)
    return items
  end

  while true do
    local name, type = uv.fs_scandir_next(handle)
    if not name then
      break
    end

    local path = dir .. "/" .. name
    local hidden = M.is_hidden(name)

    -- Skip hidden files if not configured to show them
    if not opts.hidden and hidden then
      goto continue
    end

    local stat = uv.fs_stat(path)
    if stat then
      -- Determine if this is a directory, considering symlinks
      -- For sshfs/network filesystems, uv.fs_scandir_next() type may be unreliable,
      -- so also check stat.type as fallback
      local is_dir = type == "directory" or stat.type == "directory"
      if not is_dir and type == "link" and opts.follow_symlinks then
        -- For symlinks, check what they actually point to
        is_dir = stat.type == "directory"
      end

      -- Use stat.type as primary source of truth, with scandir type as fallback
      local actual_type = stat.type or type or "file"

      table.insert(items, {
        file = path,
        text = name,
        dir = is_dir,
        hidden = hidden,
        size = stat.size or 0,
        mtime = stat.mtime.sec or 0,
        type = actual_type,
        mode = stat.mode,
      })
    end

    ::continue::
  end

  -- Sort items with configurable sort field
  M.sort_items(items, opts)

  return items
end

---Sort file items based on configuration
---@param items FileBrowserItem[] Items to sort
---@param opts table Options containing sort_by and sort_reverse
function M.sort_items(items, opts)
  local sort_by = opts.sort_by or "name"
  local sort_reverse = opts.sort_reverse or false

  table.sort(items, function(a, b)
    -- Always put directories first (consistent regardless of sort_reverse)
    if a.dir and not b.dir then
      return true
    elseif not a.dir and b.dir then
      return false
    end

    -- Both are same type, sort by specified field
    local result
    if sort_by == "size" then
      result = (a.size or 0) < (b.size or 0)
    elseif sort_by == "mtime" then
      result = (a.mtime or 0) < (b.mtime or 0)
    else -- name (default)
      result = a.text:lower() < b.text:lower()
    end

    if sort_reverse then
      return not result
    else
      return result
    end
  end)
end

-- ========================================================================
-- Git Root Caching
-- ========================================================================

---Get git root for a directory with caching
---@param dir string Directory to find git root for
---@return string? Git root path or nil if not in a git repository
function M.get_git_root(dir)
  if not dir or dir == "" then
    return nil
  end

  -- Normalize directory path
  dir = vim.fn.fnamemodify(dir, ":p:h")

  -- Check cache first
  local now = (vim.uv or vim.loop).hrtime() / 1000000 -- ms
  local cached = git_root_cache[dir]
  if cached and (now - cached.timestamp) < cache_expiry then
    return cached.root
  end

  -- Walk up directory tree to find git root (async-safe)
  local uv = vim.uv or vim.loop
  local current = dir
  local git_root = nil

  while current ~= "/" do
    local git_dir = current .. "/.git"
    local stat = uv.fs_stat(git_dir)
    if stat then
      git_root = current
      break
    end
    current = current:match "^(.+)/[^/]*$" or "/"
  end

  -- Cache result (including nil)
  git_root_cache[dir] = { root = git_root, timestamp = now }

  return git_root
end

---Clear git root cache (useful for testing or when git state changes)
function M.clear_git_root_cache()
  git_root_cache = {}
end

---Get initial directory based on current buffer or fallback to cwd
---@param opts_cwd string? Explicit cwd option
---@return string
function M.get_initial_directory(opts_cwd)
  -- If cwd is explicitly provided, use it
  if opts_cwd then
    return opts_cwd
  end

  -- Try to get directory from current buffer
  local current_buf = vim.api.nvim_get_current_buf()
  local buf_name = vim.api.nvim_buf_get_name(current_buf)

  -- Check if buffer has a valid file path (async-safe)
  if buf_name and buf_name ~= "" then
    local uv = vim.uv or vim.loop
    local stat = uv.fs_stat(buf_name)
    if stat and stat.type == "file" then
      local buf_dir = vim.fn.fnamemodify(buf_name, ":p:h")
      -- Ensure the directory exists (async-safe)
      local dir_stat = uv.fs_stat(buf_dir)
      if dir_stat and dir_stat.type == "directory" then
        return buf_dir
      end
    end
  end

  -- Fallback to current working directory
  return vim.fn.getcwd()
end

return M
