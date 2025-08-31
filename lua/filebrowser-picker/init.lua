local M = {}

-- Import modules
local actions = require("filebrowser-picker.actions")
local util = require("filebrowser-picker.util")
local roots = require("filebrowser-picker.roots")
local finder = require("filebrowser-picker.finder")

---@class FileBrowserPicker
---@field actions table<string, function>

---@class FileBrowserPicker.Config
---@field cwd? string Initial directory (default: current working directory)
---@field roots? string[]|string Multiple root directories to browse (default: {cwd})
---@field hidden? boolean Show hidden files (default: false)
---@field detailed_view? boolean Show detailed file information like ls -l (default: false)
---@field display_stat? table Configure which stats to show in detailed view (default: {mode=true, size=true, date=true})
---@field follow_symlinks? boolean Follow symbolic links (default: false)
---@field respect_gitignore? boolean Respect .gitignore (default: true)
---@field git_status? boolean Show git status icons (default: true)
---@field git_status_hl? table Git status highlight groups (default: see below)
---@field use_file_finder? boolean Use fast file discovery across all roots (default: false for single root, true for multiple roots)
---@field use_fd? boolean Enable fd for file discovery (default: true)
---@field use_rg? boolean Enable ripgrep for file discovery (default: true)
---@field excludes? string[] Additional exclude patterns (default: {})
---@field icons? table Icon configuration
---@field keymaps? table<string, string> Key mappings
---@field dynamic_layout? boolean Use dynamic layout switching based on window width (default: true)
---@field layout_width_threshold? number Minimum width for default layout, switches to vertical below this (default: 120)
---@field replace_netrw? boolean Replace netrw with the file browser (default: false)
---@field performance? table Performance optimization options
---@field performance.ui_optimizations? boolean Enable UI performance optimizations (icon caching, formatting) (default: false)
---@field performance.refresh_batching? boolean Enable refresh batching for file finder mode (default: false)
---@field performance.refresh_rate_ms? number Refresh rate for batching in milliseconds (default: 16)

---@type FileBrowserPicker.Config
M.config = {
	cwd = nil,
	roots = nil,
	hidden = false,
	detailed_view = false,
	display_stat = {
		mode = true,
		size = true,
		date = true,
	},
	follow_symlinks = false,
	respect_gitignore = true,
	git_status = true,
	git_status_hl = {
		staged = "DiagnosticHint",
		added = "Added",
		deleted = "Removed",
		ignored = "NonText",
		modified = "DiagnosticWarn",
		renamed = "Special",
		unmerged = "DiagnosticError",
		untracked = "NonText",
		copied = "Special",
	},
	use_file_finder = nil, -- Auto-detect based on roots
	use_fd = true,
	use_rg = true,
	excludes = {},
	dynamic_layout = true,
	layout_width_threshold = 120,
	replace_netrw = false,
	performance = {
		ui_optimizations = false,
		refresh_batching = false,
		refresh_rate_ms = 16,
	},
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
		["<A-h>"] = "toggle_hidden",
		["<A-l>"] = "toggle_detailed_view",
		["<A-c>"] = "create_file",
		["<A-r>"] = "rename",
		["<A-v>"] = "move",
		["<A-y>"] = "yank",
		["<A-p>"] = "paste",
		["<A-d>"] = "delete",
	},
}

-- Export actions for easy access
M.actions = actions

---Setup the file browser picker with user configuration
---@param opts? FileBrowserPicker.Config
function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", M.config, opts or {})

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

return M
