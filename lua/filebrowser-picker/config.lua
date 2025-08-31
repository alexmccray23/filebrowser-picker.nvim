---@class filebrowser-picker.config
local M = {}

local util = require("filebrowser-picker.util")

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
---@field hijack_netrw? boolean Hijack netrw (alias for replace_netrw, for telescope-file-browser compatibility) (default: false)
---@field use_trash? boolean Use trash when deleting files (requires trash-cli or similar) (default: true)
---@field confirm_rm? "always"|"multi"|"never" When to confirm deletions (default: "always")
---@field performance? table Performance optimization options
---@field performance.ui_optimizations? boolean Enable UI performance optimizations (icon caching, formatting) (default: false)
---@field performance.refresh_batching? boolean Enable refresh batching for file finder mode (default: false)
---@field performance.refresh_rate_ms? number Refresh rate for batching in milliseconds (default: 16)

---Default configuration
---@type FileBrowserPicker.Config
M.defaults = {
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
	hijack_netrw = false,
	use_trash = true,
	confirm_rm = "always",
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

---Current configuration (merged defaults + user config)
---@type FileBrowserPicker.Config
M.current = vim.deepcopy(M.defaults)

---Setup configuration with user options
---@param user_opts? FileBrowserPicker.Config User configuration
---@return FileBrowserPicker.Config merged_config
function M.setup(user_opts)
	-- Deep merge user config with defaults
	M.current = vim.tbl_deep_extend("force", M.defaults, user_opts or {})

	-- Handle hijack_netrw alias for telescope-file-browser compatibility
	if M.current.hijack_netrw ~= nil and M.current.replace_netrw == false then
		M.current.replace_netrw = M.current.hijack_netrw
	end

	return M.current
end

---Get current configuration
---@return FileBrowserPicker.Config
function M.get()
	return M.current
end

---Update configuration at runtime
---@param key string Configuration key (supports dot notation like "performance.ui_optimizations")
---@param value any New value
function M.set(key, value)
	local keys = vim.split(key, ".", { plain = true })
	local current = M.current
	
	-- Navigate to parent table
	for i = 1, #keys - 1 do
		local k = keys[i]
		if not current[k] then
			current[k] = {}
		end
		current = current[k]
	end
	
	-- Set final value
	current[keys[#keys]] = value
end

---Get configuration value
---@param key string Configuration key (supports dot notation)
---@return any value
function M.get_value(key)
	local keys = vim.split(key, ".", { plain = true })
	local current = M.current
	
	for _, k in ipairs(keys) do
		if type(current) ~= "table" or current[k] == nil then
			return nil
		end
		current = current[k]
	end
	
	return current
end

return M