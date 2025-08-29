---@class FileBrowserScanner
local M = {}

local uv = vim.uv or vim.loop

---Check if a binary is available
---@param bin string
---@return boolean
local function has_executable(bin)
	return vim.fn.executable(bin) == 1
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
			for line in data:gmatch("[^\r\n]+") do
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
			handle:kill("sigterm")
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

	if not opts.respect_gitignore then
		table.insert(base_args, "--no-ignore")
		table.insert(base_args, "--no-ignore-vcs")
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
	local default_excludes = { ".git", "node_modules", ".venv", "__pycache__", ".DS_Store" }
	local excludes = vim.tbl_extend("force", default_excludes, opts.excludes or {})

	---Check if path should be excluded
	---@param path string
	---@return boolean
	local function should_exclude(path)
		local basename = vim.fs.basename(path)
		for _, pattern in ipairs(excludes) do
			if basename:match(pattern) then
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

	return function(on_item, on_done)
		local queue = vim.deepcopy(roots)
		local active = 0
		local finished = false
		local visited = {} -- Track visited paths to prevent infinite loops

		local function process_directory(dir)
			if finished then
				return
			end

			-- Prevent infinite loops with symlinks
			local real_path = uv.fs_realpath(dir) or dir
			if visited[real_path] then
				return
			end
			visited[real_path] = true

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

						if type == "file" then
							on_item(full_path)
						elseif type == "directory" then
							table.insert(queue, full_path)
						elseif type == "link" and opts.follow_symlinks then
							-- For symlinks, check what they point to (with loop protection)
							local real_target = uv.fs_realpath(full_path)
							if real_target and not visited[real_target] then
								uv.fs_stat(full_path, function(stat_err, stat)
									if not stat_err and stat then
										if stat.type == "file" then
											on_item(full_path)
										elseif stat.type == "directory" then
											table.insert(queue, full_path)
										end
									end
								end)
							end
						end

						::continue::
					end
				end

				-- Schedule next batch
				if not finished then
					vim.schedule(process_next)
				end
			end)
		end

		function process_next()
			if finished then
				return
			end

			-- Process up to MAX_CONCURRENT directories
			while active < MAX_CONCURRENT and #queue > 0 do
				local dir = table.remove(queue, 1)
				active = active + 1
				process_directory(dir)
			end

			-- Check if we're done
			if active == 0 and #queue == 0 and not finished then
				finished = true
				on_done()
			end
		end

		-- Start processing
		vim.schedule(process_next)

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
		local git = require("filebrowser-picker.git")
		for _, root in ipairs(roots) do
			git.preload_status(root, opts._git_refresh_callback)
		end
	end

	-- Prefer fd > rg > uv fallback
	if opts.use_fd and has_executable("fd") then
		return build_fd_scanner(opts, roots)
	elseif opts.use_rg and has_executable("rg") then
		return build_rg_scanner(opts, roots)
	else
		return build_uv_scanner(opts, roots)
	end
end

return M
