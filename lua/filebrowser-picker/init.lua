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

---Setup the file browser picker with user configuration
---@param opts? FileBrowserPicker.Config
function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", M.config, opts or {})
end
---Open the file browser picker (patched for dynamic roots + streaming)
---@param opts? FileBrowserPicker.Config
function M.file_browser(opts)
	opts = vim.tbl_deep_extend("force", M.config, opts or {})

	local ok, Snacks = pcall(require, "snacks")
	if not ok then
		error("filebrowser-picker.nvim requires snacks.nvim")
	end

	-- normalize roots once; we’ll mutate this list at runtime
	local roots = (function()
		local r = normalize_roots(opts)
		if #r == 0 then
			r = { util.get_initial_directory(opts.cwd) }
		end
		return r
	end)()

	-- live state (mutated by actions)
	local state = {
		roots = roots,
		idx = 1, -- active root (1-based)
		prev_dir = nil, -- for "-" jump
	}

	local function active_root()
		return state.roots[state.idx]
	end
	local function title_for(root_idx, dir)
		local path = dir or active_root()
		return (#state.roots > 1) and string.format("[%d/%d] %s", root_idx or state.idx, #state.roots, path) or path
	end

	-- tiny helper: selection UI that works with or without Snacks.select
	local function ui_select(items, prompt, cb)
		if Snacks.picker.select then
			return Snacks.picker.select(items, { prompt = prompt or "Select" }, cb)
		end
		vim.ui.select(items, { prompt = prompt or "Select" }, cb)
	end

	-- SUGGESTED ROOTS (git, LSP, home, cwd)
	local function discover_roots()
		local out, seen = {}, {}
		local function add(p)
			if not p or p == "" then
				return
			end
			p = vim.fs.normalize(vim.fn.fnamemodify(p, ":p"))
			if vim.fn.isdirectory(p) == 1 and not seen[p] then
				out[#out + 1] = p
				seen[p] = true
			end
		end
		add(vim.fn.getcwd())
		add(vim.loop.os_homedir())
		local gitdir = vim.fs.find(".git", { upward = true, stop = vim.loop.os_homedir() })[1]
		if gitdir then
			add(vim.fs.dirname(gitdir))
		end
		for _, client in pairs(vim.lsp.get_clients({ bufnr = 0 })) do
			if client.workspace_folders then
				for _, wf in ipairs(client.workspace_folders) do
					add(vim.uri_to_fname(wf.uri))
				end
			end
			if client.config and client.config.root_dir then
				add(client.config.root_dir)
			end
		end
		return out
	end

	-- SCANNING (streaming; zero busy-wait)
	local function start_scanner(ctx)
		if not opts.use_file_finder then
			return nil, nil, nil
		end

		local scan_opts = {
			hidden = opts.hidden,
			follow_symlinks = opts.follow_symlinks,
			respect_gitignore = opts.respect_gitignore,
			use_fd = opts.use_fd,
			use_rg = opts.use_rg,
			excludes = opts.excludes,
		}

		-- If file_finder mode + multiple roots, scan ALL roots unless explicitly disabled
		local scan_roots
		if #state.roots > 1 and (opts.search_all_roots ~= false) then
			scan_roots = state.roots
		else
			scan_roots = { active_root() }
		end

		local list = {} -- items table returned to Snacks
		local pushed = 0
		local scan_fn = scanner.build_scanner(scan_opts, scan_roots)

		local cancel = scan_fn(function(file_path)
			local name = vim.fs.basename(file_path)
			local st = uv.fs_stat(file_path)
			list[#list + 1] = {
				file = file_path,
				text = name,
				dir = false,
				hidden = name:sub(1, 1) == ".",
				size = st and st.size or 0,
				mtime = st and st.mtime and st.mtime.sec or 0,
				type = "file",
			}
			pushed = pushed + 1
			if ctx and ctx.picker and (pushed % 100 == 0) then
				vim.schedule(function()
					if ctx.picker and not ctx.picker.closed then
						ctx.picker:refresh()
					end
				end)
			end
		end, function()
			if ctx and ctx.picker then
				vim.schedule(function()
					if not ctx.picker.closed then
						ctx.picker:refresh()
					end
				end)
			end
		end)

		return list, cancel, scan_roots
	end

	-- DIRECTORY LISTING (non-finder mode)
	local function read_dir(cwd)
		local items = util.scan_directory(cwd, opts)
		-- add "../" entry unless at filesystem root
		local parent = util.safe_dirname(cwd)
		if parent and parent ~= cwd then
			table.insert(items, 1, {
				file = parent,
				text = "../",
				dir = true,
				hidden = false,
				size = 0,
				mtime = 0,
				type = "directory",
			})
		end
		return items
	end

	local initial_cwd = active_root()

	local picker_opts = {
		cwd = initial_cwd,
		title = title_for(state.idx, initial_cwd),

		-- Snacks supports either :items or :finder; we keep your finder shape
		finder = function(_, ctx)
			-- Always rebuild scanner on (re)invoke so it follows state changes
			if opts.use_file_finder then
				local list, cancel = start_scanner(ctx)
				if ctx and ctx.picker then
					-- ensure previous scan is cancelled on re-find or close
					if ctx.picker._fbp_cancel_scan and ctx.picker._fbp_cancel_scan ~= cancel then
						pcall(ctx.picker._fbp_cancel_scan)
					end
					ctx.picker._fbp_cancel_scan = cancel
				end
				return list or {}
			else
				local cwd = (ctx and ctx.picker and ctx.picker:cwd()) or active_root()
				return read_dir(cwd)
			end
		end,

		format = function(item)
			return actions.format_item(item, opts)
		end,

		actions = vim.tbl_extend("force", actions.get_actions(opts), {
			-- open preserves your existing actions.* behavior

			-- Root cycling (always updates cwd for clarity)
			cycle_roots = function(p)
				if #state.roots < 2 then
					vim.notify("Only one root configured", vim.log.levels.INFO)
					return
				end
				state.idx = (state.idx % #state.roots) + 1
				local new_root = active_root()
				p:set_cwd(new_root)
				p.title = title_for(state.idx, new_root)
				p:update_titles()
				p:find({ refresh = true })
			end,
			cycle_roots_prev = function(p)
				if #state.roots < 2 then
					return
				end
				state.idx = ((state.idx - 2) % #state.roots) + 1
				local new_root = active_root()
				p:set_cwd(new_root)
				p.title = title_for(state.idx, new_root)
				p:update_titles()
				p:find({ refresh = true })
			end,

			-- Dynamic roots
			root_add_here = function(p)
				local here = p:cwd()
				-- de-dup
				for i, r in ipairs(state.roots) do
					if vim.fs.normalize(r) == vim.fs.normalize(here) then
						state.idx = i
						p.title = title_for(state.idx, here)
						p:update_titles()
						return
					end
				end
				table.insert(state.roots, state.idx + 1, here)
				state.idx = state.idx + 1
				p.title = title_for(state.idx, here)
				p:update_titles()
			end,

			root_add_path = function(p)
				local path = vim.fn.input("Add root path: ", p:cwd(), "file")
				if path == nil or path == "" then
					return
				end
				path = vim.fn.fnamemodify(vim.fn.expand(path), ":p")
				if vim.fn.isdirectory(path) ~= 1 then
					vim.notify("Not a directory: " .. path, vim.log.levels.WARN)
					return
				end
				table.insert(state.roots, state.idx + 1, path)
				state.idx = state.idx + 1
				p:set_cwd(path)
				p.title = title_for(state.idx, path)
				p:update_titles()
				p:find({ refresh = true })
			end,

			root_pick_suggested = function(p)
				local cand = discover_roots()
				ui_select(cand, "Add workspace root", function(choice)
					if not choice then
						return
					end
					table.insert(state.roots, state.idx + 1, choice)
					state.idx = state.idx + 1
					p:set_cwd(choice)
					p.title = title_for(state.idx, choice)
					p:update_titles()
					p:find({ refresh = true })
				end)
			end,

			root_remove = function(p)
				if #state.roots == 0 then
					return
				end
				table.remove(state.roots, state.idx)
				if #state.roots == 0 then
					state.roots = { util.get_initial_directory(nil) }
				end
				if state.idx > #state.roots then
					state.idx = #state.roots
				end
				local new_root = active_root()
				p:set_cwd(new_root)
				p.title = title_for(state.idx, new_root)
				p:update_titles()
				p:find({ refresh = true })
			end,

			-- Quality-of-life nav (keeps previous dir for "-")
			goto_parent = function(p)
				local cur = p:cwd()
				local parent = util.safe_dirname(cur)
				if parent and parent ~= cur then
					state.prev_dir = cur
					p:set_cwd(parent)
					p.title = title_for(state.idx, parent)
					p:update_titles()
					p:find({ refresh = true })
				end
			end,
			goto_previous_dir = function(p)
				if state.prev_dir and state.prev_dir ~= p:cwd() then
					local tmp = p:cwd()
					p:set_cwd(state.prev_dir)
					state.prev_dir = tmp
					p.title = title_for(state.idx, p:cwd())
					p:update_titles()
					p:find({ refresh = true })
				end
			end,
			goto_project_root = function(p)
				local cur = p:cwd()
				local git = util.get_git_root(cur) or cur
				if git ~= cur then
					state.prev_dir = cur
					p:set_cwd(git)
					p.title = title_for(state.idx, git)
					p:update_titles()
					p:find({ refresh = true })
				end
			end,
		}),

		-- Keep your dynamic layout behavior
		layout = opts.dynamic_layout and {
			cycle = true,
			preset = function()
				return vim.o.columns >= (opts.layout_width_threshold or 120) and "default" or "vertical"
			end,
		} or { preset = "default" },

		-- add keymaps for the new actions without breaking yours
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

		_roots = roots, -- exposed for other modules if you really want
		on_close = function(p)
			if p and p._fbp_cancel_scan then
				pcall(p._fbp_cancel_scan)
				p._fbp_cancel_scan = nil
			end
		end,
	}

	local picker = Snacks.picker.pick(picker_opts)
end

return M
