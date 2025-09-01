---@class FileBrowserScanner
local M = {}

local uv = vim.uv or vim.loop

---Check if a binary is available (cached for performance)
---@param bin string
---@return boolean
local executable_cache = {}
local function has_executable(bin)
  if executable_cache[bin] == nil then
    executable_cache[bin] = vim.fn.executable(bin) == 1
  end
  return executable_cache[bin]
end

---Spawn a process and stream output line by line
---@param cmd string
---@param args string[]
---@param on_line function(string)
---@param on_exit function(number)?
---@param cwd string? working directory
---@return function cancel function
local function spawn_streaming(cmd, args, on_line, on_exit, cwd)
  local stdout = uv.new_pipe(false)
  local stderr = uv.new_pipe(false)
  local handle

  handle = uv.spawn(cmd, {
    args = args,
    stdio = { nil, stdout, stderr },
    cwd = cwd,
  }, function(code, _)
    stdout:read_stop()
    stderr:read_stop()
    stdout:close()
    stderr:close()
    if handle and not handle:is_closing() then
      handle:close()
    end
    if on_exit then
      on_exit(code)
    end
  end)

  if not handle then
    stdout:close()
    stderr:close()
    if on_exit then
      on_exit(1)
    end
    return function() end
  end

  stdout:read_start(function(err, data)
    if err then
      return
    end
    if data then
      -- Process each line
      for line in data:gmatch "[^\r\n]+" do
        if line and line ~= "" then
          on_line(line)
        end
      end
    end
  end)

  -- Consume stderr to prevent blocking
  stderr:read_start(function() end)

  -- Return cancel function
  return function()
    if handle and not handle:is_closing() then
      handle:kill "sigterm"
    end
  end
end

---Build fd scanner
---@param opts table
---@param roots string[]
---@return function
local function build_fd_scanner(opts, roots)
  local base_args = { "--type", "f", "--color", "never" }

  if opts.hidden then
    table.insert(base_args, "--hidden")
  end

  if opts.follow_symlinks then
    table.insert(base_args, "--follow")
  end

  -- Add max depth limit
  local max_depth = opts.max_depth or 32
  table.insert(base_args, "--max-depth")
  table.insert(base_args, tostring(max_depth))

  -- Add excludes
  local excludes = opts.excludes or {}
  if not opts.respect_gitignore then
    table.insert(base_args, "--no-ignore")
    table.insert(base_args, "--no-ignore-vcs")
  end

  for _, pattern in ipairs(excludes) do
    table.insert(base_args, "--exclude")
    table.insert(base_args, pattern)
  end

  -- Add extra fd args if provided
  if opts.extra_fd_args then
    for _, arg in ipairs(opts.extra_fd_args) do
      table.insert(base_args, arg)
    end
  end

  return function(on_item, on_done)
    local cancelers = {}
    local remaining = #roots
    local finished = false

    for _, root in ipairs(roots) do
      local args = vim.deepcopy(base_args)
      table.insert(args, ".")

      local cancel = spawn_streaming("fd", args, function(line)
        if not finished then
          -- fd outputs relative paths from the root, make them absolute
          local full_path = vim.fs.joinpath(root, line)
          on_item(full_path)
        end
      end, function(code)
        remaining = remaining - 1
        if remaining == 0 and not finished then
          finished = true
          on_done()
        end
      end, root)

      table.insert(cancelers, cancel)
    end

    -- Return overall cancel function
    return function()
      finished = true
      for _, cancel in ipairs(cancelers) do
        cancel()
      end
    end
  end
end

