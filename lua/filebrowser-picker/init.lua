---@class FileBrowserPicker
---@field actions table<string, function>
local M = {}

-- Import dependencies (you'll need to ensure these are available)
local actions = require("filebrowser-picker.actions")
local util = require("filebrowser-picker.util")

---@class FileBrowserPicker.Config
---@field cwd? string Initial directory (default: current working directory)
---@field hidden? boolean Show hidden files (default: false)
---@field follow_symlinks? boolean Follow symbolic links (default: false)
---@field respect_gitignore? boolean Respect .gitignore (default: true)
---@field git_status? boolean Show git status icons (default: true)
---@field icons? table Icon configuration
---@field keymaps? table<string, string> Key mappings
---@field dynamic_layout? boolean Use dynamic layout switching based on window width (default: true)
---@field layout_width_threshold? number Minimum width for default layout, switches to vertical below this (default: 120)

---@type FileBrowserPicker.Config
M.config = {
	cwd = nil,
	hidden = false,
	follow_symlinks = false,
	respect_gitignore = true,
	git_status = true,
	dynamic_layout = true,
	layout_width_threshold = 120,
	icons = util.get_default_icons(),
	keymaps = {
		["<CR>"] = "confirm",
		["<C-v>"] = "edit_vsplit",
		["<C-x>"] = "edit_split",
		["<C-t>"] = "edit_tab",
		["<BS>"] = "conditional_backspace",
		["<C-g>"] = "goto_parent",
		["<C-e>"] = "goto_home",
		["<C-r>"] = "goto_cwd",
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

-- Get the initial directory based on current buffer or fallback to cwd
local function get_initial_directory(opts_cwd)
	-- If cwd is explicitly provided, use it
	if opts_cwd then
		return opts_cwd
	end

	-- Try to get directory from current buffer
	local current_buf = vim.api.nvim_get_current_buf()
	local buf_name = vim.api.nvim_buf_get_name(current_buf)

	-- Check if buffer has a valid file path
	if buf_name and buf_name ~= "" and vim.fn.filereadable(buf_name) == 1 then
		local buf_dir = vim.fn.fnamemodify(buf_name, ":p:h")
		-- Ensure the directory exists
		if vim.fn.isdirectory(buf_dir) == 1 then
			return buf_dir
		end
	end

	-- Fallback to current working directory
	return vim.fn.getcwd()
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

	-- Build picker configuration
	local picker_opts = {
		source = "filebrowser",
		cwd = get_initial_directory(opts.cwd),
		title = get_initial_directory(opts.cwd),
		finder = actions.create_finder,
		format = function(item)
			return actions.format_item(item, opts)
		end,
		actions = actions.get_actions(opts),
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
	}

	Snacks.picker.pick(picker_opts)
end

return M
