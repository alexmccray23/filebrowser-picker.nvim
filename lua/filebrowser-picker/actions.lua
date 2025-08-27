local M = {}

local uv = vim.uv or vim.loop
local util = require("filebrowser-picker.util")
local scanner = require("filebrowser-picker.scanner")

---@class FileBrowserItem
---@field file string Absolute path to the file/directory
---@field text string Display text
---@field dir boolean Whether this is a directory
---@field hidden boolean Whether this is a hidden file/directory
---@field size number File size in bytes
---@field mtime number Last modified time
---@field type string File type (file, directory, symlink)

---Create finder for directory browsing (current behavior)
---@param opts table
---@param ctx table
---@return function
function M.create_directory_finder(opts, ctx)
	return function(cb)
		local cwd = ctx.picker:cwd()
		local config = opts or {}
		local items = util.scan_directory(cwd, config)

		-- Add parent directory entry if not at root
		-- Get home directory safely (expand ~ outside of async context)
		local home_dir = (os.getenv("HOME") or "/home/") .. (os.getenv("USER") or "user")
		if cwd ~= "/" and cwd ~= home_dir then
			table.insert(items, 1, {
				file = util.safe_dirname(cwd),
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

---Create finder for fast file discovery across roots
---@param opts table
---@param roots string[]
---@param ctx table
---@return function
function M.create_file_finder(opts, roots, ctx)
	return function(cb)
		local config = opts or {}
		local scan_opts = {
			hidden = config.hidden,
			follow_symlinks = config.follow_symlinks,
			respect_gitignore = config.respect_gitignore,
			use_fd = config.use_fd,
			use_rg = config.use_rg,
			excludes = config.excludes,
		}

		local scan_fn = scanner.build_scanner(scan_opts, roots)
		local item_count = 0
		local batch_size = 100

		local cancel_scan = scan_fn(function(file_path)
			-- Create file item
			local basename = vim.fs.basename(file_path)
			local stat = uv.fs_stat(file_path)

			cb({
				file = file_path,
				text = basename,
				dir = false,
				hidden = basename:sub(1, 1) == ".",
				size = stat and stat.size or 0,
				mtime = stat and stat.mtime and stat.mtime.sec or 0,
				type = "file",
			})

			-- Batch updates for performance
			item_count = item_count + 1
			if item_count % batch_size == 0 then
				-- Allow UI to update
				vim.schedule(function() end)
			end
		end, function()
			-- Scan complete
		end)

		-- Store cancel function on context for cleanup
		if ctx and ctx.picker then
			ctx.picker._cancel_scan = cancel_scan
		end
	end
end

---Create the finder function for snacks picker (adaptive)
---@param opts table
---@param ctx table
---@return function
function M.create_finder(opts, ctx)
	-- Use file finder if we have multiple roots or fast discovery is enabled
	local use_file_finder = opts.use_file_finder or (opts._roots and #opts._roots > 1)

	if use_file_finder and opts._roots then
		return M.create_file_finder(opts, opts._roots, ctx)
	else
		return M.create_directory_finder(opts, ctx)
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
		icon = opts.icons.folder_closed
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
	if not util.is_directory(path) then
		vim.schedule(function()
			vim.notify("Not a directory: " .. path, vim.log.levels.WARN)
		end)
		return
	end

	-- Change picker's working directory (following snacks explorer pattern)
	picker:set_cwd(path)

	-- Update the picker title to show current path
	picker.title = path
	picker:update_titles()

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
function M.confirm(picker, item)
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

---Action: Conditional backspace - goto parent if prompt empty, otherwise backspace
---@param picker any
function M.conditional_backspace(picker)
	if picker.input:get() == "" then
		M.goto_parent(picker)
	else
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<BS>", true, false, true), "tn", false)
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

	if current ~= nil then
		local parent = util.safe_dirname(current)

		if parent and parent ~= current then
			navigate_to_directory(picker, parent)
		end
	end
end

---Action: Go to home directory
---@param picker any
function M.goto_home(picker)
	local home_dir = os.getenv("HOME") or ("/home/" .. (os.getenv("USER") or "user"))
	navigate_to_directory(picker, home_dir)
end

---Action: Go to current working directory
---@param picker any
function M.goto_cwd(picker)
	-- Use libuv to get cwd safely in async context
	local cwd = uv.cwd()
	if cwd ~= nil then
		navigate_to_directory(picker, cwd)
	end
end

---Action: Go to project root (git root)
---@param picker any
function M.goto_project_root(picker)
	-- Try to find git root
	local current_dir = picker:cwd() or uv.cwd()

	-- Walk up the directory tree looking for .git
	local function find_git_root(path)
		while path and path ~= "/" do
			if vim.fn.isdirectory(path .. "/.git") == 1 then
				return path
			end
			path = util.safe_dirname(path)
		end
		return nil
	end

	local git_root = find_git_root(current_dir)
	if git_root then
		navigate_to_directory(picker, git_root)
	else
		vim.schedule(function()
			vim.notify("No git repository found", vim.log.levels.WARN)
		end)
	end
end

---Action: Go to previous directory (stored in history)
---@param picker any
function M.goto_previous_dir(picker)
	-- Simple implementation - could be enhanced with full history stack
	local current_dir = picker:cwd()
	if current_dir then
		local parent = util.safe_dirname(current_dir)
		if parent and parent ~= current_dir then
			navigate_to_directory(picker, parent)
		end
	end
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

---Action: Rename selected file (using Snacks' LSP-aware rename)
---@param picker any
---@param item? FileBrowserItem
function M.rename(picker, item)
	if not item then
		return
	end

	Snacks.rename.rename_file({
		from = item.file,
		on_rename = function(new_path, old_path, ok)
			if ok then
				-- Refresh picker after successful rename
				picker:find({ refresh = true })
			end
		end,
	})
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
	}, function(_, idx)
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

---Action: Set current working directory to displayed directory
---@param picker any
function M.set_pwd(picker)
	local current_dir = picker:cwd()
	if current_dir then
		vim.cmd("cd " .. vim.fn.fnameescape(current_dir))
		vim.notify("Set working directory to: " .. current_dir)
	end
end

---Action: Cycle through multiple roots
---@param picker any
function M.cycle_roots(picker)
	-- This will be implemented by the picker configuration
	-- The actual implementation is in init.lua where roots are managed
end

---Get all actions for picker configuration
---@return table
function M.get_actions()
	return {
		confirm = function(picker, item)
			M.confirm(picker, item)
		end,
		conditional_backspace = M.conditional_backspace,
		goto_parent = M.goto_parent,
		goto_home = M.goto_home,
		goto_cwd = M.goto_cwd,
		goto_project_root = M.goto_project_root,
		goto_previous_dir = M.goto_previous_dir,
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
		set_pwd = M.set_pwd,
		cycle_roots = M.cycle_roots,
	}
end

---Convert keymap table to snacks picker format
---@param keymaps table<string, string>
---@return table
function M.get_keymaps(keymaps)
	local result = {}
	for key, action in pairs(keymaps) do
		result[key] = { action, mode = { "n", "i" } }
	end
	return result
end

return M
