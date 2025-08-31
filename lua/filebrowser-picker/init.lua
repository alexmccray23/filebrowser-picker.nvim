local M = {}

-- Import modules
local config = require("filebrowser-picker.config")
local actions = require("filebrowser-picker.actions")
local util = require("filebrowser-picker.util")
local roots = require("filebrowser-picker.roots")
local finder = require("filebrowser-picker.finder")

---@class FileBrowserPicker
---@field actions table<string, function>
---@field config table Current configuration

-- Export actions for easy access
M.actions = actions

-- Export config module for access
M.config = config.get()

---Setup the file browser picker with user configuration
---@param user_opts? table User configuration options
function M.setup(user_opts)
	-- Use config module to handle configuration
	M.config = config.setup(user_opts)

	-- Enable performance optimizations if requested
	if M.config.performance then
		if M.config.performance.ui_optimizations then
			local ok, perf = pcall(require, "filebrowser-picker.perf")
			if ok then
				perf.install()
			else
				vim.notify("filebrowser-picker: Failed to load performance module", vim.log.levels.WARN)
			end
		end

		if M.config.performance.refresh_batching then
			local ok, perf_batch = pcall(require, "filebrowser-picker.perf_batch")
			if ok then
				perf_batch.install({
					refresh_ms = M.config.performance.refresh_rate_ms or 16
				})
			else
				vim.notify("filebrowser-picker: Failed to load refresh batching module", vim.log.levels.WARN)
			end
		end
	end

	-- Replace netrw with file browser if requested
	if M.config.replace_netrw then
		M.setup_netrw_replacement()
	end
end

---Setup netrw replacement functionality
function M.setup_netrw_replacement()
	-- Disable netrw completely (must be done early)
	vim.g.loaded_netrw = 1
	vim.g.loaded_netrwPlugin = 1
	vim.g.netrw_nogx = 1 -- disable netrw's gx mapping
	vim.g.netrw_altv = 1 -- disable alternative view
	vim.g.netrw_banner = 0 -- disable banner

	-- Remove existing netrw FileExplorer autocmd group
	pcall(vim.api.nvim_del_augroup_by_name, "FileExplorer")

	-- Also try to remove other potential netrw autocmds
	pcall(vim.api.nvim_del_augroup_by_name, "Network")
	pcall(vim.api.nvim_del_augroup_by_name, "NetworkReadFixup")

	local group = vim.api.nvim_create_augroup("filebrowser-picker.netrw", { clear = true })

	local function handle_directory_buffer(ev)
		if ev.file ~= "" and vim.fn.isdirectory(ev.file) == 1 then
			if vim.v.vim_did_enter == 0 then
				-- Before vim enters: clear buffer name so we don't try loading this one again
				vim.api.nvim_buf_set_name(ev.buf, "")
			else
				-- After vim has entered: delete the directory buffer using proper method
				local ok, Snacks = pcall(require, "snacks")
				if ok and Snacks.bufdelete then
					Snacks.bufdelete.delete(ev.buf)
				end
			end
			
			-- Use small delay to ensure picker opens with proper timing and focus
			vim.defer_fn(function()
				M.file_browser({
					cwd = ev.file,
					follow_symlinks = M.config.follow_symlinks,
				})
			end, 1)
		end
	end

	-- Open file browser when entering a directory buffer
	vim.api.nvim_create_autocmd("BufEnter", {
		group = group,
		callback = handle_directory_buffer,
	})

	-- Handle current buffer if it's a directory (async-safe)
	local current_file = vim.api.nvim_buf_get_name(0)
	if current_file ~= "" then
		local uv = vim.uv or vim.loop
		local stat = uv.fs_stat(current_file)
		if stat and stat.type == "directory" then
			handle_directory_buffer({ buf = 0, file = current_file })
		end
	end
end

