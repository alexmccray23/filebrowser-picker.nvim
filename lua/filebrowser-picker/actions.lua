local M = {}

local uv = vim.uv or vim.loop
local util = require("filebrowser-picker.util")
local scanner = require("filebrowser-picker.scanner")
local notify = require("filebrowser-picker.notify")
local git = require("filebrowser-picker.git")

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
		local home_dir = (vim.loop.os_homedir()) or ("/home/" .. (os.getenv("USER") or "user"))
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
			git_status = config.git_status,
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
				mode = stat and stat.mode or nil,
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
		icon, icon_hl = util.icon(item.text, "directory", { fallback = { file = opts.icons.folder_closed } })
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

	local result

	-- Format detailed view if enabled
	if opts.detailed_view then
		local stat_module = require("filebrowser-picker.stat")

		-- Use default stats if display_stat is not configured
		local display_stat = opts.display_stat or stat_module.default_stats
		local stat_components = stat_module.build_stat_display(item, display_stat)

		-- Build inline display like telescope-file-browser
		result = {
			{ "  ", "" },
			{ icon, icon_hl or "Normal" },
			{ item.text, text_hl },
		}

		-- Reserve fixed space for stats based on configured widths
		local stat_width = stat_module.calculate_stat_width(display_stat)

		-- Get available window width (approximation - picker window is usually most of the screen)
		local win_width = vim.api.nvim_win_get_width(0)
		local available_width = math.floor(win_width * 0.99) -- Use 99% of window width as safe estimate

		-- Calculate filename display width (icon + space + text)
		local filename_width = #item.text + 2 -- +2 for icon and space

		-- Reserve space for stats + git status + some margin
		local reserved_width = stat_width + 3 -- +3 for git status and margins

		-- Calculate padding to right-align stats within available space
		local max_filename_area = available_width - reserved_width
		local padding_length = math.max(max_filename_area - filename_width, 2) -- Minimum 2 spaces

		-- Ensure we don't go crazy with padding on very wide windows
		padding_length = math.min(padding_length, 80)

		table.insert(result, { string.rep(" ", padding_length), "Normal" })

		-- Add stat components inline
		for _, component in ipairs(stat_components) do
			if type(component) == "table" and component[1] then
				local text = component[1]
				local hl = component[2] or "Comment"

				-- Handle highlight function case (for mode permissions)
				if type(hl) == "function" then
					-- For now, just use the text without complex highlighting
					table.insert(result, { text, "Comment" })
				else
					table.insert(result, { text, hl })
				end
			end
		end

		if opts.git_status then
			local git_status = git.get_status_sync(item.file)
			if git_status then
				local git_icon = opts.icons.git[git_status] or " "
				local git_hl = opts.git_status_hl[git_status] or "Normal"

				if git_status == "staged" then
					git_icon = opts.icons.git.staged
				end

				if git_icon and git_icon ~= "" then
					result[1] = { (git_icon .. " "), git_hl }
				end
			end
		end
	else
		-- Normal view
		result = {
			{ "  ", "" },
			{ icon, icon_hl or "Normal" },
			{ item.text, text_hl },
		}

		if opts.git_status then
			local git_status = git.get_status_sync(item.file)
			if git_status then
				local git_icon = opts.icons.git[git_status] or " "
				local git_hl = opts.git_status_hl[git_status] or "Normal"

				if git_status == "staged" then
					git_icon = opts.icons.git.staged
				end

				if git_icon and git_icon ~= "" then
					result[1] = { (git_icon .. " "), git_hl }
				end
			end
		end
	end

	return result
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

