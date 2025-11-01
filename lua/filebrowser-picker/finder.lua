---@class filebrowser-picker.finder
local M = {}

local util = require "filebrowser-picker.util"
local scanner = require "filebrowser-picker.scanner"
local actions = require "filebrowser-picker.actions"

---UI selection helper that works with or without Snacks.select
---@param items string[] Items to select from
---@param prompt? string Selection prompt
---@param callback function Callback function
local function ui_select(items, prompt, callback)
  local ok, Snacks = pcall(require, "snacks")
  if ok and Snacks.picker and Snacks.picker.select then
    return Snacks.picker.select(items, { prompt = prompt or "Select" }, callback)
  end
  vim.ui.select(items, { prompt = prompt or "Select" }, callback)
end

---Start file scanner for file finder mode
---@param opts table Configuration options
---@param state table Multi-root state
---@param ctx table Picker context
---@param setup_git_callback? boolean Whether to set up git refresh callback (skip on initial call)
---@return table?, function?, string[]? items, cancel_function, scan_roots
function M.start_scanner(opts, state, ctx, setup_git_callback)
  if not opts.use_file_finder then
    return nil, nil, nil
  end

  local scan_opts = {
    hidden = opts.hidden,
    follow_symlinks = opts.follow_symlinks,
    respect_gitignore = opts.respect_gitignore,
    use_fd = opts.use_fd,
    use_rg = opts.use_rg,
    excludes = opts.excludes,
    git_status = opts.git_status,
  }

  -- Add refresh callback for git status updates in file finder mode only on non-initial calls
  -- During initial call, git status will preload silently without triggering picker:refresh()
  if setup_git_callback and opts.git_status and ctx and ctx.picker then
    scan_opts._git_refresh_callback = function()
      if ctx.picker and not ctx.picker.closed and ctx.picker.refresh then
        ctx.picker:refresh()
      end
    end
  end

  -- Determine roots to scan
  local scan_roots
  if #state.roots > 1 and (opts.search_all_roots ~= false) then
    scan_roots = state.roots
  else
    scan_roots = { state.roots[state.idx] }
  end

  local list = {} -- items table returned to Snacks
  local scan_fn = scanner.build_scanner(scan_opts, scan_roots)

  local cancel = scan_fn(function(file_path)
    local name = vim.fs.basename(file_path)
    local item = {
      file = file_path,
      text = name,
      dir = false,
      hidden = name:sub(1, 1) == ".",
      size = 0,
      mtime = 0,
      type = "file",
    }

    -- Add item immediately for fast display
    list[#list + 1] = item

    -- Asynchronously get stat info if detailed view is enabled
    if current_opts.detailed_view then
      local uv = vim.uv or vim.loop
      uv.fs_stat(file_path, function(err, st)
        if not err and st then
          item.size = st.size or 0
          item.mtime = st.mtime and st.mtime.sec or 0
        end
      end)
    end
  end)

  return list, cancel, scan_roots
end

---Read directory contents for directory browser mode
---@param cwd string Current working directory
---@param opts table Configuration options
---@return table[] Directory items
function M.read_directory(cwd, opts)
  local items = util.scan_directory(cwd, opts)

  -- Add "../" entry unless at filesystem root
  local parent = util.safe_dirname(cwd)
  if parent and parent ~= cwd then
    -- Get actual stat info for parent directory
    local uv = vim.uv or vim.loop
    local stat = uv.fs_stat(parent)
    local parent_mtime = stat and stat.mtime and stat.mtime.sec or 0
    local parent_size = stat and stat.size or 0

    table.insert(items, 1, {
      file = parent,
      text = "../",
      dir = true,
      hidden = false,
      size = parent_size,
      mtime = parent_mtime,
      type = "directory",
    })
  end

  return items
end

---Create finder function for snacks picker
---@param opts table Configuration options
---@param state table Multi-root state
---@return function Finder function
function M.create_finder(opts, state)
  local is_initial_call = true

  return function(_, ctx)
    -- Merge static and dynamic ctx.picer.opts to enable git signs rendering
    local current_opts = opts
    if ctx and ctx.picker and ctx.picker.opts then
      current_opts = vim.tbl_deep_extend("keep", ctx.picker.opts, opts)
    end

    -- Only set git refresh callback on non-initial calls to avoid stack overflow during picker init
    -- During initial call, git status will preload silently without triggering picker:refresh()
    -- which avoids the snacks.nvim stack overflow issue with update_titles
    local setup_git_callback = not is_initial_call
    is_initial_call = false

    -- Always rebuild scanner on (re)invoke so it follows state changes
    if opts.use_file_finder then
      local list, cancel = M.start_scanner(current_opts, state, ctx, setup_git_callback)
      if ctx and ctx.picker then
        -- Ensure previous scan is cancelled on re-find or close
        if ctx.picker._fbp_cancel_scan and ctx.picker._fbp_cancel_scan ~= cancel then
          pcall(ctx.picker._fbp_cancel_scan)
        end
        ctx.picker._fbp_cancel_scan = cancel
      end
      return list or {}
    else
      local cwd = (ctx and ctx.picker and ctx.picker:cwd()) or state.roots[state.idx]

      -- Add refresh callback for git status updates only on non-initial calls
      if setup_git_callback and current_opts.git_status and ctx and ctx.picker then
        current_opts._git_refresh_callback = function()
          if ctx.picker and not ctx.picker.closed and ctx.picker.refresh then
            ctx.picker:refresh()
          end
        end
      end

      return M.read_directory(cwd, current_opts)
    end
  end
end

---Create format function for picker items
---@param opts table Configuration options
---@return function Format function
function M.create_format_function(opts)
  return function(item, picker)
    -- Use picker options if available (for dynamic updates like toggle)
    -- Otherwise fall back to the original opts closure
    local active_opts = (picker and picker.opts and picker.opts.opts) or opts
    return actions.format_item(item, active_opts)
  end
end

---Create picker cleanup function
---@return function Cleanup function
function M.create_cleanup_function()
  return function(picker)
    if picker and picker._fbp_cancel_scan then
      pcall(picker._fbp_cancel_scan)
      picker._fbp_cancel_scan = nil
    end

    -- Stop git watchers if any
    pcall(function()
      local git = require "filebrowser-picker.git"
      if picker and picker.opts then
        -- unwatch current cwd
        if picker.opts.cwd then
          local root = util.get_git_root(picker.opts.cwd)
          if root then
            git.unwatch_repo(root)
          end
        end
        -- unwatch provided roots
        if picker.opts._roots then
          for _, r in ipairs(picker.opts._roots) do
            local root = util.get_git_root(r)
            if root then
              git.unwatch_repo(root)
            end
          end
        end
      end
    end)
  end
end

-- Export ui_select for use by other modules
M.ui_select = ui_select

return M
