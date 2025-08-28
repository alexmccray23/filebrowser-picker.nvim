---@class filebrowser-picker.notify
local M = {}

---@class NotifyOptions
---@field title? string Custom title for notification
---@field timeout? number Timeout in milliseconds

---Base notification function with consistent formatting
---@param message string
---@param level? number vim.log.levels level
---@param opts? NotifyOptions
local function notify(message, level, opts)
	opts = opts or {}
	local title = opts.title and "[FileBrowser] " .. opts.title or "[FileBrowser]"
	
	-- Add title prefix for better identification
	local formatted_message = title .. " " .. message
	
	if opts.timeout then
		vim.notify(formatted_message, level, { timeout = opts.timeout })
	else
		vim.notify(formatted_message, level)
	end
end

---Show success notification (green, typically)
---@param message string
---@param opts? NotifyOptions
function M.success(message, opts)
	notify(message, vim.log.levels.INFO, opts)
end

---Show info notification (default styling)
---@param message string  
---@param opts? NotifyOptions
function M.info(message, opts)
	notify(message, vim.log.levels.INFO, opts)
end

---Show warning notification (yellow/orange, typically)
---@param message string
---@param opts? NotifyOptions
function M.warn(message, opts)
	notify(message, vim.log.levels.WARN, opts)
end

---Show error notification (red, typically)
---@param message string
---@param opts? NotifyOptions
function M.error(message, opts)
	notify(message, vim.log.levels.ERROR, opts)
end

---Show operation result with success/error counts
---@param operation string Operation name (e.g., "moved", "deleted", "copied")
---@param success_count number Number of successful operations
---@param total_count number Total number of operations attempted
---@param errors? string[] List of error messages
---@param opts? NotifyOptions
function M.operation_result(operation, success_count, total_count, errors, opts)
	if success_count > 0 then
		local item_word = success_count == 1 and "file" or "files"
		M.success(string.format("%s %d %s", operation:gsub("^%l", string.upper), success_count, item_word), opts)
	end
	
	if errors and #errors > 0 then
		local failure_count = total_count - success_count
		local error_message = string.format("Some %s failed (%d/%d):\n%s", 
			operation, failure_count, total_count, table.concat(errors, "\n"))
		M.error(error_message, opts)
	elseif success_count == 0 then
		M.error(string.format("All %s operations failed", operation), opts)
	end
end

---Show file creation result
---@param created_items string[] List of created items (e.g., "file: /path", "directory: /path")
---@param opts? NotifyOptions  
function M.created(created_items, opts)
	if #created_items > 0 then
		local message = "Created " .. table.concat(created_items, " and ")
		M.success(message, opts)
	end
end

---Show "no selection" warning
---@param operation string Operation that requires selection (e.g., "delete", "move")
---@param opts? NotifyOptions
function M.no_selection(operation, opts)
	M.warn(string.format("No files selected to %s", operation), opts)
end

---Show path validation error
---@param path string Invalid path
---@param reason string Reason for invalidity  
---@param opts? NotifyOptions
function M.invalid_path(path, reason, opts)
	M.error(string.format("Invalid path '%s': %s", path, reason), opts)
end

---Show cancellation message
---@param operation string Operation that was cancelled
---@param opts? NotifyOptions
function M.cancelled(operation, opts)
	M.info(string.format("%s cancelled", operation:gsub("^%l", string.upper)), opts)
end

return M