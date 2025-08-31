-- lua/filebrowser-picker/perf_batch.lua
-- Opt-in batching/throttled refresh for filebrowser-picker.nvim
-- Enable with: require("filebrowser-picker.perf_batch").install()
local M = {}

local uv = vim.uv or vim.loop

-- Smart auto-tuning batching with adaptive batch sizes
local function make_smart_debounced_refresh(picker, base_delay_ms)
  local timer, pending = uv.new_timer(), false
  local closed = false
  local item_count = 0
  local last_update = uv.hrtime()

  -- Auto-tuning parameters
  local min_delay = base_delay_ms or 16
  local max_delay = 200
  local batch_thresholds = {
    small = { max_items = 100, batch_size = 25, delay = min_delay },
    medium = { max_items = 1000, batch_size = 100, delay = min_delay * 2 },
    large = { max_items = math.huge, batch_size = 200, delay = min_delay * 4 },
  }
  local current_batch_size = batch_thresholds.small.batch_size
  local current_delay = min_delay

  local function stop()
    if timer then
      pcall(timer.stop, timer)
      pcall(timer.close, timer)
      timer = nil
    end
    closed = true
  end

  local function auto_tune()
    -- Determine appropriate batch size and delay based on item count
    if item_count <= batch_thresholds.small.max_items then
      current_batch_size = batch_thresholds.small.batch_size
      current_delay = batch_thresholds.small.delay
    elseif item_count <= batch_thresholds.medium.max_items then
      current_batch_size = batch_thresholds.medium.batch_size
      current_delay = batch_thresholds.medium.delay
    else
      current_batch_size = batch_thresholds.large.batch_size
      current_delay = batch_thresholds.large.delay
    end
  end

  local function fire()
    if closed or not picker or picker.closed then
      return
    end
    pending = false
    last_update = uv.hrtime()
    -- pcall to avoid noisy errors if picker is closing
    pcall(function()
      picker:refresh()
    end)
  end

  local function schedule(new_item_count)
    if closed or not picker or picker.closed then
      return
    end
    if not timer then
      return
    end

    -- Update item count for auto-tuning
    if new_item_count then
      item_count = new_item_count
      auto_tune()
    end

    -- Only schedule if we don't have a pending refresh or if enough time has passed
    local now = uv.hrtime()
    local time_since_update = (now - last_update) / 1000000 -- Convert to ms

    if not pending and time_since_update >= current_delay then
      -- Immediate refresh for small changes
      fire()
    elseif not pending then
      -- Schedule batched refresh
      pending = true
      timer:start(current_delay, 0, vim.schedule_wrap(fire))
    end
  end

  return schedule, stop, function()
    return current_batch_size, current_delay
  end
end

-- Legacy simple debounced refresh for backward compatibility
local function make_debounced_refresh(picker, min_delay_ms)
  local schedule, stop = make_smart_debounced_refresh(picker, min_delay_ms)
  return function()
    schedule()
  end, stop
end

-- Wrap the growing `list` with a metatable that detects appends
local function wrap_list_with_refresh(list, on_append)
  local proxy = {}
  local mt = {
    __index = list,
    __len = function()
      return #list
    end,
    __pairs = function()
      return pairs(list)
    end,
    __ipairs = function()
      return ipairs(list)
    end,
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
  local refresh_ms = tonumber(opts.refresh_ms) or 16 -- ~60fps

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