---Navigate to a new directory with state management
---@param picker any
---@param path string
---@param state? table Optional state object for previous directory tracking
---@param update_title? boolean Whether to update title (default: true)
local function navigate_to_directory(picker, path, state, update_title)
	-- Default update_title to true for backward compatibility
	if update_title == nil then
		update_title = true
	end

	-- Normalize the path safely
	path = safe_normalize_path(path)

	-- Ensure directory exists
	if not util.is_directory(path) then
		notify.warn("Not a directory: " .. path)
		return false
	end

	-- Update previous directory state before navigation
	if state then
		state.prev_dir = picker:cwd()
	end

	-- Change picker's working directory (following snacks explorer pattern)
	picker:set_cwd(path)

	-- Update the picker title if requested (let caller handle complex titles)
	if update_title then
		picker.title = path
		picker:update_titles()
	end

	-- Clear any search pattern to show directory contents
	picker.input:set("", "")

	-- Refresh the picker
	picker:find({
		on_done = function()
			-- Focus on first item
			picker.list:view(1)
		end,
	})

	return true
end

---Action: Confirm/Open selected item
---@param picker any
---@param item FileBrowserItem
function M.confirm(picker, item)
	if not item then
		return
	end

	-- Check if this should be treated as a directory
	local is_directory = item.dir

	-- For symlinks, also check if they point to directories (when follow_symlinks is enabled)
	if not is_directory and item.type == "link" then
		local picker_opts = (picker and picker.opts) or {}
		if picker_opts.follow_symlinks then
			local stat = uv.fs_stat(item.file)
			is_directory = stat and stat.type == "directory"
		end
	end

	if is_directory then
		-- Navigate to directory (without state management for backward compatibility)
		navigate_to_directory(picker, item.file)
	else
		-- Open file and close picker
		picker:close()
		vim.cmd("edit " .. vim.fn.fnameescape(item.file))
	end
end

---Action: Confirm/Open selected item with state management
---@param picker any
---@param item FileBrowserItem
---@param state table Multi-root state for previous directory tracking
function M.confirm_with_state(picker, item, state)
	if not item then
		return
	end

	local is_directory = item.dir

	-- For symlinks, also check if they point to directories (when follow_symlinks is enabled)
	if not is_directory and item.type == "link" then
		local picker_opts = (picker and picker.opts) or {}
		if picker_opts.follow_symlinks then
			-- Synchronously check if the symlink target is a directory
			local target = vim.fn.readlink(item.file)
			if target and target ~= "" then
				-- Construct the full path to the target
				local parent_dir = vim.fn.fnamemodify(item.file, ":h")
				local full_path = vim.fs.normalize(target, { Cwd = parent_dir })
				if vim.fn.isdirectory(full_path) == 1 then
					is_directory = true
				end
			end
		end
	end

	if is_directory then
		-- Navigate to directory with state management
		navigate_to_directory(picker, item.file, state)
	else
		-- Open file and close picker
		picker:close()
		vim.cmd("edit " .. vim.fn.fnameescape(item.file))
	end
end

-- function M.confirm_with_state(picker, item, state)
-- 	if not item then
-- 		return
-- 	end
--
-- 	-- Check if this should be treated as a directory
-- 	local is_directory = item.dir
--
-- 	-- For symlinks, also check if they point to directories (when follow_symlinks is enabled)
-- 	if not is_directory and item.type == "link" then
-- 		local picker_opts = (picker and picker.opts) or {}
-- 		if picker_opts.follow_symlinks then
-- 			local stat = uv.fs_stat(item.file)
-- 			is_directory = stat and stat.type == "directory"
-- 		end
-- 	end
--
-- 	if is_directory then
-- 		-- Navigate to directory with state management
-- 		navigate_to_directory(picker, item.file, state)
-- 	else
-- 		-- Open file and close picker
-- 		picker:close()
-- 		vim.cmd("edit " .. vim.fn.fnameescape(item.file))
-- 	end
-- end

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

---Action: Go to home directory with state management
---@param picker any
---@param state table Multi-root state for previous directory tracking
function M.goto_home_with_state(picker, state)
	local home_dir = os.getenv("HOME") or ("/home/" .. (os.getenv("USER") or "user"))
	navigate_to_directory(picker, home_dir, state, false) -- Let caller handle title updates
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

