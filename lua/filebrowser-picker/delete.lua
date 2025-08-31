---@class filebrowser-picker.delete
local M = {}

local uv = vim.uv or vim.loop
local notify = require("filebrowser-picker.notify")

-- Cache for executable checks
local executable_cache = {}

---Check if a command is available in PATH
---@param cmd string Command name
---@return boolean
local function has_executable(cmd)
	if executable_cache[cmd] == nil then
		executable_cache[cmd] = vim.fn.executable(cmd) == 1
	end
	return executable_cache[cmd]
end

---Find available trash command
---@return string?
local function find_trash_cmd()
	-- Check common trash commands in order of preference
	local trash_commands = {
		"trash-put",  -- trash-cli (most common on Linux)
		"trash",      -- macOS
		"gtrash",     -- alternatives
		"rmtrash",    -- alternatives
	}
	
	for _, cmd in ipairs(trash_commands) do
		if has_executable(cmd) then
			return cmd
		end
	end
	return nil
end

---Check if directory is empty
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

---Recursively delete directory using vim.uv
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

---Move single item to trash using external command
---@param item_path string Path to item to trash
---@param trash_cmd string Trash command to use
---@return boolean success
---@return string? error
local function trash_single_item(item_path, trash_cmd)
	local result = vim.fn.system({ trash_cmd, item_path })
	local exit_code = vim.v.shell_error
	
	if exit_code == 0 then
		return true
	else
		return false, "Trash command failed: " .. result
	end
end

---Delete single item using filesystem operations
---@param item table FileBrowserItem
---@param force_recursive boolean Skip confirmation for recursive deletion
---@return boolean success
---@return string? error
local function delete_single_item_fs(item, force_recursive)
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

---Delete single item (with trash support)
---@param item table FileBrowserItem
---@param opts table Delete options
---@return boolean success
---@return string? error
local function delete_single_item(item, opts)
	opts = opts or {}
	
	if opts.use_trash then
		local trash_cmd = find_trash_cmd()
		if trash_cmd then
			return trash_single_item(item.file, trash_cmd)
		else
			-- Fall back to filesystem deletion if no trash command available
			notify.warn("No trash command available, falling back to permanent deletion")
		end
	end
	
	-- Use filesystem deletion
	return delete_single_item_fs(item, opts.force_recursive)
end

---Determine if confirmation is needed based on settings and context
---@param opts table Options with confirm_rm setting
---@param item_count number Number of items to delete
---@return boolean needs_confirmation
local function needs_confirmation(opts, item_count)
	local confirm_rm = opts.confirm_rm or "always"
	
	if confirm_rm == "never" then
		return false
	elseif confirm_rm == "multi" then
		return item_count > 1
	else -- "always" or any other value
		return true
	end
end

---Get confirmation message for deletion
---@param selected_items table[] Items to delete
---@param opts table Delete options
---@return string message
---@return string[] choices
local function get_confirmation_message(selected_items, opts)
	local item_count = #selected_items
	local what = item_count == 1 and selected_items[1].text or item_count .. " items"
	
	-- Check for non-empty directories that need recursive deletion
	local non_empty_dirs = {}
	for _, item in ipairs(selected_items) do
		if item.dir and not is_directory_empty(item.file) then
			table.insert(non_empty_dirs, item.text)
		end
	end
	
	local action = opts.use_trash and find_trash_cmd() and "Move to trash" or "Delete permanently"
	local base_message = action .. " " .. what .. "?"
	
	if #non_empty_dirs > 0 then
		local dir_warning = #non_empty_dirs == 1 
			and "'" .. non_empty_dirs[1] .. "' contains files"
			or #non_empty_dirs .. " directories contain files"
		
		if opts.use_trash and find_trash_cmd() then
			-- Trash handles recursion automatically
			return base_message .. "\n" .. dir_warning, { "Cancel", action }
		else
			-- Need to offer recursive deletion option
			return base_message .. "\n" .. dir_warning .. " - choose option:",
				   { "Cancel", "Delete (files only)", "Delete recursively" }
		end
	end
	
	return base_message, { "Cancel", action }
end

---Delete multiple items with appropriate confirmation
---@param selected_items table[] Items to delete
---@param opts table Options including use_trash, confirm_rm
---@param on_complete function Callback when deletion is complete
function M.delete_items(selected_items, opts, on_complete)
	if #selected_items == 0 then
		notify.no_selection("delete")
		return
	end
	
	opts = vim.tbl_extend("keep", opts or {}, {
		use_trash = true,
		confirm_rm = "always",
		force_recursive = false,
	})
	
	-- Function to perform the actual deletion
	local function perform_deletion(recursive_mode)
		local deleted_count = 0
		local errors = {}
		
		-- Delete each item
		for _, item in ipairs(selected_items) do
			local delete_opts = vim.tbl_extend("force", opts, {
				force_recursive = recursive_mode == "recursive"
			})
			
			-- Skip non-empty directories if not in recursive mode
			if recursive_mode == "files_only" and item.dir and not is_directory_empty(item.file) then
				goto continue
			end
			
			local ok, err = delete_single_item(item, delete_opts)
			
			if ok then
				deleted_count = deleted_count + 1
			else
				table.insert(errors, item.text .. ": " .. (err or "unknown error"))
			end
			
			::continue::
		end
		
		-- Report results
		local action = opts.use_trash and find_trash_cmd() and "moved to trash" or "deleted"
		notify.operation_result(action, deleted_count, #selected_items, #errors > 0 and errors or nil)
		
		if on_complete then
			on_complete(deleted_count > 0)
		end
	end
	
	-- Check if confirmation is needed
	if not needs_confirmation(opts, #selected_items) then
		perform_deletion("recursive")
		return
	end
	
	-- Get appropriate confirmation message and choices
	local message, choices = get_confirmation_message(selected_items, opts)
	
	vim.ui.select(choices, {
		prompt = message,
	}, function(choice, idx)
		if idx == 1 or not choice then
			-- Cancel
			return
		elseif idx == 2 then
			-- Main action (trash/delete files only)
			perform_deletion("files_only")
		elseif idx == 3 then
			-- Recursive deletion (only shown for permanent deletion with non-empty dirs)
			vim.ui.input({
				prompt = "Type 'DELETE' to confirm recursive deletion: ",
			}, function(input)
				if input == "DELETE" then
					perform_deletion("recursive")
				else
					notify.cancelled("deletion")
				end
			end)
		end
	end)
end

return M