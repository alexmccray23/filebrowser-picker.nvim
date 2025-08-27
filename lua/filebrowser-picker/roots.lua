---@class filebrowser-picker.roots
local M = {}

local util = require("filebrowser-picker.util")

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

---Generate title for picker showing current root context
---@param root_idx number Current root index
---@param roots string[] All available roots
---@param dir? string Current directory (defaults to active root)
---@return string Formatted title
function M.title_for(root_idx, roots, dir)
	local path = dir or roots[root_idx]
	return (#roots > 1) and string.format("[%d/%d] %s", root_idx, #roots, path) or path
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
		if vim.fn.isdirectory(p) == 1 and not seen[p] then
			out[#out + 1] = p
			seen[p] = true
		end
	end

	-- Add common root candidates
	add(vim.fn.getcwd())
	add(vim.loop.os_homedir())

	-- Find git root
	local gitdir = vim.fs.find(".git", { upward = true, stop = vim.loop.os_homedir() })[1]
	if gitdir then
		add(vim.fs.dirname(gitdir))
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
				vim.notify("Only one root configured", vim.log.levels.INFO)
				return
			end
			local new_idx = (state.idx % #state.roots) + 1
			update_picker_root(picker, state.roots[new_idx], new_idx)
		end,

		cycle_roots_prev = function(picker)
			if #state.roots < 2 then
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
			path = vim.fn.fnamemodify(vim.fn.expand(path), ":p")
			if vim.fn.isdirectory(path) ~= 1 then
				vim.notify("Not a directory: " .. path, vim.log.levels.WARN)
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
				vim.notify("Cannot remove the last root", vim.log.levels.WARN)
				return
			end
			table.remove(state.roots, state.idx)
			if state.idx > #state.roots then
				state.idx = #state.roots
			end
			update_picker_root(picker)
		end,
	}
end

return M
