local M = {}

local uv = vim.uv or vim.loop
local util = require("filebrowser-picker.util")

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
local function is_directory(path)
	local stat = uv.fs_stat(path)
	return stat and stat.type == "directory" or false
end

---Check if a file is hidden (starts with .)
---@param name string
---@return boolean
local function is_hidden(name)
	return name:sub(1, 1) == "."
end

---Scan directory and return items
---@param dir string Directory path
---@param opts table Options
---@return FileBrowserItem[]
local function scan_directory(dir, opts)
	local items = {}
	local handle = uv.fs_scandir(dir)

	if not handle then
		return items
	end

	while true do
		local name, type = uv.fs_scandir_next(handle)
		if not name then
			break
		end

		local path = dir .. "/" .. name
		local hidden = is_hidden(name)

		-- Skip hidden files if not configured to show them
		if not opts.hidden and hidden then
			goto continue
		end

		local stat = uv.fs_stat(path)
		if stat then
			table.insert(items, {
				file = path,
				text = name,
				dir = type == "directory",
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

---Safe dirname function that works in async context
---@param path string
---@return string
local function safe_dirname(path)
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

---Create the finder function for snacks picker
---@param opts table
---@param ctx table
---@return function
function M.create_finder(opts, ctx)
	return function(cb)
		local cwd = ctx.picker:cwd()
		local config = opts or {}
		local items = scan_directory(cwd, config)

		-- Add parent directory entry if not at root
		-- Get home directory safely (expand ~ outside of async context)
		local home_dir = (os.getenv("HOME") or "/home/") .. (os.getenv("USER") or "user")
		if cwd ~= "/" and cwd ~= home_dir then
			table.insert(items, 1, {
				file = safe_dirname(cwd),
				text = "../",
				dir = true,
				hidden = false,
				size = 0,
				mtime = 0,
				type = "directory",
			})
		end

		for _, item in ipairs(items) do
			cb(item)
		end
	end
end

---Format item for display in picker
---@param item FileBrowserItem
---@param opts table
---@return table
function M.format_item(item, opts)
	local icon, icon_hl = "", nil
	local text_hl = "Normal"

	if item.dir then
		icon = item.open and opts.icons.folder_open or opts.icons.folder_closed
		icon_hl = "Directory"
		text_hl = "Directory" -- Keep directory name highlighted
	elseif item.type == "link" then
		icon = opts.icons.symlink
		icon_hl = "Special"
		text_hl = "Normal" -- Symlink filename stays normal
	else
		-- Use icon library for files with color support
		icon, icon_hl = util.icon(item.text, "file", { fallback = { file = opts.icons.file } })
		text_hl = "Normal" -- File name stays normal, only icon is colored
	end

	-- Add space after icon for proper spacing
	icon = icon .. " "

	return {
		{ icon, icon_hl or "Normal" },
		{ item.text, text_hl },
	}
end

---Safe path normalization for async context
---@param path string
---@return string
local function safe_normalize_path(path)
	-- Simple path normalization without vim.fs functions
	path = path:gsub("/+", "/") -- Replace multiple slashes with single
	path = path:gsub("/$", "") -- Remove trailing slash
	if path == "" then
		path = "/"
	end
	return path
end

---Navigate to a new directory
---@param picker any
---@param path string
local function navigate_to_directory(picker, path)
	-- Normalize the path safely
	path = safe_normalize_path(path)

	-- Ensure directory exists
	if not is_directory(path) then
		vim.schedule(function()
			vim.notify("Not a directory: " .. path, vim.log.levels.WARN)
		end)
		return
	end

	-- Change picker's working directory (following snacks explorer pattern)
	picker:set_cwd(path)

	-- Clear any search pattern to show directory contents
	picker.input:set("", "")

	-- Refresh the picker
	picker:find({
		on_done = function()
			-- Focus on first item
			picker.list:view(1)
		end,
	})
end

---Action: Confirm/Open selected item
---@param picker any
---@param item FileBrowserItem
---@param opts table
function M.confirm(picker, item, opts)
	if not item then
		return
	end

	if item.dir then
		-- Navigate to directory
		navigate_to_directory(picker, item.file)
	else
		-- Open file and close picker
		picker:close()
		vim.cmd("edit " .. vim.fn.fnameescape(item.file))
	end
end

---Action: Go to parent directory
---@param picker any
function M.goto_parent(picker)
	-- Try multiple ways to get current directory
	local current = nil
	if picker and picker.cwd then
		current = picker:cwd()
	elseif picker and picker.dir then
		current = picker:dir()
	elseif picker and picker.input and picker.input.filter then
		current = picker.input.filter.cwd
	end

	-- Fallback to system cwd
	current = current or uv.cwd()

	local parent = safe_dirname(current)

	if parent and parent ~= current then
		navigate_to_directory(picker, parent)
	end
end

---Action: Go to home directory
---@param picker any
function M.goto_home(picker)
	local home_dir = os.getenv("HOME") or "/home/" .. (os.getenv("USER") or "user")
	navigate_to_directory(picker, home_dir)
end

---Action: Go to current working directory
---@param picker any
function M.goto_cwd(picker)
	-- Use libuv to get cwd safely in async context
	local cwd = uv.cwd()
	navigate_to_directory(picker, cwd)
end

---Action: Change to selected directory
---@param picker any
---@param item? FileBrowserItem
function M.change_directory(picker, item)
	local target_dir

	if item and item.dir then
		target_dir = item.file
	else
		-- If no item or item is not a directory, use current picker directory
		target_dir = picker:dir()
	end

	navigate_to_directory(picker, target_dir)
end

---Action: Toggle hidden files visibility
---@param picker any
function M.toggle_hidden(picker)
	-- This would need to be implemented by modifying the finder
	-- For now, just refresh
	picker:find({ refresh = true })
end

---Action: Create new file/directory
---@param picker any
function M.create_file(picker)
	vim.ui.input({ prompt = "Create: " }, function(name)
		if not name or name == "" then
			return
		end

		local cwd = picker:cwd()
		local path = cwd .. "/" .. name

		if name:sub(-1) == "/" then
			-- Create directory
			local dir_path = path:sub(1, -2)
			vim.fn.mkdir(dir_path, "p")
			vim.notify("Created directory: " .. dir_path)
		else
			-- Create file
			local file = io.open(path, "w")
			if file then
				file:close()
				vim.notify("Created file: " .. path)
			else
				vim.notify("Failed to create file: " .. path, vim.log.levels.ERROR)
			end
		end

		-- Refresh picker
		picker:find({ refresh = true })
	end)
end

---Action: Rename selected file
---@param picker any
---@param item? FileBrowserItem
function M.rename(picker, item)
	if not item then
		return
	end

	vim.ui.input({
		prompt = "Rename to: ",
		default = item.text,
	}, function(new_name)
		if not new_name or new_name == "" or new_name == item.text then
			return
		end

		local old_path = item.file
		local new_path = safe_dirname(old_path) .. "/" .. new_name

		local ok, err = os.rename(old_path, new_path)
		if ok then
			vim.notify("Renamed: " .. item.text .. " -> " .. new_name)
			picker:find({ refresh = true })
		else
			vim.notify("Failed to rename: " .. (err or "unknown error"), vim.log.levels.ERROR)
		end
	end)
end

---Action: Move selected file
---@param picker any
---@param item? FileBrowserItem
function M.move(picker, item)
	if not item then
		return
	end

	vim.ui.input({
		prompt = "Move to: ",
		default = picker:cwd() .. "/",
	}, function(dest_path)
		if not dest_path or dest_path == "" then
			return
		end

		local ok, err = os.rename(item.file, dest_path)
		if ok then
			vim.notify("Moved: " .. item.text .. " -> " .. dest_path)
			picker:find({ refresh = true })
		else
			vim.notify("Failed to move: " .. (err or "unknown error"), vim.log.levels.ERROR)
		end
	end)
end

---Action: Copy selected file
---@param picker any
---@param item? FileBrowserItem
function M.copy(picker, item)
	if not item then
		return
	end

	vim.ui.input({
		prompt = "Copy to: ",
		default = picker:cwd() .. "/" .. item.text,
	}, function(dest_path)
		if not dest_path or dest_path == "" then
			return
		end

		-- Simple file copy (doesn't handle directories recursively)
		local cmd = string.format("cp %s %s", vim.fn.shellescape(item.file), vim.fn.shellescape(dest_path))

		local result = vim.fn.system(cmd)
		if vim.v.shell_error == 0 then
			vim.notify("Copied: " .. item.text .. " -> " .. dest_path)
			picker:find({ refresh = true })
		else
			vim.notify("Failed to copy: " .. result, vim.log.levels.ERROR)
		end
	end)
end

---Action: Delete selected file
---@param picker any
---@param item? FileBrowserItem
function M.delete(picker, item)
	if not item then
		return
	end

	vim.ui.select({ "No", "Yes" }, {
		prompt = "Delete " .. item.text .. "?",
	}, function(choice, idx)
		if idx ~= 2 then
			return
		end

		local ok, err
		if item.dir then
			ok, err = os.remove(item.file)
		else
			ok, err = os.remove(item.file)
		end

		if ok then
			vim.notify("Deleted: " .. item.text)
			picker:find({ refresh = true })
		else
			vim.notify("Failed to delete: " .. (err or "unknown error"), vim.log.levels.ERROR)
		end
	end)
end

---Action: Edit file in vertical split
---@param picker any
---@param item? FileBrowserItem
function M.edit_vsplit(picker, item)
	if not item or item.dir then
		return
	end

	picker:close()
	vim.cmd("vsplit " .. vim.fn.fnameescape(item.file))
end

---Action: Edit file in horizontal split
---@param picker any
---@param item? FileBrowserItem
function M.edit_split(picker, item)
	if not item or item.dir then
		return
	end

	picker:close()
	vim.cmd("split " .. vim.fn.fnameescape(item.file))
end

---Action: Edit file in new tab
---@param picker any
---@param item? FileBrowserItem
function M.edit_tab(picker, item)
	if not item or item.dir then
		return
	end

	picker:close()
	vim.cmd("tabedit " .. vim.fn.fnameescape(item.file))
end

---Get all actions for picker configuration
---@param opts table
---@return table
function M.get_actions(opts)
	return {
		confirm = function(picker, item)
			M.confirm(picker, item, opts)
		end,
		goto_parent = M.goto_parent,
		goto_home = M.goto_home,
		goto_cwd = M.goto_cwd,
		change_directory = M.change_directory,
		toggle_hidden = M.toggle_hidden,
		create_file = M.create_file,
		rename = M.rename,
		move = M.move,
		copy = M.copy,
		delete = M.delete,
		edit_vsplit = M.edit_vsplit,
		edit_split = M.edit_split,
		edit_tab = M.edit_tab,
	}
end

---Convert keymap table to snacks picker format
---@param keymaps table<string, string>
---@return table
function M.get_keymaps(keymaps)
	local result = {}
	for key, action in pairs(keymaps) do
		if key == "<BS>" then
			-- Backspace only works in normal mode for now (reliable parent navigation)
			result[key] = { action, mode = { "n" } }
		else
			result[key] = { action, mode = { "n", "i" } }
		end
	end
	return result
end

return M
