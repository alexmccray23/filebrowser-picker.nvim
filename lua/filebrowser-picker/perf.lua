-- lua/filebrowser-picker/perf.lua
-- Runtime perf hooks for filebrowser-picker.nvim
-- Drop-in: require("filebrowser-picker.perf").install()
local M = {}

local uv = vim.uv or vim.loop

local function now_ms()
  return uv.now and uv.now() or math.floor((uv.hrtime() or 0) / 1e6)
end

-- -----------------------------------------------------------------------------
-- 1) Cache window width for ~33ms to avoid API churn in item formatter
-- -----------------------------------------------------------------------------
local _w_cache = { win = nil, t = 0, w = nil }
local function cached_win_width()
  local win = vim.api.nvim_get_current_win()
  local t = now_ms()
  if _w_cache.win == win and _w_cache.w and (t - _w_cache.t) < 33 then
    return _w_cache.w
  end
  local w = vim.api.nvim_win_get_width(0)
  _w_cache.win, _w_cache.t, _w_cache.w = win, t, w
  return w
end

-- -----------------------------------------------------------------------------
-- 2) Icon cache (per (cat,name)); avoids repeated plugin lookups
-- -----------------------------------------------------------------------------
local function install_icon_cache(util)
  local orig = util.icon
  local cache = setmetatable({}, { __mode = "kv" }) -- soft
  util.icon = function(name, cat, opts)
    local key = (cat or "file") .. "\n" .. (name or "")
    local hit = cache[key]
    if hit then
      return hit[1], hit[2]
    end
    local i, hl = orig(name, cat, opts)
    cache[key] = { i, hl }
    return i, hl
  end
end

-- -----------------------------------------------------------------------------
-- 3) mode/permissions fast-path: use item.mode if present
-- -----------------------------------------------------------------------------
local function install_mode_fastpath(stat, util_mod)
  local mode_color = {
    ["-"] = "NonText",
    ["r"] = "Constant",
    ["w"] = "Function",
    ["x"] = "Title",
    ["d"] = "Label",
    ["l"] = "Comment",
  }
  local orig_display = stat.mode.display
  stat.mode.display = function(item)
    local m = item and item.mode
    if not m then
      return orig_display(item)
    end
    local perms = util_mod.format_permissions(m)
    local out = {}
    for i = 1, #perms do
      local ch = perms:sub(i, i)
      out[#out + 1] = { ch, mode_color[ch] or "NonText" }
    end
    return out
  end
end

-- -----------------------------------------------------------------------------
-- 4) Replace actions.format_item with an aligned, cached-width variant
-- -----------------------------------------------------------------------------
local function install_format_patch(actions, util_mod, stat_mod, git_mod)
  local function trunc_middle(s, maxw)
    if #s <= maxw then
      return s
    end
    if maxw <= 3 then
      return s:sub(1, maxw)
    end
    local left = math.floor((maxw - 1) / 2)
    local right = maxw - 1 - left
    return s:sub(1, left) .. "…" .. s:sub(#s - right + 1)
  end

  actions._fbp_orig_format_item = actions._fbp_orig_format_item or actions.format_item
  actions.format_item = function(item, opts)
    -- Icons + name highlight
    local icon, icon_hl = "", nil
    local text_hl = "Normal"
    if item.dir then
      icon, icon_hl = util_mod.icon(item.text, "directory", { fallback = { file = (opts.icons and opts.icons.folder_closed) or "󰉋" } })
      text_hl = "Directory"
    elseif item.type == "link" then
      icon = (opts.icons and opts.icons.symlink) or "󰌷"
      icon_hl = "Special"
      text_hl = "Normal"
    else
      icon, icon_hl = util_mod.icon(item.text, "file", { fallback = { file = (opts.icons and opts.icons.file) or "󰈔" } })
    end

    -- Git badge (left gutter)
    local git_icon, git_hl = " ", "Normal"
    if opts.git_status and git_mod and git_mod.get_status_sync then
      local st = git_mod.get_status_sync(item.file)
      if st then
        git_icon = (opts.icons and opts.icons.git and (st == "staged" and opts.icons.git.staged or opts.icons.git[st])) or git_icon
        git_hl = (opts.git_status_hl and opts.git_status_hl[st]) or git_hl
      end
    end

    local detailed = opts.detailed_view
    if not detailed then
      return {
        { git_icon .. " ", git_hl },
        { icon .. " ", icon_hl or "Normal" },
        { item.text, text_hl },
      }
    end

    -- Detailed view
    local display_stat = opts.display_stat or stat_mod.default_stats
    local stat_components = stat_mod.build_stat_display(item, display_stat, opts)

    -- Fixed stat width for clean alignment
    local stat_width = stat_mod.calculate_stat_width(display_stat)

    local win_w = cached_win_width()
    local filename_width = #item.text + 2 -- icon + space
    local reserved = stat_width + 3 -- git + margins
    local avail = math.max(0, math.floor(win_w * 0.99) - reserved)
    local name_max = math.max(8, avail - 4) -- keep some air

    local shown_name = trunc_middle(item.text, name_max)

    local res = {
      { git_icon .. " ", git_hl },
      { icon .. " ", icon_hl or "Normal" },
      { shown_name, text_hl },
    }

    -- pad between name and stats
    local pad = math.max(1, (math.floor(win_w * 0.95) - (#shown_name + 2) - stat_width))
    pad = math.min(pad, 80)
    res[#res + 1] = { string.rep(" ", pad), "Normal" }

    for _, comp in ipairs(stat_components) do
      if type(comp) == "table" and comp[1] then
        local txt, hl = comp[1], comp[2] or "Comment"
        if type(hl) == "function" then
          local out = hl(txt)
          if type(out) == "table" then
            for _, c in ipairs(out) do
              res[#res + 1] = c
            end
          else
            res[#res + 1] = { tostring(out), "Comment" }
          end
        else
          res[#res + 1] = { txt, hl }
        end
      end
    end

    return res
  end
end

function M.install()
  local ok_actions, actions = pcall(require, "filebrowser-picker.actions")
  local ok_stat, stat = pcall(require, "filebrowser-picker.stat")
  local ok_util, util = pcall(require, "filebrowser-picker.util")
  local ok_git, git = pcall(require, "filebrowser-picker.git")

  if ok_util then
    install_icon_cache(util)
  end
  if ok_stat and ok_util then
    install_mode_fastpath(stat, util)
  end
  if ok_actions and ok_util and ok_stat then
    install_format_patch(actions, util, stat, ok_git and git or nil)
  end
end

return M
