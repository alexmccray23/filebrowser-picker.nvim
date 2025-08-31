---@class filebrowser-picker.roots
local M = {}

local util = require("filebrowser-picker.util")
local notify = require("filebrowser-picker.notify")

---Normalize roots configuration into a valid list of directories
---@param opts table Configuration options
---@return string[] List of valid root directories
function M.normalize_roots(opts)
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

			-- Use async-safe directory check
			local uv = vim.uv or vim.loop
			local stat = uv.fs_stat(absolute_root)
			if stat and stat.type == "directory" then
				table.insert(valid_roots, absolute_root)
			else
				notify.warn("Invalid root directory: " .. root .. " (expanded: " .. absolute_root .. ")")
			end
		end
		roots = #valid_roots > 0 and valid_roots or { util.get_initial_directory(opts.cwd) }
	end

	return roots
end

---Generate title for picker showing current root context with enhanced badge
---@param root_idx number Current root index
---@param roots string[] All available roots
---@param dir? string Current directory (defaults to active root)
---@return string Formatted title
function M.title_for(root_idx, roots, dir)
	local path = dir or roots[root_idx]
	if #roots > 1 then
		-- Enhanced multi-root badge with root name
		local root_name = vim.fn.fnamemodify(roots[root_idx], ":t") or "root"
		return string.format("󰉋 [%d/%d:%s] %s", root_idx, #roots, root_name, path)
	else
		return path
	end
end

---Discover potential workspace roots (git, LSP, home, cwd)
---@return string[] List of discovered root directories
function M.discover_roots()
	local out, seen = {}, {}
	local function add(p)
		if not p or p == "" then
			return
		end
		p = vim.fs.normalize(vim.fn.fnamemodify(p, ":p"))
		-- Use async-safe directory check
		local uv = vim.uv or vim.loop
		local stat = uv.fs_stat(p)
		if stat and stat.type == "directory" and not seen[p] then
			out[#out + 1] = p
			seen[p] = true
		end
	end

	-- Add common root candidates (cached for performance)
	add(vim.fn.getcwd())
	add((vim.uv or vim.loop).os_homedir())

	-- Find git root (async-safe alternative)
	local current_dir = vim.fn.getcwd()
	local git_root = util.get_git_root(current_dir)
	if git_root then
		add(git_root)
	end

	-- LSP workspace folders
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

---Create root management actions for picker
---@param state table Multi-root state object
---@param ui_select function UI selection function
---@return table Root management actions
function M.create_actions(state, ui_select)
	local function active_root()
		return state.roots[state.idx]
	end

	local function update_picker_root(picker, new_root, new_idx)
		if new_idx then
			state.idx = new_idx
		end
		picker:set_cwd(new_root or active_root())
		picker.title = M.title_for(state.idx, state.roots, new_root)
		picker:update_titles()
		picker:find({ refresh = true })
	end

	return {
		cycle_roots = function(picker)
			if #state.roots < 2 then
				-- Fallback to list navigation when only one root
				picker:action("list_down")
				return
			end
			local new_idx = (state.idx % #state.roots) + 1
			update_picker_root(picker, state.roots[new_idx], new_idx)
		end,

		cycle_roots_prev = function(picker)
			if #state.roots < 2 then
				-- Fallback to list navigation when only one root
				picker:action("list_up")
				return
			end
			local new_idx = ((state.idx - 2) % #state.roots) + 1
			update_picker_root(picker, state.roots[new_idx], new_idx)
		end,

		root_add_here = function(picker)
			local here = picker:cwd()
			-- Check for duplicates
			for i, r in ipairs(state.roots) do
				if vim.fs.normalize(r) == vim.fs.normalize(here) then
					update_picker_root(picker, here, i)
					return
				end
			end
			-- Add new root
			table.insert(state.roots, state.idx + 1, here)
			update_picker_root(picker, here, state.idx + 1)
		end,

		root_add_path = function(picker)
			local path = vim.fn.input("Add root path: ", picker:cwd(), "file")
			if path == nil or path == "" then
				return
			end
			-- Expand and normalize path
			local expanded = vim.fn.expand(path)
			path = vim.fn.fnamemodify(expanded, ":p")
			
			-- Check if directory exists
			local uv = vim.uv or vim.loop
			local stat = uv.fs_stat(path)
			if not stat or stat.type ~= "directory" then
				notify.warn("Not a directory: " .. path)
				return
			end
			table.insert(state.roots, state.idx + 1, path)
			update_picker_root(picker, path, state.idx + 1)
		end,

		root_pick_suggested = function(picker)
			local candidates = M.discover_roots()
			ui_select(candidates, "Add workspace root", function(choice)
				if not choice then
					return
				end
				table.insert(state.roots, state.idx + 1, choice)
				update_picker_root(picker, choice, state.idx + 1)
			end)
		end,

		root_remove = function(picker)
			if #state.roots <= 1 then
				notify.warn("Cannot remove the last root")
				return
			end
			table.remove(state.roots, state.idx)
			if state.idx > #state.roots then
				state.idx = #state.roots
			end
			update_picker_root(picker)
		end,

		root_jump = function(picker)
			if #state.roots <= 1 then
				notify.info("Only one root available")
				return
			end
			
			-- Create formatted list of roots for selection
			local root_options = {}
			for i, root in ipairs(state.roots) do
				local display = string.format("[%d] %s", i, root)
				if i == state.idx then
					display = display .. " (current)"
				end
				table.insert(root_options, display)
			end
			
			ui_select(root_options, "Jump to root:", function(choice, idx)
				if choice and idx then
					update_picker_root(picker, state.roots[idx], idx)
				end
			end)
		end,

		show_recent_dirs = function(picker)
			local history = require("filebrowser-picker.history")
			local opts = (picker and picker.opts and picker.opts.opts) or {}
			local recent_dirs = history.get_recent_dirs(opts.history_file, 10)
			
			if #recent_dirs == 0 then
				notify.info("No recent directories")
				return
			end
			
			ui_select(recent_dirs, "Recent directories:", function(choice)
				if choice then
					-- Navigate to selected directory
					local current = picker:cwd()
					if current ~= choice then
						picker:set_cwd(choice)
						picker:find({ refresh = true })
					end
				end
			end)
		end,

		show_recent_roots = function(picker)
			local history = require("filebrowser-picker.history")
			local opts = (picker and picker.opts and picker.opts.opts) or {}
			local recent_roots = history.get_recent_roots(opts.history_file, 5)
			
			if #recent_roots == 0 then
				notify.info("No recent root configurations")
				return
			end
			
			local root_options = {}
			for _, entry in ipairs(recent_roots) do
				local display = table.concat(entry.roots, ", ")
				table.insert(root_options, display)
			end
			
			ui_select(root_options, "Recent root configurations:", function(choice, idx)
				if choice and idx then
					local selected_roots = recent_roots[idx].roots
					-- Update current state with selected roots
					state.roots = selected_roots
					state.idx = 1
					update_picker_root(picker, selected_roots[1], 1)
				end
			end)
		end,
	}
end

return M
