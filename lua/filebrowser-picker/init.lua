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
		["<A-h>"] = "toggle_hidden",
		["<A-c>"] = "create_file",
		["<A-r>"] = "rename",
		["<A-m>"] = "move",
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

	-- Create navigation actions that need state access
	local navigation_actions = {
		goto_parent = function(picker)
			actions.goto_parent_with_state(picker, state)
			picker.title = roots.title_for(state.idx, state.roots)
			picker:update_titles()
		end,
		goto_previous_dir = function(picker)
			actions.goto_previous_dir_with_state(picker, state)
			picker.title = roots.title_for(state.idx, state.roots)
			picker:update_titles()
		end,
		goto_project_root = function(picker)
			actions.goto_project_root_with_state(picker, state)
			picker.title = roots.title_for(state.idx, state.roots)
			picker:update_titles()
		end,
	}

	local initial_cwd = active_root()

	-- Store opts on the picker for toggle_hidden to access
	local picker_opts = {
		cwd = initial_cwd,
		title = roots.title_for(state.idx, state.roots, initial_cwd),

		finder = finder.create_finder(opts, state),
		format = finder.create_format_function(opts),

		actions = vim.tbl_extend("force", actions.get_actions(), root_actions, navigation_actions),

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

	Snacks.picker.pick(picker_opts)
end

return M
