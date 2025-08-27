local M = {}

-- Import dependencies (you'll need to ensure these are available)
local actions = require("filebrowser-picker.actions")
local util = require("filebrowser-picker.util")
local scanner = require("filebrowser-picker.scanner")
local uv = vim.uv or vim.loop

---@class FileBrowserPicker
---@field actions table<string, function>

---@class FileBrowserPicker.Config
---@field cwd? string Initial directory (default: current working directory)
---@field roots? string[]|string Multiple root directories to browse (default: {cwd})
---@field hidden? boolean Show hidden files (default: false)
---@field follow_symlinks? boolean Follow symbolic links (default: false)
---@field respect_gitignore? boolean Respect .gitignore (default: true)
---@field git_status? boolean Show git status icons (default: true)
---@field use_file_finder? boolean Use fast file discovery across all roots (default: false for single root, true for multiple roots)
---@field use_fd? boolean Enable fd for file discovery (default: true)
---@field use_rg? boolean Enable ripgrep for file discovery (default: true)
---@field excludes? string[] Additional exclude patterns (default: {})
---@field icons? table Icon configuration
---@field keymaps? table<string, string> Key mappings
---@field dynamic_layout? boolean Use dynamic layout switching based on window width (default: true)
---@field layout_width_threshold? number Minimum width for default layout, switches to vertical below this (default: 120)

---@type FileBrowserPicker.Config
M.config = {
	cwd = nil,
	roots = nil,
	hidden = false,
	follow_symlinks = false,
	respect_gitignore = true,
	git_status = true,
	use_file_finder = nil, -- Auto-detect based on roots
	use_fd = true,
	use_rg = true,
	excludes = {},
	dynamic_layout = true,
	layout_width_threshold = 120,
	icons = util.get_default_icons(),
	keymaps = {
		["<CR>"] = "confirm",
		["<C-v>"] = "edit_vsplit",
		["<C-x>"] = "edit_split",
		["<A-t>"] = "edit_tab",
		["<bs>"] = "conditional_backspace",
		["<C-g>"] = "goto_parent",
		["<C-e>"] = "goto_home",
		["<C-r>"] = "goto_cwd",
		["<C-n>"] = "cycle_roots",
		["~"] = "goto_home",
		["-"] = "goto_previous_dir",
		["="] = "goto_project_root",
		["<C-t>"] = "set_pwd",
		["<A-c>"] = "create_file",
		["<A-r>"] = "rename",
		["<A-m>"] = "move",
		["<A-y>"] = "copy",
		["<A-d>"] = "delete",
	},
}

-- Export actions for easy access
M.actions = actions

---Setup the file browser picker with user configuration
---@param opts? FileBrowserPicker.Config
function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", M.config, opts or {})
end

---Quick access functions (telescope-file-browser style)

---Open file browser at current buffer's directory
---@param opts? FileBrowserPicker.Config
function M.file_browser_here(opts)
	opts = opts or {}
	opts.cwd = util.get_initial_directory(nil)
	return M.file_browser(opts)
end

---Open file browser at project root (git root or cwd)
---@param opts? FileBrowserPicker.Config
function M.file_browser_project_root(opts)
	opts = opts or {}
	-- Try to find git root using cached lookup
	local current_file = vim.api.nvim_buf_get_name(0)
	local git_root
	if current_file and current_file ~= "" then
		git_root = util.get_git_root(vim.fn.fnamemodify(current_file, ":h"))
	end
	opts.cwd = git_root or vim.fn.getcwd()
	return M.file_browser(opts)
end

-- Normalize roots configuration
local function normalize_roots(opts)
	local roots = opts.roots
	if not roots then
		roots = { util.get_initial_directory(opts.cwd) }
	elseif type(roots) == "string" then
		roots = { roots }
	else
		-- Ensure all roots are valid directories
		local valid_roots = {}
		for _, root in ipairs(roots) do
			-- Expand ~ and resolve to absolute path
			local expanded_root = vim.fn.expand(root)
			local absolute_root = vim.fn.fnamemodify(expanded_root, ":p")

			if vim.fn.isdirectory(absolute_root) == 1 then
				table.insert(valid_roots, absolute_root)
			else
				vim.notify(
					"Invalid root directory: " .. root .. " (expanded: " .. absolute_root .. ")",
					vim.log.levels.WARN
				)
			end
		end
		roots = #valid_roots > 0 and valid_roots or { util.get_initial_directory(opts.cwd) }
	end

	return roots
end

---Open the file browser picker
---@param opts? FileBrowserPicker.Config
function M.file_browser(opts)
	opts = vim.tbl_deep_extend("force", M.config, opts or {})

	-- Get Snacks picker
	local picker_ok, Snacks = pcall(require, "snacks")
	if not picker_ok then
		error("filebrowser-picker.nvim requires snacks.nvim")
	end

	-- Normalize and validate roots
	local roots = normalize_roots(opts)
	local initial_cwd = roots[1]

	-- Auto-detect file finder usage - default to directory browser for better navigation
	if opts.use_file_finder == nil then
		opts.use_file_finder = false
	end

	-- State management for root cycling - use table so it's mutable across closures
	local state = {
		current_root_idx = 1,
		roots = roots,
	}

	-- Debug information
	if opts.debug then
		print("FileBrowser setup:")
		print("  Roots:", vim.inspect(roots))
		print("  Use file finder:", opts.use_file_finder)
		print("  Current root idx:", state.current_root_idx)
	end

	-- Pass roots to options for actions to access
	opts._roots = roots
	opts._current_root_idx = state.current_root_idx

	-- Helper function to generate title
	local function get_title(root_idx, current_dir)
		if #roots > 1 then
			return string.format("[%d/%d] %s", root_idx or state.current_root_idx, #roots, current_dir or initial_cwd)
		else
			return current_dir or initial_cwd
		end
	end

	-- Build picker configuration
	local picker_opts = {
		cwd = initial_cwd,
		title = get_title(state.current_root_idx, initial_cwd),
		finder = function(fopts, ctx)
			-- Determine the current active root (read dynamically from state)
			local current_idx = state.current_root_idx
			local active_root = state.roots[current_idx]

			-- Use file finder only if explicitly enabled
			local use_file_finder = opts.use_file_finder == true

			if use_file_finder and opts._roots then
				-- File discovery mode - scan synchronously but yield every 50 items
				local scan_opts = {
					hidden = opts.hidden,
					follow_symlinks = opts.follow_symlinks,
					respect_gitignore = opts.respect_gitignore,
					use_fd = opts.use_fd,
					use_rg = opts.use_rg,
					excludes = opts.excludes,
				}

				-- Scan only the active root (not all roots)
				local scan_fn = scanner.build_scanner(scan_opts, { active_root })
				local items = {}
				local item_count = 0
				local completed = false

				local cancel_scan = scan_fn(function(file_path)
					-- Create file item
					local basename = vim.fs.basename(file_path)
					local stat = uv.fs_stat(file_path)

					table.insert(items, {
						file = file_path,
						text = basename,
						dir = false,
						hidden = basename:sub(1, 1) == ".",
						size = stat and stat.size or 0,
						mtime = stat and stat.mtime and stat.mtime.sec or 0,
						type = "file",
					})

					-- Yield periodically to prevent blocking
					item_count = item_count + 1
					if item_count % 50 == 0 then
						vim.schedule(function() end) -- Allow UI updates
					end
				end, function()
					completed = true
				end)

				-- Wait for scan to complete, but yield control
				local start_time = uv.hrtime()
				local timeout = 10000 -- 10 second timeout
				while not completed and (uv.hrtime() - start_time) / 1000000 < timeout do
					vim.wait(1, function()
						return completed
					end, 1)
				end

				-- Store cancel function for cleanup
				if ctx and ctx.picker then
					ctx.picker._cancel_scan = cancel_scan
				end

				return items
			else
				-- Directory browsing mode - use picker's current cwd
				local cwd = ctx and ctx.picker and ctx.picker:cwd() or active_root
				local dir_items = util.scan_directory(cwd, opts)

				-- Add parent directory entry if not at root
				local home_dir = (os.getenv("HOME") or "/home/") .. (os.getenv("USER") or "user")
				if cwd ~= "/" and cwd ~= home_dir then
					table.insert(dir_items, 1, {
						file = util.safe_dirname(cwd),
						text = "../",
						dir = true,
						hidden = false,
						size = 0,
						mtime = 0,
						type = "directory",
					})
				end

				return dir_items
			end
		end,
		format = function(item)
			return actions.format_item(item, opts)
		end,
		actions = vim.tbl_extend("force", actions.get_actions(opts), {
			cycle_roots = function(picker)
				if #state.roots < 2 then
					vim.notify("Only one root directory configured", vim.log.levels.INFO)
					return
				end

				-- Update the mutable state
				local old_idx = state.current_root_idx
				state.current_root_idx = (state.current_root_idx % #state.roots) + 1
				local new_root = state.roots[state.current_root_idx]
				opts._current_root_idx = state.current_root_idx

				-- For multiple roots, we don't change picker cwd since we're discovering across all roots
				-- But for single directory mode, we do change cwd
				if not opts.use_file_finder then
					picker:set_cwd(new_root)
				end

				picker.title = get_title(state.current_root_idx, new_root)
				picker:update_titles()
				picker:find({ refresh = true })
			end,
		}),
		layout = opts.dynamic_layout and {
			cycle = true,
			preset = function()
				return vim.o.columns >= (opts.layout_width_threshold or 120) and "default" or "vertical"
			end,
		} or {
			preset = "default",
		},
		win = {
			input = {
				keys = actions.get_keymaps(opts.keymaps),
			},
			list = {
				keys = actions.get_keymaps(opts.keymaps),
			},
		},
		-- Store additional metadata
		_roots = roots,
		_current_root_idx = current_root_idx,
	}

	Snacks.picker.pick(picker_opts)
end

return M