---Build rg scanner
---@param opts table
---@param roots string[]
---@return function
local function build_rg_scanner(opts, roots)
  local base_args = { "--files", "--no-color" }

  if opts.hidden then
    table.insert(base_args, "--hidden")
  end

  if opts.follow_symlinks then
    table.insert(base_args, "--follow")
  end

  -- Add max depth limit  
  local max_depth = opts.max_depth or 32
  table.insert(base_args, "--max-depth")
  table.insert(base_args, tostring(max_depth))

  if not opts.respect_gitignore then
    table.insert(base_args, "--no-ignore")
    table.insert(base_args, "--no-ignore-vcs")
  end

  -- Add extra rg args if provided
  if opts.extra_rg_args then
    for _, arg in ipairs(opts.extra_rg_args) do
      table.insert(base_args, arg)
    end
  end

  return function(on_item, on_done)
    local cancelers = {}
    local remaining = #roots
    local finished = false

    for _, root in ipairs(roots) do
      local args = vim.deepcopy(base_args)
      table.insert(args, ".")

      local cancel = spawn_streaming("rg", args, function(line)
        if not finished then
          -- rg outputs relative paths from the root, make them absolute
          local full_path = vim.fs.joinpath(root, line)
          on_item(full_path)
        end
      end, function(code)
        remaining = remaining - 1
        if remaining == 0 and not finished then
          finished = true
          on_done()
        end
      end, root)

      table.insert(cancelers, cancel)
    end

    return function()
      finished = true
      for _, cancel in ipairs(cancelers) do
        cancel()
      end
    end
  end
end

