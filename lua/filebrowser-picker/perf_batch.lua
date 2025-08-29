-- lua/filebrowser-picker/perf_batch.lua
-- Opt-in batching/throttled refresh for filebrowser-picker.nvim
-- Enable with: require("filebrowser-picker.perf_batch").install()
local M = {}

local uv = vim.uv or vim.loop

-- Simple trailing-edge debounce (also acts like a throttle when called in bursts)
local function make_debounced_refresh(picker, min_delay_ms)
  local timer, pending = uv.new_timer(), false
  local closed = false

  local function stop()
    if timer then
      pcall(timer.stop, timer)
      pcall(timer.close, timer)
      timer = nil
    end
    closed = true
  end

  local function fire()
    if closed or not picker or picker.closed then return end
    pending = false
    -- pcall to avoid noisy errors if picker is closing
    pcall(function() picker:refresh() end)
  end

  local function schedule()
    if closed or not picker or picker.closed then return end
    if not timer then return end
    if not pending then
      pending = true
      timer:start(min_delay_ms, 0, vim.schedule_wrap(fire))
    end
  end

  return schedule, stop
end

-- Wrap the growing `list` with a metatable that detects appends
local function wrap_list_with_refresh(list, on_append)
  local proxy = {}
  local mt = {
    __index = list,
    __len = function() return #list end,
    __pairs = function() return pairs(list) end,
    __ipairs = function() return ipairs(list) end,
    __newindex = function(_, k, v)
      -- Forward the write
      list[k] = v
      -- Trigger only on numeric appends (k == #list)
      if type(k) == "number" and k == #list then
        on_append()
      end
    end,
  }
  return setmetatable(proxy, mt)
end

function M.install(opts)
  opts = opts or {}
  local refresh_ms = tonumber(opts.refresh_ms) or 16  -- ~60fps

  local ok, finder = pcall(require, "filebrowser-picker.finder")
  if not ok or type(finder.start_scanner) ~= "function" then
    return
  end

  -- Keep original
  finder._fbp_orig_start_scanner = finder._fbp_orig_start_scanner or finder.start_scanner

  finder.start_scanner = function(start_opts, state, ctx)
    -- Call original to create its list/cancel/roots
    local list, cancel, roots = finder._fbp_orig_start_scanner(start_opts, state, ctx)
    -- Only batch in file-finder mode (where list is used and grows over time)
    if not start_opts or not start_opts.use_file_finder or not ctx or not ctx.picker or type(list) ~= "table" then
      return list, cancel, roots
    end

    -- Debounced refresh bound to this picker
    local schedule_refresh, stop_refresh = make_debounced_refresh(ctx.picker, refresh_ms)

    -- Wrap list so appends schedule a single near-future refresh
    local wrapped = wrap_list_with_refresh(list, schedule_refresh)

    -- Wrap cancel so timers are cleaned up
    local wrapped_cancel = function()
      stop_refresh()
      if type(cancel) == "function" then
        pcall(cancel)
      end
    end

    -- Ensure we stop when the picker closes as well
    if ctx.picker then
      local orig_on_close = ctx.picker.on_close
      ctx.picker.on_close = function(...)
        stop_refresh()
        if type(orig_on_close) == "function" then
          pcall(orig_on_close, ...)
        end
      end
    end

    return wrapped, wrapped_cancel, roots
  end
end

return M

