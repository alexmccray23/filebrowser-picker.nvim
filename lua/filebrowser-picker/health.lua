local M = {}

local config = require "filebrowser-picker.config"

local has = function(mod)
  local ok, pkg = pcall(require, mod)
  return ok and pkg or nil
end

local function get_health()
  if vim.health and vim.health.start then
    return vim.health
  end
  return vim.health.report
end

local health = get_health()

local function start(msg)
  if health.start then
    health.start(msg)
  else
    health.report_start(msg)
  end
end

local function ok(msg)
  if health.ok then
    health.ok(msg)
  else
    health.report_ok(msg)
  end
end

local function warn(msg)
  if health.warn then
    health.warn(msg)
  else
    health.report_warn(msg)
  end
end

local function error(msg)
  if health.error then
    health.error(msg)
  else
    health.report_error(msg)
  end
end

local function check_version()
  start "Neovim version"
  local ver = vim.version()
  local function encode(v)
    return (v.major * 10000) + (v.minor * 100) + v.patch
  end
  local current = encode(ver)
  local required = encode { major = 0, minor = 9, patch = 4 }
  if current >= required then
    ok(string.format("Neovim %d.%d.%d", ver.major, ver.minor, ver.patch))
  else
    error("filebrowser-picker.nvim requires Neovim >= 0.9.4")
  end
end

local function check_dependencies()
  start "Required dependencies"
  if has "snacks" then
    ok "snacks.nvim found"
  else
    error "snacks.nvim is not installed; picker cannot start"
  end

  if has "filebrowser-picker" then
    ok "filebrowser-picker modules load"
  else
    error "Unable to require filebrowser-picker"
  end
end

local function check_optional_modules()
  start "Optional integrations"
  if has "mini.icons" or has "nvim-web-devicons" then
    ok "Icon provider detected"
  else
    warn "No icon provider detected; fallback glyphs will be used"
  end

  if has "trash" or vim.fn.executable "trash" == 1 or vim.fn.executable "trash-put" == 1 then
    ok "Trash utility available"
  else
    warn "No trash utility detected; deletions will be permanent unless `use_trash` is disabled"
  end
end

local function check_cli_tools(cfg)
  start "External CLI tools"

  if cfg.use_fd and vim.fn.executable "fd" == 0 then
    warn "fd not found; falling back to built-in scanner (set `use_fd=false` to silence)"
  else
    ok "fd available"
  end

  if cfg.use_rg and vim.fn.executable "rg" == 0 then
    warn "ripgrep not found; fast filtering disabled (set `use_rg=false` to silence)"
  else
    ok "ripgrep available"
  end

  if vim.fn.executable "git" == 0 then
    warn "git not found; git status badges will be disabled"
  else
    ok "git available"
  end
end

local function check_history(cfg)
  start "History configuration"
  local history_file = cfg.history_file or config.defaults.history_file
  local dir = vim.fn.fnamemodify(history_file, ":h")
  if vim.fn.isdirectory(dir) == 1 then
    if vim.fn.filewritable(dir) == 1 then
      ok("History directory writable: " .. dir)
    else
      warn("History directory exists but is not writable: " .. dir)
    end
  else
    local parent = vim.fn.fnamemodify(dir, ":h")
    if vim.fn.filewritable(parent) == 1 then
      warn("History directory missing; will be created on demand: " .. dir)
    else
      error("Cannot create history directory (parent not writable): " .. dir)
    end
  end
end

function M.check()
  local cfg = config.get()
  check_version()
  check_dependencies()
  check_optional_modules()
  check_cli_tools(cfg)
  check_history(cfg)
end

return M