---Build fallback uv scanner with bounded concurrency
---@param opts table
---@param roots string[]
---@return function
local function build_uv_scanner(opts, roots)
  local MAX_CONCURRENT = 16
  local max_depth = opts.max_depth or 32  -- Default depth limit like fd/rg
  local default_excludes = { ".git", "node_modules", ".venv", "__pycache__", ".DS_Store" }
  local excludes = vim.tbl_extend("force", default_excludes, opts.excludes or {})

  ---Check if path should be excluded
  ---@param path string
  ---@return boolean
  local function should_exclude(path)
    local basename = vim.fs.basename(path)
    for _, pattern in ipairs(excludes) do
      -- Treat plain strings as literal matches; allow regex when user explicitly uses magic chars
      if type(pattern) == "string" then
        local has_magic = pattern:find "[%^%$%(%)%%%.%[%]%*%+%-%?]" ~= nil
        if has_magic then
          -- Treat excludes as literal names by default to avoid regex surprises.
          -- If users want patterns, they can pass a magic pattern themselves.
          if basename:find(pattern, 1, true) then
            return true
          end
        else
          -- Exact name match for common folders like .git, node_modules, etc.
          if basename == pattern then
            return true
          end
        end
      elseif tostring(pattern) and basename:match(tostring(pattern)) then
        return true
      end
    end
    return false
  end

  ---Check if file is hidden
  ---@param name string
  ---@return boolean
  local function is_hidden(name)
    return name:sub(1, 1) == "."
  end

  ---Load gitignore patterns from a directory
  ---@param dir string
  ---@return table
  local function load_gitignore_patterns(dir)
    local patterns = {}
    local gitignore_path = vim.fs.joinpath(dir, ".gitignore")
    
    local stat = uv.fs_stat(gitignore_path)
    if stat and stat.type == "file" then
      local fd = uv.fs_open(gitignore_path, "r", 438) -- 438 = 0666
      if fd then
        local data = uv.fs_read(fd, stat.size, 0)
        uv.fs_close(fd)
        
        if data then
          for line in data:gmatch("[^\r\n]+") do
            line = line:gsub("^%s*", ""):gsub("%s*$", "") -- trim whitespace
            if line ~= "" and not line:match("^#") then
              table.insert(patterns, line)
            end
          end
        end
      end
    end
    
    return patterns
  end

  ---Check if path matches gitignore patterns
  ---@param path string
  ---@param gitignore_patterns table
  ---@return boolean
  local function matches_gitignore(path, gitignore_patterns)
    local name = vim.fs.basename(path)
    for _, pattern in ipairs(gitignore_patterns) do
      -- Simple pattern matching - this is a basic implementation
      if pattern == name or name:match(pattern:gsub("%*", ".*")) then
        return true
      end
    end
    return false
  end

  return function(on_item, on_done)
    -- Initialize queue with depth tracking
    local queue = {}
    for _, root in ipairs(roots) do
      table.insert(queue, { path = root, depth = 0 })
    end
    
    local active = 0
    local finished = false
    local visited = {} -- Track visited paths to prevent infinite loops
    local gitignore_cache = {} -- Cache gitignore patterns per directory

    local function process_directory(dir_entry)
      if finished then
        return
      end
      
      local dir = dir_entry.path
      local depth = dir_entry.depth

      -- Prevent infinite loops with symlinks (async)
      uv.fs_realpath(dir, function(err, real_path)
        real_path = real_path or dir
        if visited[real_path] then
          return
        end
        visited[real_path] = true
        process_directory_impl(dir, depth)
      end)
    end

    local function process_directory_impl(dir, depth)
      if finished then
        return
      end

      -- Load gitignore patterns for this directory if respecting gitignore
      local gitignore_patterns = {}
      if opts.respect_gitignore then
        if not gitignore_cache[dir] then
          gitignore_cache[dir] = load_gitignore_patterns(dir)
        end
        gitignore_patterns = gitignore_cache[dir]
      end

      uv.fs_scandir(dir, function(err, handle)
        active = active - 1

        if not err and handle then
          while true do
            local name, type = uv.fs_scandir_next(handle)
            if not name then
              break
            end

            local full_path = vim.fs.joinpath(dir, name)

            -- Skip hidden files if not requested
            if not opts.hidden and is_hidden(name) then
              goto continue
            end

            -- Skip excluded patterns
            if should_exclude(full_path) then
              goto continue
            end

            -- Skip gitignore patterns if respecting gitignore
            if opts.respect_gitignore and matches_gitignore(full_path, gitignore_patterns) then
              goto continue
            end

            if type == "file" then
              on_item(full_path)
            elseif type == "directory" then
              -- Only add directory to queue if we haven't exceeded max depth
              if depth < max_depth then
                table.insert(queue, { path = full_path, depth = depth + 1 })
              end
            elseif type == "link" and opts.follow_symlinks then
              -- For symlinks, check what they point to (with loop protection) - async
              uv.fs_realpath(full_path, function(real_err, real_target)
                if not real_err and real_target and not visited[real_target] then
                  uv.fs_stat(full_path, function(stat_err, stat)
                    if not stat_err and stat then
                      if stat.type == "file" then
                        on_item(full_path)
                      elseif stat.type == "directory" and depth < max_depth then
                        table.insert(queue, { path = full_path, depth = depth + 1 })
                      end
                    end
                  end)
                end
              end)
            end

            ::continue::
          end
        end

        -- Continue processing without manual scheduling
        if not finished then
          process_next()
        end
      end)
    end

    function process_next()
      if finished then
        return
      end

      -- Process up to MAX_CONCURRENT directories
      while active < MAX_CONCURRENT and #queue > 0 do
        local dir_entry = table.remove(queue, 1)
        active = active + 1
        process_directory(dir_entry)
      end

      -- Check if we're done
      if active == 0 and #queue == 0 and not finished then
        finished = true
        on_done()
      end
    end

    -- Start processing immediately
    process_next()

    -- Return cancel function
    return function()
      finished = true
    end
  end
end

---Build the appropriate scanner based on available tools and options
---@param opts table
---@param roots string[]
---@return function scanner function that takes (on_item, on_done) and returns cancel function
function M.build_scanner(opts, roots)
  -- Default options
  opts = vim.tbl_extend("keep", opts or {}, {
    hidden = false,
    follow_symlinks = false,
    respect_gitignore = true,
    use_fd = true,
    use_rg = true,
    excludes = {},
    git_status = false,
  })

  -- Preload git status for all roots if enabled
  if opts.git_status then
    local git = require "filebrowser-picker.git"
    for _, root in ipairs(roots) do
      git.preload_status(root, opts._git_refresh_callback)
    end
  end

  -- Scanner selection priority: fd > rg > uv
  -- All scanners have good performance - fd/rg offer additional features
  if opts.use_fd and has_executable "fd" then
    return build_fd_scanner(opts, roots)
  elseif opts.use_rg and has_executable "rg" then
    return build_rg_scanner(opts, roots)
  else
    return build_uv_scanner(opts, roots)
  end
end

return M