---Action: Go to current working directory with state management
---@param picker any
---@param state table Multi-root state for previous directory tracking
function M.goto_cwd_with_state(picker, state)
	-- Use libuv to get cwd safely in async context
	local cwd = uv.cwd()
	if cwd ~= nil then
		navigate_to_directory(picker, cwd, state, false) -- Let caller handle title updates
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
			-- Use async-safe directory check
			local uv = vim.uv or vim.loop
			local stat = uv.fs_stat(path .. "/.git")
			if stat and stat.type == "directory" then
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
		notify.warn("No git repository found")
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

---Helper: Validate and normalize creation path
---@param input string User input path
---@param base_dir string Base directory to create relative to
---@return string? normalized_path, string? error_message
local function validate_creation_path(input, base_dir)
	-- Trim whitespace
	input = input:gsub("^%s+", ""):gsub("%s+$", "")

	-- Prevent empty paths
	if input == "" then
		return nil, "Path cannot be empty"
	end

	-- Prevent absolute paths (security)
	if input:sub(1, 1) == "/" then
		return nil, "Absolute paths not allowed"
	end

	-- Normalize path separators and resolve relative components
	local parts = {}
	for part in input:gmatch("[^/]+") do
		if part == ".." then
			if #parts > 0 then
				table.remove(parts)
			else
				return nil, "Cannot escape base directory"
			end
		elseif part ~= "." and part ~= "" then
			table.insert(parts, part)
		end
	end

	if #parts == 0 then
		return nil, "Invalid path"
	end

	-- Construct full path
	local relative_path = table.concat(parts, "/")
	local full_path = base_dir .. "/" .. relative_path

	return full_path, nil
end

