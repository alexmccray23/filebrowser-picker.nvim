---@class filebrowser-picker.util
local M = {}

--- Get an icon from `mini.icons` or `nvim-web-devicons`, similar to snacks.nvim
--- Returns icon, highlight_group
---@param name string
---@param cat? string defaults to "file"
---@param opts? { fallback?: {dir?:string, file?:string} }
---@return string, string?
function M.icon(name, cat, opts)
	opts = opts or {}
	opts.fallback = opts.fallback or {}
	local try = {
		function()
			return require("mini.icons").get(cat or "file", name)
		end,
		function()
			if cat == "directory" then
				return opts.fallback.dir or "󰉋", "Directory"
			end
			local Icons = require("nvim-web-devicons")
			if cat == "filetype" then
				return Icons.get_icon_by_filetype(name, { default = false })
			elseif cat == "file" then
				local ext = name:match("%.(%w+)$")
				return Icons.get_icon(name, ext, { default = false }) --[[@as string, string]]
			elseif cat == "extension" then
				return Icons.get_icon(nil, name, { default = false }) --[[@as string, string]]
			end
		end,
	}
	for _, fn in ipairs(try) do
		local ret = { pcall(fn) }
		if ret[1] and ret[2] then
			return ret[2], ret[3]
		end
	end
	return opts.fallback.file or "󰈔"
end

--- Get default icons using icon libraries when available
---@return table
function M.get_default_icons()
	local folder_icon = M.icon("folder", "directory", { fallback = { dir = "󰉋" } })
	return {
		folder_closed = folder_icon, -- just the icon string
		folder_open = "󰝰", -- keep simple for open folders
		file = "󰈔", -- fallback for files without specific icons
		symlink = "󰌷", -- symlinks are less common, keep simple fallback
	}
end

return M