---Open the file browser picker
---@param opts? FileBrowserPicker.Config
function M.file_browser(opts)
	opts = vim.tbl_deep_extend("force", M.config, opts or {})

	local ok, Snacks = pcall(require, "snacks")
	if not ok then
		error("filebrowser-picker.nvim requires snacks.nvim")
	end

	-- Initialize multi-root state
	local root_list = roots.normalize_roots(opts)

	-- Auto-detect use_file_finder based on number of roots
	if opts.use_file_finder == nil then
		opts.use_file_finder = #root_list > 1
	end

	local state = {
		roots = root_list,
		idx = 1,
		prev_dir = nil,
	}

	-- Helper to get current active root
	local function active_root()
		return state.roots[state.idx]
	end

	-- Create root management actions
	local root_actions = roots.create_actions(state, finder.ui_select)

	-- Create actions that need state access
	local state_aware_actions = {
		confirm = function(picker, item)
			actions.confirm_with_state(picker, item, state)
		end,
		goto_parent = function(picker)
			actions.goto_parent_with_state(picker, state)
			picker.title = roots.title_for(state.idx, state.roots, picker:cwd())
			picker:update_titles()
		end,
		goto_home = function(picker)
			actions.goto_home_with_state(picker, state)
			picker.title = roots.title_for(state.idx, state.roots, picker:cwd())
			picker:update_titles()
		end,
		goto_cwd = function(picker)
			actions.goto_cwd_with_state(picker, state)
			picker.title = roots.title_for(state.idx, state.roots, picker:cwd())
			picker:update_titles()
		end,
		goto_previous_dir = function(picker)
			actions.goto_previous_dir_with_state(picker, state)
			picker.title = roots.title_for(state.idx, state.roots, picker:cwd())
			picker:update_titles()
		end,
		goto_project_root = function(picker)
			actions.goto_project_root_with_state(picker, state)
			picker.title = roots.title_for(state.idx, state.roots, picker:cwd())
			picker:update_titles()
		end,
	}

	local initial_cwd = active_root()

	-- Store opts on the picker for actions to access
	local picker_opts = {
		cwd = initial_cwd,
		title = roots.title_for(state.idx, state.roots, initial_cwd),
		opts = opts, -- Store the options for actions to access

		finder = finder.create_finder(opts, state),
		format = finder.create_format_function(opts),

		actions = vim.tbl_extend("force", actions.get_actions(), root_actions, state_aware_actions),

		layout = opts.dynamic_layout and {
			cycle = true,
			preset = function()
				return vim.o.columns >= (opts.layout_width_threshold or 120) and "default" or "vertical"
			end,
		} or { preset = "default" },

		win = {
			input = {
				keys = actions.get_keymaps(vim.tbl_extend("force", opts.keymaps or {}, {
					["gr"] = "root_add_here",
					["gR"] = "root_add_path",
					["<leader>wr"] = "root_pick_suggested",
					["<leader>wR"] = "root_remove",
					["<C-p>"] = "cycle_roots_prev",
				})),
			},
			list = {
				keys = actions.get_keymaps(vim.tbl_extend("force", opts.keymaps or {}, {
					["gr"] = "root_add_here",
					["gR"] = "root_add_path",
					["<leader>wr"] = "root_pick_suggested",
					["<leader>wR"] = "root_remove",
					["<C-p>"] = "cycle_roots_prev",
				})),
			},
		},

		on_close = finder.create_cleanup_function(),
	}

	return Snacks.picker.pick(picker_opts)
end

---Enable netrw replacement (can be called without setup)
function M.replace_netrw()
	M.config.replace_netrw = true
	M.setup_netrw_replacement()
end

---Enable netrw hijacking (alias for replace_netrw, for telescope-file-browser compatibility)
function M.hijack_netrw()
	M.config.hijack_netrw = true
	M.config.replace_netrw = true
	M.setup_netrw_replacement()
end

---Open file browser at specific path (composable API function)
---@param path string Directory path to open at
---@param opts? table Additional options to override defaults
function M.open_at(path, opts)
	opts = vim.tbl_deep_extend("force", { cwd = path }, opts or {})
	return M.file_browser(opts)
end

---Add a root to the current picker (if one is open)
---@param path string Directory path to add as root
---@return boolean success Whether the root was added successfully
function M.add_root(path)
	-- This would need to be implemented with picker state management
	-- For now, we'll focus on the other API functions
	vim.notify("add_root() requires an active picker session", vim.log.levels.WARN)
	return false
end

---Toggle hidden files visibility (global config)
---@param show? boolean Optional explicit state, otherwise toggles current
function M.toggle_hidden(show)
	if show ~= nil then
		M.config.hidden = show
	else
		M.config.hidden = not M.config.hidden
	end
	
	-- If there's an active picker, we'd need to refresh it
	-- For now, just update the global config
	local status = M.config.hidden and "shown" or "hidden"
	vim.notify("Hidden files are now " .. status .. " (affects new pickers)", vim.log.levels.INFO)
end

---Refresh the current picker (if one is open)
---@return boolean success Whether a picker was refreshed
function M.refresh()
	-- This would need picker state management to work
	-- For now, we'll provide a basic implementation
	vim.notify("refresh() requires an active picker session", vim.log.levels.WARN)
	return false
end

return M