---Action: Create new file/directory with intelligent path parsing
---@param picker any
function M.create_file(picker)
	vim.ui.input({
		prompt = "Create (supports nested paths): ",
		default = "",
	}, function(input)
		if not input or input == "" then
			return
		end

		local cwd = picker:cwd()
		local is_directory = input:sub(-1) == "/"

		-- Remove trailing slash for path validation
		local clean_input = is_directory and input:sub(1, -2) or input

		-- Validate and normalize the path
		local target_path, error_msg = validate_creation_path(clean_input, cwd)
		if not target_path then
			notify.invalid_path(clean_input, error_msg)
			return
		end

		local success = false
		local created_items = {}

		if is_directory then
			-- Create directory (with parents)
			local ok, err = pcall(vim.fn.mkdir, target_path, "p")
			if ok then
				success = true
				table.insert(created_items, "directory: " .. target_path)
			else
				notify.error("Failed to create directory: " .. (err or "unknown error"))
				return
			end
		else
			-- Create file (with parent directories if needed)
			local parent_dir = vim.fn.fnamemodify(target_path, ":h")

			-- Create parent directories if they don't exist
			if parent_dir ~= cwd and vim.fn.isdirectory(parent_dir) == 0 then
				local ok, err = pcall(vim.fn.mkdir, parent_dir, "p")
				if ok then
					table.insert(created_items, "directories: " .. parent_dir)
				else
					notify.error("Failed to create parent directories: " .. (err or "unknown error"))
					return
				end
			end

			-- Create the file
			local file = io.open(target_path, "w")
			if file then
				file:close()
				success = true
				table.insert(created_items, "file: " .. target_path)
			else
				notify.error("Failed to create file: " .. target_path)
				return
			end
		end

		-- Report what was created
		if success then
			notify.created(created_items)

			-- Refresh picker
			picker:find({ refresh = true })
		end
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

---Action: Move selected file(s) - supports multi-file selection
---@param picker any
---@param item? FileBrowserItem
function M.move(picker, item)
	-- Get selected files, fallback to current item if no selection
	local selected_items = picker:selected()
	if #selected_items == 0 and item then
		selected_items = { item }
	end

	if #selected_items == 0 then
		notify.no_selection("move")
		return
	end

	-- If we have multiple files, move them all to current directory
	if #selected_items > 1 then
		local target_dir = picker:cwd()
		local what = #selected_items .. " files"
		local target_display = vim.fn.fnamemodify(target_dir, ":~:.")

		-- Confirm multi-file move
		vim.ui.select({ "No", "Yes" }, {
			prompt = "Move " .. what .. " to " .. target_display .. "?",
		}, function(_, idx)
			if idx ~= 2 then
				return
			end

			local moved_count = 0
			local errors = {}

			-- Move each file
			for _, itm in ipairs(selected_items) do
				local from = itm.file
				local name = vim.fn.fnamemodify(from, ":t")
				local to = target_dir .. "/" .. name

				-- Check if destination already exists
				if vim.fn.filereadable(to) == 1 or vim.fn.isdirectory(to) == 1 then
					table.insert(errors, "Destination exists: " .. name)
				else
					-- Use Snacks rename if available, fallback to os.rename
					local ok, err = pcall(function()
						local Snacks = require("snacks")
						if Snacks.rename and Snacks.rename.rename_file then
							Snacks.rename.rename_file({ from = from, to = to })
						else
							local success = os.rename(from, to)
							if not success then
								error("Move failed")
							end
						end
					end)

					if ok then
						moved_count = moved_count + 1
					else
						table.insert(errors, name .. ": " .. (err or "unknown error"))
					end
				end
			end

			-- Clear selection and refresh
			picker.list:set_selected()
			picker:find({ refresh = true })

			-- Report results
			notify.operation_result("moved", moved_count, #selected_items, #errors > 0 and errors or nil)
		end)
	else
		-- Single file move - use input for custom destination
		local single_item = selected_items[1]
		vim.ui.input({
			prompt = "Move to: ",
			default = picker:cwd() .. "/" .. single_item.text,
		}, function(dest_path)
			if not dest_path or dest_path == "" then
				return
			end

			-- Check if destination already exists
			if vim.fn.filereadable(dest_path) == 1 or vim.fn.isdirectory(dest_path) == 1 then
				notify.error("Destination already exists: " .. dest_path)
				return
			end

			-- Use Snacks rename if available, fallback to os.rename
			local ok, err = pcall(function()
				local Snacks = require("snacks")
				if Snacks.rename and Snacks.rename.rename_file then
					Snacks.rename.rename_file({ from = single_item.file, to = dest_path })
				else
					local success = os.rename(single_item.file, dest_path)
					if not success then
						error("Move failed")
					end
				end
			end)

			if ok then
				notify.success("Moved: " .. single_item.text .. " -> " .. vim.fn.fnamemodify(dest_path, ":t"))
				picker:find({ refresh = true })
			else
				notify.error("Failed to move: " .. (err or "unknown error"))
			end
		end)
	end
end

---Action: Yank (copy to register) selected files
---@param picker any
function M.yank(picker)
	local selected_items = picker:selected()
	if #selected_items == 0 then
		-- If nothing selected, yank current item
		local current = picker:current()
		if current then
			selected_items = { current }
		end
	end

	if #selected_items == 0 then
		notify.no_selection("yank")
		return
	end

	local paths = vim.tbl_map(function(itm)
		return itm.file
	end, selected_items)
	local value = table.concat(paths, "\n")

	-- Store in default register and clipboard
	vim.fn.setreg(vim.v.register or "+", value, "l")

	-- Clear selection and notify
	picker.list:set_selected()
	local item_word = #selected_items == 1 and "file" or "files"
	notify.success("Yanked " .. #selected_items .. " " .. item_word)
end

---Action: Paste files from register to current directory
---@param picker any
function M.paste(picker)
	local files = vim.split(vim.fn.getreg(vim.v.register or "+") or "", "\n", { plain = true })
	files = vim.tbl_filter(function(file)
		return file ~= "" and (vim.fn.filereadable(file) == 1 or vim.fn.isdirectory(file) == 1)
	end, files)

	if #files == 0 then
		notify.warn("No files in register to paste")
		return
	end

	local target_dir = picker:cwd()
	local what = #files == 1 and vim.fn.fnamemodify(files[1], ":t") or #files .. " files"
	local target_display = vim.fn.fnamemodify(target_dir, ":~:.")

	vim.ui.select({ "No", "Yes" }, {
		prompt = "Paste " .. what .. " to " .. target_display .. "?",
	}, function(_, idx)
		if idx ~= 2 then
			return
		end

		-- Use Snacks utility for reliable copying
		local ok, err = pcall(function()
			local Snacks = require("snacks")
			if Snacks.picker and Snacks.picker.util and Snacks.picker.util.copy then
				Snacks.picker.util.copy(files, target_dir)
			else
				-- Fallback to manual copy
				for _, path in ipairs(files) do
					local name = vim.fn.fnamemodify(path, ":t")
					local dest = target_dir .. "/" .. name
					M._copy_path(path, dest)
				end
			end
		end)

		if ok then
			local item_word = #files == 1 and "file" or "files"
			notify.success("Pasted " .. #files .. " " .. item_word)
			picker:find({ refresh = true })
		else
			notify.error("Failed to paste files: " .. (err or "unknown error"))
		end
	end)
end

---Helper: Check if directory is empty
---@param path string
---@return boolean
local function is_directory_empty(path)
	local handle = uv.fs_scandir(path)
	if not handle then
		return false
	end

	local name = uv.fs_scandir_next(handle)
	return name == nil
end

---Helper: Recursively delete directory using vim.uv
---@param path string
---@return boolean success
---@return string? error
local function delete_directory_recursive(path)
	local handle = uv.fs_scandir(path)
	if not handle then
		return false, "Cannot scan directory"
	end

	-- First delete all contents
	while true do
		local name, type = uv.fs_scandir_next(handle)
		if not name then
			break
		end

		local child_path = path .. "/" .. name
		local success, err

		if type == "directory" then
			-- Recursively delete subdirectories
			success, err = delete_directory_recursive(child_path)
		else
			-- Delete files and other types
			success, err = uv.fs_unlink(child_path)
		end

		if not success then
			return false, err or ("Failed to delete " .. name)
		end
	end

	-- Finally delete the empty directory
	local success, err = uv.fs_rmdir(path)
	return success ~= nil, err
end

---Helper: Delete a single file or directory with enhanced error handling
---@param item FileBrowserItem
---@param force_recursive? boolean Skip confirmation for recursive deletion
---@return boolean success
---@return string? error
local function delete_single_item(item, force_recursive)
	if item.dir then
		-- Handle directory deletion
		if is_directory_empty(item.file) then
			-- Empty directory - use fs_rmdir
			local success, err = uv.fs_rmdir(item.file)
			if success then
				return true
			else
				return false, err or "Failed to remove directory"
			end
		else
			-- Non-empty directory
			if force_recursive then
				return delete_directory_recursive(item.file)
			else
				return false, "Directory not empty (use recursive delete)"
			end
		end
	else
		-- Handle file deletion
		local success, err = uv.fs_unlink(item.file)
		if success then
			return true
		else
			return false, err or "Failed to delete file"
		end
	end
end

---Action: Delete selected file(s) - supports multi-file selection
---@param picker any
---@param item? FileBrowserItem
function M.delete(picker, item)
	-- Get selected files, fallback to current item if no selection
	local selected_items = picker:selected()
	if #selected_items == 0 and item then
		selected_items = { item }
	end

	if #selected_items == 0 then
		notify.no_selection("delete")
		return
	end

	-- Check for non-empty directories that need recursive deletion
	local non_empty_dirs = {}
	for _, itm in ipairs(selected_items) do
		if itm.dir and not is_directory_empty(itm.file) then
			table.insert(non_empty_dirs, itm.text)
		end
	end

	local function perform_deletion(force_recursive)
		local deleted_count = 0
		local errors = {}

		-- Delete each file/directory
		for _, itm in ipairs(selected_items) do
			local ok, err = delete_single_item(itm, force_recursive)

			if ok then
				deleted_count = deleted_count + 1
			else
				table.insert(errors, itm.text .. ": " .. (err or "unknown error"))
			end
		end

		-- Clear selection and refresh
		picker.list:set_selected()
		picker:find({ refresh = true })

		-- Report results
		notify.operation_result("deleted", deleted_count, #selected_items, #errors > 0 and errors or nil)
	end

	-- If we have non-empty directories, show enhanced confirmation
	if #non_empty_dirs > 0 then
		local what = #selected_items == 1 and selected_items[1].text or #selected_items .. " files"
		local dir_warning = #non_empty_dirs == 1 and "'" .. non_empty_dirs[1] .. "' contains files"
			or #non_empty_dirs .. " directories contain files"

		vim.ui.select({ "Cancel", "Delete (files only)", "Delete recursively" }, {
			prompt = "Delete " .. what .. "?\n" .. dir_warning .. " - choose option:",
		}, function(_, idx)
			if idx == 2 then
				-- Delete files only, skip non-empty directories
				perform_deletion(false)
			elseif idx == 3 then
				-- Strong confirmation for recursive deletion
				vim.ui.input({
					prompt = "Type 'Delete' to confirm recursive deletion: ",
				}, function(input)
					if input == "Delete" then
						perform_deletion(true)
					else
						notify.cancelled("deletion")
					end
				end)
			end
		end)
	else
		-- Standard confirmation for files and empty directories
		local what = #selected_items == 1 and selected_items[1].text or #selected_items .. " files"

		vim.ui.select({ "No", "Yes" }, {
			prompt = "Delete " .. what .. "?",
		}, function(_, idx)
			if idx == 2 then
				perform_deletion(false)
			end
		end)
	end
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
		notify.info("Set working directory to: " .. current_dir)
	end
end

---Navigation actions that need state access will be injected from init.lua
---These are placeholders that get replaced with actual implementations

---Action: Go to parent directory with previous directory tracking
---@param picker any
---@param state table Multi-root state for previous directory tracking
function M.goto_parent_with_state(picker, state)
	local current = picker:cwd()
	local parent = util.safe_dirname(current)
	if parent and parent ~= current then
		navigate_to_directory(picker, parent, state, false) -- Let caller handle title updates
	end
end

---Action: Go to previous directory
---@param picker any
---@param state table Multi-root state containing prev_dir
function M.goto_previous_dir_with_state(picker, state)
	if state.prev_dir and state.prev_dir ~= picker:cwd() then
		local tmp = picker:cwd()
		picker:set_cwd(state.prev_dir)
		state.prev_dir = tmp
		-- Title updates handled by caller
		picker:find({ refresh = true })
	end
end

---Action: Go to project root (git root)
---@param picker any
---@param state table Multi-root state for previous directory tracking
function M.goto_project_root_with_state(picker, state)
	local current = picker:cwd()
	local git_root = util.get_git_root(current) or current
	if git_root ~= current then
		navigate_to_directory(picker, git_root, state, false) -- Let caller handle title updates
	end
end

---Placeholder for cycle_roots - replaced by roots module
function M.cycle_roots(picker)
	-- Implemented by roots module in init.lua
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
		create_file = M.create_file,
		rename = M.rename,
		move = M.move,
		yank = M.yank,
		paste = M.paste,
		delete = M.delete,
		edit_vsplit = M.edit_vsplit,
		edit_split = M.edit_split,
		edit_tab = M.edit_tab,
		set_pwd = M.set_pwd,
		cycle_roots = M.cycle_roots,
		toggle_detailed_view = function(picker)
			if picker.opts and picker.opts.opts then
				picker.opts.opts.detailed_view = not picker.opts.opts.detailed_view
				if picker.update then
					picker:find({ refresh = true })
				end
			end
		end,
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
