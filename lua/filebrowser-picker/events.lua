---@class filebrowser-picker.events
local M = {}

-- Event types supported by the plugin
M.events = {
	ENTER = "FilebrowserEnter",
	LEAVE = "FilebrowserLeave", 
	DIR_CHANGED = "FilebrowserDirChanged",
	CONFIRM = "FilebrowserConfirm",
	ROOTS_CHANGED = "FilebrowserRootsChanged",
	FILE_CREATED = "FilebrowserFileCreated",
	FILE_DELETED = "FilebrowserFileDeleted",
	FILE_RENAMED = "FilebrowserFileRenamed",
}

---Emit a User autocommand for the given event
---@param event string Event name
---@param data? table Event data to pass
function M.emit(event, data)
	-- Create User autocommand
	vim.api.nvim_exec_autocmds("User", {
		pattern = event,
		data = data or {},
	})
end

---Set up autocommand groups for events
function M.setup()
	-- Create autocommand group for filebrowser-picker events
	local group = vim.api.nvim_create_augroup("filebrowser-picker-events", { clear = true })
	
	-- We don't create any default autocmds here - users will set up their own listeners
	-- This just ensures the group exists for organization
	return group
end

---Helper to create callback wrapper that emits events and calls user callback
---@param event_name string Name of the event to emit
---@param user_callback? function User-provided callback
---@return function wrapped_callback
function M.create_callback_wrapper(event_name, user_callback)
	return function(...)
		local args = {...}
		
		-- Emit the event first
		M.emit(event_name, { args = args })
		
		-- Call user callback if provided
		if user_callback and type(user_callback) == "function" then
			return user_callback(...)
		end
	end
end

---Get event data from autocommand callback
---@param autocmd_data table Autocommand data from nvim_create_autocmd callback
---@return table? event_data The data passed to the event
function M.get_event_data(autocmd_data)
	if autocmd_data and autocmd_data.data then
		return autocmd_data.data
	end
	return nil
end

---Convenience function to register event listeners
---@param event string Event name (use M.events.* constants)
---@param callback function Callback to run when event occurs
---@param opts? table Options for nvim_create_autocmd
---@return number autocmd_id The autocmd ID for later removal
function M.on(event, callback, opts)
	opts = opts or {}
	opts.pattern = event
	opts.callback = callback
	
	return vim.api.nvim_create_autocmd("User", opts)
end

---Remove an event listener
---@param autocmd_id number The autocmd ID returned by M.on()
function M.off(autocmd_id)
	pcall(vim.api.nvim_del_autocmd, autocmd_id)
end

---Create a simple event listener that logs events (useful for debugging)
---@param events? string[] List of events to log (default: all events)
---@return function cleanup_function Function to remove all listeners
function M.create_debug_logger(events)
	events = events or vim.tbl_values(M.events)
	local autocmd_ids = {}
	
	for _, event in ipairs(events) do
		local id = M.on(event, function(autocmd_data)
			local data = M.get_event_data(autocmd_data)
			vim.notify(string.format("[FilebrowserPicker] Event: %s, Data: %s", 
				event, vim.inspect(data)), vim.log.levels.INFO)
		end)
		table.insert(autocmd_ids, id)
	end
	
	-- Return cleanup function
	return function()
		for _, id in ipairs(autocmd_ids) do
			M.off(id)
		end
	end
end

return M