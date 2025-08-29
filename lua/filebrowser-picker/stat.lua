---@class filebrowser-picker.stat
local M = {}

local uv = vim.uv or vim.loop
local util = require("filebrowser-picker.util")

-- Size formatting with units similar to telescope-file-browser
local SIZE_TYPES = { "", "K", "M", "G", "T", "P", "E", "Z" }
local YEAR = os.date("%Y")

-- Highlight groups for different stat components
local SIZE_HL = "Comment"
local DATE_HL = "Comment"
local MODE_HL = "Comment"

-- Size display configuration
M.size = {
	width = 5, -- Match telescope width
	right_justify = true,
	display = function(item)
		local size = item.size or 0
		local formatted_size = size

		for _, v in ipairs(SIZE_TYPES) do
			local type_size = math.abs(formatted_size)
			if type_size < 1024.0 then
				if type_size > 9 then
					return { string.format("%3d%s", formatted_size, v), SIZE_HL }
				else
					return { string.format("%3.1f%s", formatted_size, v), SIZE_HL }
				end
			end
			formatted_size = formatted_size / 1024.0
		end
		return { string.format("%.1f%s", formatted_size, "Y"), SIZE_HL }
	end,
}

-- Date display configuration
M.date = {
	width = 13, -- Match telescope width
	right_justify = true,
	display = function(item)
		local mtime = item.mtime
		if not mtime then
			return { string.format("%13s", ""), DATE_HL }
		end

		if YEAR ~= os.date("%Y", mtime) then
			return { os.date("%b %d  %Y", mtime), DATE_HL }
		end
		return { os.date("%b %d %H:%M", mtime), DATE_HL }
	end,
}

-- Permission/mode display configuration with color-coded permissions
local color_hash = {
	["d"] = "Directory",
	["l"] = "MoreMsg", -- for symlinks
	["s"] = "WarningMsg", -- for sockets
	["r"] = "String", -- read permission
	["w"] = "Identifier", -- write permission
	["x"] = "Function", -- execute permission
	["-"] = MODE_HL, -- no permission
}

local mode_perm_map = {
	["0"] = { "-", "-", "-" },
	["1"] = { "-", "-", "x" },
	["2"] = { "-", "w", "-" },
	["3"] = { "-", "w", "x" },
	["4"] = { "r", "-", "-" },
	["5"] = { "r", "-", "x" },
	["6"] = { "r", "w", "-" },
	["7"] = { "r", "w", "x" },
}

local mode_type_map = {
	["directory"] = "d",
	["link"] = "l",
}

M.mode = {
	width = 10,
	right_justify = false,
	display = function(item)
		-- Get file stat for mode information
		local stat = uv.fs_stat(item.file)
		if not stat then
			return { "----------", MODE_HL }
		end

		-- Use the working util.format_permissions function
		local permissions = util.format_permissions(stat.mode)

		-- Create highlights for individual permission characters
		local highlights = {}
		for i = 1, #permissions do
			local char = permissions:sub(i, i)
			local hl = color_hash[char]
			if hl then
				table.insert(highlights, { { i - 1, i }, hl })
			end
		end

		return {
			permissions,
			function()
				return highlights
			end,
		}
	end,
}

-- Default stat configuration - what to show by default
M.default_stats = {
	mode = true,
	size = true,
	date = true,
}

-- Available stat types for configuration
M.stat_types = {
	mode = M.mode,
	size = M.size,
	date = M.date,
}

--- Calculate total width needed for enabled stats
---@param display_stat table Configuration for which stats to display
---@return number Total width needed for all enabled stats
function M.calculate_stat_width(display_stat)
	local total_width = 0

	if not display_stat then
		return 0
	end

	for stat_name, enabled in pairs(display_stat) do
		if enabled and M.stat_types[stat_name] then
			local stat_config = M.stat_types[stat_name]
			total_width = total_width + stat_config.width + 1 -- +1 for separator
		end
	end

	return total_width
end

--- Build stat display components for an item
---@param item FileBrowserItem The file item to display stats for
---@param display_stat table Configuration for which stats to display
---@return table Array of display components { text, highlight }
function M.build_stat_display(item, display_stat)
	local components = {}

	if not display_stat then
		return components
	end

	-- Process stats in a consistent order - same as telescope-file-browser
	local stat_order = { "mode", "size", "date" }
	local stat_parts = {}

	for _, stat_name in ipairs(stat_order) do
		if display_stat[stat_name] and M.stat_types[stat_name] then
			local stat_config = M.stat_types[stat_name]
			local result = stat_config.display(item)

			if result and result[1] then
				local text = result[1]
				local highlight = result[2]

				-- Apply width formatting and justification like telescope
				if stat_config.width then
					if stat_config.right_justify then
						text = string.format("%" .. stat_config.width .. "s", text)
					else
						text = string.format("%-" .. stat_config.width .. "s", text)
					end
				end

				-- For mode, preserve highlight function, otherwise use simple highlight
				if stat_name == "mode" and type(highlight) == "function" then
					table.insert(stat_parts, { text, highlight })
				else
					table.insert(stat_parts, { text, highlight or "Comment" })
				end
			end
		end
	end

	-- Join all stats with double-space separators like telescope
	if #stat_parts > 0 then
		-- Add the first component (usually mode/permissions)
		if stat_parts[1] then
			table.insert(components, stat_parts[1])
		end

		-- Add remaining stats with double-space separators
		for i = 2, #stat_parts do
			table.insert(components, { "  ", "Normal" })
			table.insert(components, stat_parts[i])
		end
	end

	return components
end

return M
