---@class FileBrowserBench
local M = {}

local scanner = require "filebrowser-picker.scanner"
local notify = require "filebrowser-picker.notify"
local uv = vim.uv or vim.loop

---Profile scanner performance for a directory
---@param opts? table Options with path
function M.profile_scanners(opts)
  opts = opts or {}
  local test_path = opts.path or vim.uv.cwd() or "."

  -- Ensure path exists
  local stat = uv.fs_stat(test_path)
  if not stat or stat.type ~= "directory" then
    notify.error("Path is not a directory: " .. test_path)
    return
  end

  notify.info("Profiling scanners for: " .. vim.fn.fnamemodify(test_path, ":~:."))

  local results = {}
  local scanner_configs = {
    { name = "fd", opts = { hidden = false, respect_gitignore = true, max_depth = 32 } },
    { name = "rg", opts = { hidden = false, respect_gitignore = true, max_depth = 32 } },
    { name = "uv", opts = { hidden = false, respect_gitignore = true, max_depth = 32 } },
  }

  -- Test each scanner
  for _, config in ipairs(scanner_configs) do
    local start_time = uv.hrtime()
    local file_count = 0
    local completed = false

    -- Get the scanner function
    local scan_fn = scanner.build_scanner(config.opts, { test_path })

    if scan_fn then
      -- Run the scan
      scan_fn(function(file_path)
        file_count = file_count + 1
      end, function()
        completed = true
        local end_time = uv.hrtime()
        local duration_ms = (end_time - start_time) / 1e6

        results[config.name] = {
          duration_ms = duration_ms,
          file_count = file_count,
          files_per_second = math.floor(file_count / (duration_ms / 1000)),
          available = true,
        }
      end)

      -- Wait for completion (with timeout)
      local timeout = 30000 -- 30 seconds
      local elapsed = 0
      local check_interval = 50 -- 50ms

      while not completed and elapsed < timeout do
        vim.wait(check_interval)
        elapsed = elapsed + check_interval
      end

      if not completed then
        results[config.name] = {
          duration_ms = timeout,
          file_count = 0,
          files_per_second = 0,
          available = true,
          timeout = true,
        }
      end
    else
      results[config.name] = {
        duration_ms = 0,
        file_count = 0,
        files_per_second = 0,
        available = false,
      }
    end
  end

  -- Display results
  M._display_results(test_path, results)
end

---Display profiling results
---@param path string The tested path
---@param results table Scanner results
function M._display_results(path, results)
  local lines = {
    "",
    "=== File Browser Scanner Benchmark ===",
    "Path: " .. vim.fn.fnamemodify(path, ":~:."),
    "",
  }

  -- Sort results by performance (fastest first)
  local sorted_scanners = {}
  for name, result in pairs(results) do
    table.insert(sorted_scanners, { name = name, result = result })
  end

  table.sort(sorted_scanners, function(a, b)
    if not a.result.available then
      return false
    end
    if not b.result.available then
      return true
    end
    if a.result.timeout then
      return false
    end
    if b.result.timeout then
      return true
    end
    return a.result.duration_ms < b.result.duration_ms
  end)

  -- Display results
  for i, entry in ipairs(sorted_scanners) do
    local name = entry.name
    local result = entry.result
    local rank = i == 1 and not result.timeout and result.available and " 🏆" or ""

    if not result.available then
      table.insert(lines, string.format("%s: Not available", name))
    elseif result.timeout then
      table.insert(lines, string.format("%s: Timeout (>30s)", name))
    else
      table.insert(lines, string.format("%s%s: %.2fms | %d files | %d files/sec", name, rank, result.duration_ms, result.file_count, result.files_per_second))
    end
  end

  table.insert(lines, "")

  -- Show recommendations
  local fastest = sorted_scanners[1]
  if fastest and fastest.result.available and not fastest.result.timeout then
    table.insert(lines, "💡 Fastest: " .. fastest.name .. " scanner (" .. fastest.result.files_per_second .. " files/sec)")
    
    -- Show balanced perspective
    if fastest.name == "uv" then
      table.insert(lines, "   Note: fd/rg offer additional features like advanced gitignore patterns and exclude options")
    else
      table.insert(lines, "   Note: All scanners have good performance - choice depends on specific needs")
    end
  end

  table.insert(lines, "")

  -- Create floating window for results
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "text"
  vim.bo[buf].modifiable = false

  local width = 80
  local height = #lines + 2
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " Scanner Benchmark Results ",
    title_pos = "center",
  })

  -- Set window options
  vim.wo[win].wrap = false

  -- Close window on any key
  vim.keymap.set("n", "<Esc>", "<cmd>close<cr>", { buffer = buf })
  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf })
  vim.keymap.set("n", "<CR>", "<cmd>close<cr>", { buffer = buf })
end

return M
