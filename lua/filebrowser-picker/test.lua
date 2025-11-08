local M = {}

local uv = vim.uv or vim.loop

---@class TestCase
---@field name string
---@field fn fun()
local tests = {}

local function add(name, fn)
  table.insert(tests, { name = name, fn = fn })
end

local function ok(condition, message)
  if not condition then
    error(message or "assertion failed")
  end
end

local function eq(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    local inspect = vim.inspect
    error(message or string.format("expected %s, got %s", inspect(expected), inspect(actual)))
  end
end

local function normalize(path)
  if vim.fs and vim.fs.normalize then
    return vim.fs.normalize(path)
  end
  return vim.fn.fnamemodify(path, ":p")
end

local function with_tmpdir(fn)
  local template = string.format("%s/filebrowser-picker-%s", uv.os_tmpdir(), "XXXXXX")
  local dir = uv.fs_mkdtemp(template)
  assert(dir, "failed to create temp directory")
  local ok_call, value = pcall(fn, dir)
  vim.fn.delete(dir, "rf")
  if not ok_call then
    error(value)
  end
  return value
end

-- ============================================================================
-- Config tests
-- ============================================================================

local config = require "filebrowser-picker.config"

add("config.setup merges defaults", function()
  config.setup { hidden = true, performance = { ui_optimizations = true } }
  local current = config.get()
  ok(current.hidden, "hidden flag not applied")
  ok(current.performance.ui_optimizations, "ui_optimizations not set")
  eq(current.performance.refresh_batching, false, "default batching flag changed")
  eq(current.keymaps["<CR>"], "confirm", "default keymaps lost")
  config.setup()
end)

add("config hijack alias updates replace_netrw", function()
  config.setup { hijack_netrw = true }
  ok(config.get().replace_netrw, "hijack flag failed to set replace_netrw")
  config.setup { hijack_netrw = false, replace_netrw = false }
  eq(config.get().replace_netrw, false, "explicit replace_netrw should win")
  config.setup()
end)

add("config set/get_value support dot notation", function()
  config.setup()
  config.set("performance.refresh_rate_ms", 33)
  eq(config.get_value("performance.refresh_rate_ms"), 33)
  config.set("performance.batch.enabled", true)
  eq(config.get_value("performance.batch.enabled"), true)
  eq(config.get_value("performance.missing.key"), nil)
  config.setup()
end)

-- ============================================================================
-- Roots tests
-- ============================================================================

local roots = require "filebrowser-picker.roots"

add("roots.normalize_roots falls back to cwd when unset", function()
  with_tmpdir(function(dir)
    local result = roots.normalize_roots { cwd = dir }
    eq(result, { dir })
  end)
end)

add("roots.normalize_roots filters invalid directories", function()
  with_tmpdir(function(dir)
    local opts = {
      cwd = dir,
      roots = { "/definitely/invalid/path" },
    }
    local result = roots.normalize_roots(opts)
    eq(result, { dir })
  end)
end)

add("roots.normalize_roots keeps absolute directories", function()
  with_tmpdir(function(dir)
    local other = dir .. "/child"
    vim.fn.mkdir(other, "p")
    local abs = vim.fn.fnamemodify(other, ":p")
    local result = roots.normalize_roots { roots = { other }, cwd = dir }
    eq(result, { abs })
  end)
end)

add("roots.title_for annotates multi-root context", function()
  with_tmpdir(function(dir)
    local other = dir .. "/other"
    vim.fn.mkdir(other, "p")
    local nested = dir .. "/nested"
    vim.fn.mkdir(nested, "p")
    local root_list = { dir, other }
    local expected = string.format("󰉋 [1/2:%s] %s", vim.fn.fnamemodify(dir, ":t"), nested)
    eq(roots.title_for(1, root_list, nested), expected)
    eq(roots.title_for(1, { dir }, nil), dir)
  end)
end)

-- ============================================================================
-- Util tests
-- ============================================================================

local util = require "filebrowser-picker.util"

add("util.format_permissions handles directories and files", function()
  eq(util.format_permissions(tonumber("040755", 8)), "drwxr-xr-x")
  eq(util.format_permissions(tonumber("0100644", 8)), ".rw-r--r--")
end)

add("util.format_size handles auto and bytes modes", function()
  eq(util.format_size(512), "512B")
  eq(util.format_size(1536), "1.5K")
  eq(util.format_size(2048, "bytes"), "2048B")
end)

add("util.format_timestamp switches format based on age", function()
  eq(util.format_timestamp(0, "%Y"), os.date("%Y", 0))
  local recent = util.format_timestamp(os.time() - 5 * 24 * 3600)
  ok(recent:match("%d%d:%d%d"), "recent timestamp should include time")
  local old = util.format_timestamp(os.time() - 200 * 24 * 3600)
  ok(old:match("%d%d%d%d$"), "old timestamp should end with year")
end)

add("util.safe_dirname trims last path segment", function()
  eq(util.safe_dirname("/a/b/c"), "/a/b")
  eq(util.safe_dirname("/single"), "/")
  eq(util.safe_dirname("/"), "/")
end)

add("util.sort_items prioritizes directories and respects sort options", function()
  local items = {
    { text = "b", dir = false, size = 10, mtime = 100 },
    { text = "a", dir = false, size = 5, mtime = 50 },
    { text = "dir", dir = true, size = 0, mtime = 0 },
  }
  util.sort_items(items, { sort_by = "name" })
  eq({ items[1].text, items[2].text, items[3].text }, { "dir", "a", "b" })
  util.sort_items(items, { sort_by = "size", sort_reverse = true })
  eq({ items[1].text, items[2].text, items[3].text }, { "dir", "b", "a" })
end)

add("util.get_git_root caches and clears lookups", function()
  with_tmpdir(function(dir)
    local git_dir = dir .. "/.git"
    vim.fn.mkdir(git_dir, "p")
    local nested = dir .. "/nested/deeper"
    vim.fn.mkdir(nested, "p")

    util.clear_git_root_cache()
    local root = util.get_git_root(nested)
    eq(normalize(root), normalize(dir))

    -- cache should still return the old root even if .git disappears
    vim.fn.delete(git_dir, "rf")
    eq(normalize(util.get_git_root(nested) or ""), normalize(dir))

    util.clear_git_root_cache()
    eq(util.get_git_root(nested), nil)
  end)
end)

-- ============================================================================
-- History tests
-- ============================================================================

local history = require "filebrowser-picker.history"

add("history.add_to_history maintains recency order", function()
  with_tmpdir(function(dir)
    local history_file = dir .. "/history.json"
    local a = dir .. "/a"
    local b = dir .. "/b"
    vim.fn.mkdir(a, "p")
    vim.fn.mkdir(b, "p")

    history.add_to_history(a, history_file)
    history.add_to_history(b, history_file)
    history.add_to_history(a, history_file)

    local data = history.load_history(history_file)
    eq(data.last_dir, a)
    eq(data.recent_dirs[#data.recent_dirs], a)
    eq(#data.recent_dirs, 2)

    local recent = history.get_recent_dirs(history_file, 5)
    eq(recent[1], a)
    eq(recent[2], b)
  end)
end)

add("history roots helpers record and filter entries", function()
  with_tmpdir(function(dir)
    local history_file = dir .. "/history.json"
    local root1 = dir .. "/workspace1"
    local root2 = dir .. "/workspace2"
    vim.fn.mkdir(root1, "p")
    vim.fn.mkdir(root2, "p")

    history.add_roots_to_history({ root1, root2 }, history_file)
    local recent = history.get_recent_roots(history_file, 1)
    eq(#recent, 1)
    eq(recent[1].roots, { root1, root2 })

    ok(history.clear_history(history_file))
    eq(vim.fn.filereadable(history_file), 0)
  end)
end)

-- ============================================================================
-- Runner
-- ============================================================================

---Run all registered tests
---@param opts? { verbose?: boolean }
function M.run_all_tests(opts)
  opts = opts or {}
  local started = uv.hrtime()
  local passed, failed = 0, 0
  local lines = {}

  for _, test in ipairs(tests) do
    local ok_call, err = pcall(test.fn)
    if ok_call then
      passed = passed + 1
      if opts.verbose then
        table.insert(lines, "✓ " .. test.name)
      end
    else
      failed = failed + 1
      table.insert(lines, "✗ " .. test.name .. "\n  " .. err)
    end
  end

  local duration_ms = (uv.hrtime() - started) / 1e6
  table.insert(lines, string.format("filebrowser-picker tests: %d passed, %d failed in %.2fms", passed, failed, duration_ms))

  for _, line in ipairs(lines) do
    print(line)
  end

  if failed > 0 then
    error("test run failed")
  end
end

return M
