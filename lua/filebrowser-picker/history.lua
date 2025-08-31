---@class filebrowser-picker.history
local M = {}

local uv = vim.uv or vim.loop

-- Default history settings
local DEFAULT_HISTORY_FILE = vim.fn.stdpath("data") .. "/filebrowser-picker/history"
local DEFAULT_MAX_ENTRIES = 50

---Ensure history directory exists
---@param history_file string Path to history file
---@return boolean success
local function ensure_history_dir(history_file)
	local dir = vim.fn.fnamemodify(history_file, ":h")
	if vim.fn.isdirectory(dir) == 0 then
		local ok, err = pcall(vim.fn.mkdir, dir, "p")
		if not ok then
			vim.notify("filebrowser-picker: Failed to create history directory: " .. (err or "unknown error"), vim.log.levels.ERROR)
			return false
		end
	end
	return true
end

---Load history from file
---@param history_file? string Path to history file (default: standard location)
---@return table history_data
function M.load_history(history_file)
	history_file = history_file or DEFAULT_HISTORY_FILE
	
	local history = {
		last_dir = nil,
		recent_dirs = {},
		roots_history = {},
	}
	
	if vim.fn.filereadable(history_file) == 0 then
		return history
	end
	
	local ok, content = pcall(vim.fn.readfile, history_file)
	if not ok then
		return history
	end
	
	local json_str = table.concat(content, "\n")
	if json_str == "" then
		return history
	end
	
	-- Parse JSON safely
	local parsed_ok, parsed = pcall(vim.json.decode, json_str)
	if parsed_ok and type(parsed) == "table" then
		history = vim.tbl_deep_extend("keep", parsed, history)
	end
	
	return history
end

---Save history to file
---@param history table History data to save
---@param history_file? string Path to history file (default: standard location)
---@return boolean success
function M.save_history(history, history_file)
	history_file = history_file or DEFAULT_HISTORY_FILE
	
	if not ensure_history_dir(history_file) then
		return false
	end
	
	-- Limit recent_dirs to max entries
	local max_entries = DEFAULT_MAX_ENTRIES
	if #history.recent_dirs > max_entries then
		-- Keep most recent entries
		local new_recent = {}
		for i = #history.recent_dirs - max_entries + 1, #history.recent_dirs do
			table.insert(new_recent, history.recent_dirs[i])
		end
		history.recent_dirs = new_recent
	end
	
	local ok, json_str = pcall(vim.json.encode, history)
	if not ok then
		vim.notify("filebrowser-picker: Failed to encode history", vim.log.levels.ERROR)
		return false
	end
	
	local write_ok, err = pcall(vim.fn.writefile, vim.split(json_str, "\n"), history_file)
	if not write_ok then
		vim.notify("filebrowser-picker: Failed to write history: " .. (err or "unknown error"), vim.log.levels.ERROR)
		return false
	end
	
	return true
end

---Add directory to history
---@param dir string Directory path to add
---@param history_file? string Path to history file
function M.add_to_history(dir, history_file)
	if not dir or dir == "" then
		return
	end
	
	-- Normalize path
	dir = vim.fn.fnamemodify(dir, ":p"):gsub("/$", "")
	
	local history = M.load_history(history_file)
	
	-- Update last directory
	history.last_dir = dir
	
	-- Add to recent directories (avoiding duplicates)
	history.recent_dirs = history.recent_dirs or {}
	
	-- Remove existing entry if present
	for i = #history.recent_dirs, 1, -1 do
		if history.recent_dirs[i] == dir then
			table.remove(history.recent_dirs, i)
		end
	end
	
	-- Add to end (most recent)
	table.insert(history.recent_dirs, dir)
	
	-- Save updated history
	M.save_history(history, history_file)
end

---Get last directory from history
---@param history_file? string Path to history file
---@return string? last_dir
function M.get_last_dir(history_file)
	local history = M.load_history(history_file)
	
	-- Verify directory still exists
	if history.last_dir and vim.fn.isdirectory(history.last_dir) == 1 then
		return history.last_dir
	end
	
	return nil
end

---Get recent directories from history
---@param history_file? string Path to history file
---@param limit? number Maximum number of entries to return
---@return string[] recent_dirs
function M.get_recent_dirs(history_file, limit)
	local history = M.load_history(history_file)
	limit = limit or 10
	
	local recent = {}
	local count = 0
	
	-- Get most recent entries, filtering out non-existent directories
	for i = #history.recent_dirs, 1, -1 do
		local dir = history.recent_dirs[i]
		if vim.fn.isdirectory(dir) == 1 then
			table.insert(recent, dir)
			count = count + 1
			if count >= limit then
				break
			end
		end
	end
	
	return recent
end

---Add roots configuration to history
---@param roots string[] Root directories
---@param history_file? string Path to history file
function M.add_roots_to_history(roots, history_file)
	if not roots or #roots == 0 then
		return
	end
	
	local history = M.load_history(history_file)
	history.roots_history = history.roots_history or {}
	
	-- Create a key for this roots configuration
	local roots_key = table.concat(roots, "|")
	
	-- Add timestamp
	local entry = {
		roots = roots,
		timestamp = os.time(),
		key = roots_key,
	}
	
	-- Remove existing entry with same roots
	for i = #history.roots_history, 1, -1 do
		if history.roots_history[i].key == roots_key then
			table.remove(history.roots_history, i)
		end
	end
	
	-- Add to end (most recent)
	table.insert(history.roots_history, entry)
	
	-- Limit to reasonable number
	local max_roots_history = 20
	if #history.roots_history > max_roots_history then
		table.remove(history.roots_history, 1)
	end
	
	M.save_history(history, history_file)
end

---Get recent roots configurations from history
---@param history_file? string Path to history file
---@param limit? number Maximum number of entries to return
---@return table[] recent_roots Array of {roots=string[], timestamp=number}
function M.get_recent_roots(history_file, limit)
	local history = M.load_history(history_file)
	limit = limit or 5
	
	local recent = {}
	local count = 0
	
	-- Get most recent entries, filtering out non-existent directories
	for i = #history.roots_history, 1, -1 do
		local entry = history.roots_history[i]
		if entry.roots then
			-- Verify at least one root still exists
			local valid = false
			for _, root in ipairs(entry.roots) do
				if vim.fn.isdirectory(root) == 1 then
					valid = true
					break
				end
			end
			
			if valid then
				table.insert(recent, entry)
				count = count + 1
				if count >= limit then
					break
				end
			end
		end
	end
	
	return recent
end

---Clear history
---@param history_file? string Path to history file
---@return boolean success
function M.clear_history(history_file)
	history_file = history_file or DEFAULT_HISTORY_FILE
	
	local ok, err = pcall(vim.fn.delete, history_file)
	if not ok and err ~= 0 then
		vim.notify("filebrowser-picker: Failed to clear history: " .. (err or "unknown error"), vim.log.levels.ERROR)
		return false
	end
	
	return true
end

return M