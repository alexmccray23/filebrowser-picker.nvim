---@class filebrowser-picker.util
local M = {}

local uv = vim.uv or vim.loop

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
			local Icons = require("nvim-web-devicons")
			if cat == "filetype" then
				return Icons.get_icon_by_filetype(name, { default = false })
			elseif cat == "file" then
				local ext = name:match("%.(%w+)$")
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

---Safe dirname function that works in async context
---@param path string
---@return string
function M.safe_dirname(path)
	if path == "/" then
		return "/"
	end
	local parts = {}
	for part in path:gmatch("[^/]+") do
		table.insert(parts, part)
	end
	if #parts <= 1 then
		return "/"
	end
	table.remove(parts) -- Remove last part
	return "/" .. table.concat(parts, "/")
end

---Scan directory and return items
---@param dir string Directory path
---@param opts table Options
---@return FileBrowserItem[]
function M.scan_directory(dir, opts)
	local items = {}
	local handle = uv.fs_scandir(dir)

	if not handle then
		vim.notify("Failed to scan directory: " .. dir, vim.log.levels.WARN)
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
			local is_dir = type == "directory"
			if not is_dir and type == "link" and opts.follow_symlinks then
				-- For symlinks, check what they actually point to
				is_dir = stat.type == "directory"
			end

			table.insert(items, {
				file = path,
				text = name,
				dir = is_dir,
				hidden = hidden,
				size = stat.size or 0,
				mtime = stat.mtime.sec or 0,
				type = type or "file",
			})
		end

		::continue::
	end

	-- Sort items: directories first, then files, alphabetically
	table.sort(items, function(a, b)
		if a.dir and not b.dir then
			return true
		elseif not a.dir and b.dir then
			return false
		else
			return a.text:lower() < b.text:lower()
		end
	end)

	return items
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
	local now = vim.uv.hrtime() / 1000000 -- Convert to milliseconds
	local cached = git_root_cache[dir]
	if cached and (now - cached.timestamp) < cache_expiry then
		return cached.root
	end

	-- Find git root
	local git_root =
		vim.fn.system("git -C " .. vim.fn.shellescape(dir) .. " rev-parse --show-toplevel 2>/dev/null"):gsub("\n", "")

	-- Validate result
	if vim.fn.isdirectory(git_root) ~= 1 then
		git_root = nil
	end

	-- Cache result (including nil results to avoid repeated failed lookups)
	git_root_cache[dir] = {
		root = git_root,
		timestamp = now,
	}

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

	-- Check if buffer has a valid file path
	if buf_name and buf_name ~= "" and vim.fn.filereadable(buf_name) == 1 then
		local buf_dir = vim.fn.fnamemodify(buf_name, ":p:h")
		-- Ensure the directory exists
		if vim.fn.isdirectory(buf_dir) == 1 then
			return buf_dir
		end
	end

	-- Fallback to current working directory
	return vim.fn.getcwd()
end

return M
