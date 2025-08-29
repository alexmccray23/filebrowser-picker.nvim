---@class filebrowser-picker.git
local M = {}

local uv = vim.uv or vim.loop

-- Cache for git status results
local git_cache = {}
local CACHE_TTL = 15 * 60 * 1000 -- 15 minutes in milliseconds

-- Git status mappings from porcelain format
local STATUS_CODES = {
	["??"] = "untracked",
	["!!"] = "ignored",
	[" M"] = "modified",
	["M "] = "staged",
	["MM"] = "modified", -- Modified in both index and working tree
	[" D"] = "deleted",
	["D "] = "staged",
	["A "] = "added",
	["R "] = "renamed",
	["C "] = "copied",
	["UU"] = "unmerged",
	["AA"] = "unmerged",
	["DD"] = "unmerged",
}

-- Priority system for status (higher = more important)
local STATUS_PRIORITY = {
	unmerged = 30,
	staged = 25,
	deleted = 20,
	modified = 15,
	added = 10,
	renamed = 10,
	copied = 10,
	untracked = 5,
	ignored = 1,
}

---Get git root for a given path
---@param path string
---@return string|nil
local function get_git_root(path)
	local current = path
	while current ~= "/" do
		local git_dir = current .. "/.git"
		local stat = uv.fs_stat(git_dir)
		if stat then
			return current
		end
		current = current:match("^(.+)/[^/]*$") or "/"
	end
	return nil
end

---Parse git status output
---@param output string Raw git status --porcelain output
---@return table<string, string> Map of file paths to status
local function parse_git_status(output)
	local status_map = {}

	-- Split by null bytes (git --porcelain -z)
	local lines = vim.split(output, "\0", { plain = true })
	for _, line in ipairs(lines) do
		if line:len() >= 3 then
			local status_code = line:sub(1, 2)
			local file_path = line:sub(4)

			-- Handle renamed files (original -> new format)
			if status_code:sub(1, 1) == "R" then
				local parts = vim.split(file_path, " -> ")
				if #parts == 2 then
					file_path = parts[2] -- Use new filename
				end
			end

			local status = STATUS_CODES[status_code] or "unknown"

			-- Store the highest priority status for this file
			local existing_priority = STATUS_PRIORITY[status_map[file_path]] or 0
			local new_priority = STATUS_PRIORITY[status] or 0

			if new_priority > existing_priority then
				status_map[file_path] = status
			end
		end
	end

	return status_map
end

---Get git status for a directory (async)
---@param root_path string Git repository root path
---@param callback function(status_map: table<string, string>)
local function fetch_git_status(root_path, callback)
	local stdout = uv.new_pipe(false)
	local output = ""

	local handle = uv.spawn("git", {
		stdio = { nil, stdout, nil },
		cwd = root_path,
		args = {
			"--no-pager",
			"status",
			"--porcelain=v1",
			"--ignored=matching",
			"-z",
			"-unormal", -- Include untracked files
		},
	}, function(code)
		stdout:close()

		if code == 0 then
			local status_map = parse_git_status(output)

			-- Cache the results
			git_cache[root_path] = {
				status_map = status_map,
				timestamp = uv.now(),
			}

			callback(status_map)
		else
			-- Git command failed, return empty status
			callback({})
		end
	end)

	if not handle then
		callback({})
		return
	end

	stdout:read_start(function(err, data)
		if not err and data then
			output = output .. data
		end
	end)
end

---Get git status for a file or directory
---@param file_path string Absolute path to file
---@param callback function(status: string|nil)
function M.get_status(file_path, callback)
	local git_root = get_git_root(file_path)
	if not git_root then
		callback(nil)
		return
	end

	local cached = git_cache[git_root]
	local now = uv.now()

	-- Use cached results if available and not expired
	if cached and (now - cached.timestamp) < CACHE_TTL then
		local relative_path = file_path:sub(#git_root + 2) -- Remove git_root/ prefix
		callback(cached.status_map[relative_path])
		return
	end

	-- Fetch fresh git status
	fetch_git_status(git_root, function(status_map)
		local relative_path = file_path:sub(#git_root + 2) -- Remove git_root/ prefix
		callback(status_map[relative_path])
	end)
end

---Get git status synchronously (for immediate display, may be stale)
---@param file_path string Absolute path to file
---@return string|nil
function M.get_status_sync(file_path)
	local git_root = get_git_root(file_path)
	if not git_root then
		return nil
	end

	local cached = git_cache[git_root]
	if not cached then
		return nil
	end

	local relative_path = file_path:sub(#git_root + 2) -- Remove git_root/ prefix
	return cached.status_map[relative_path]
end

---Invalidate git cache for a specific root or all roots
---@param root_path string|nil If nil, clear all cache
function M.invalidate_cache(root_path)
	if root_path then
		git_cache[root_path] = nil
	else
		git_cache = {}
	end
end

---Preload git status for a directory (optimization for file browsers)
---@param dir_path string Directory to preload git status for
---@param on_complete function? Optional callback when git status is loaded
function M.preload_status(dir_path, on_complete)
	local git_root = get_git_root(dir_path)
	if not git_root then
		return
	end

	local cached = git_cache[git_root]
	local now = uv.now()

	-- Start watcher to invalidate on HEAD/index changes
	if M.watch_repo then
		M.watch_repo(git_root, on_complete)
	end

	-- Skip if cache is still fresh
	if cached and (now - cached.timestamp) < CACHE_TTL then
		if on_complete then
			on_complete()
		end
		return
	end

	-- Preload in background
	fetch_git_status(git_root, function(status_map)
		-- Status is now cached for future sync calls
		if on_complete then
			on_complete()
		end
	end)
end

	-- Lightweight repo watchers to invalidate cache quickly
	local _watchers = {}

	---Watch .git/HEAD and .git/index, invalidating cache and optionally calling on_change
	---@param root string
	---@param on_change function|nil
	function M.watch_repo(root, on_change)
		if not root or _watchers[root] then
			return
		end
		local function mkwatch(path)
			local w = uv.new_fs_event()
			if not w then
				return
			end
			w:start(path, {}, function()
				M.invalidate_cache(root)
				if on_change then
					pcall(on_change)
				end
				-- kick off a refresh in background
				pcall(M.preload_status, root, on_change)
			end)
			return w
		end
		local head = root .. "/.git/HEAD"
		local index = root .. "/.git/index"
		_watchers[root] = { mkwatch(head), mkwatch(index) }
	end

	function M.unwatch_repo(root)
		local ws = _watchers[root]
		if not ws then
			return
		end
		for _, w in ipairs(ws) do
			pcall(function()
				w:stop()
				w:close()
			end)
		end
		_watchers[root] = nil
	end

return M
