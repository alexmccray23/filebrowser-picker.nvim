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

local function with_overrides(entries, fn)
  local originals = {}
  for _, entry in ipairs(entries) do
    local target, key, value = entry[1], entry[2], entry[3]
    originals[#originals + 1] = { target, key, target[key] }
    target[key] = value
  end
  local ok_call, result = pcall(fn)
  for i = #originals, 1, -1 do
    local target, key, original_value = originals[i][1], originals[i][2], originals[i][3]
    target[key] = original_value
  end
  if not ok_call then
    error(result)
  end
  return result
end

local function with_health_recorder(fn)
  local calls = { start = {}, ok = {}, warn = {}, error = {} }
  local stub = {}
  for name in pairs(calls) do
    stub[name] = function(msg)
      table.insert(calls[name], msg)
    end
  end
  stub._calls = calls
  local original = vim.health
  vim.health = stub
  local ok_call, res = pcall(fn, stub)
  vim.health = original
  if not ok_call then
    error(res)
  end
  return stub
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
-- Integration tests
-- ============================================================================

add("file_browser configures multi-root picker state", function()
  with_tmpdir(function(dir)
    local root_a = vim.fn.fnamemodify(dir .. "/a", ":p")
    local root_b = vim.fn.fnamemodify(dir .. "/b", ":p")
    vim.fn.mkdir(root_a, "p")
    vim.fn.mkdir(root_b, "p")

    local fb = require "filebrowser-picker"
    local finder = require "filebrowser-picker.finder"
    local history = require "filebrowser-picker.history"

    local captured_pick, captured_finder_opts, captured_state, captured_history_roots

    local overrides = {
      { package.loaded, "snacks", {
          picker = {
            pick = function(opts)
              captured_pick = opts
              return opts
            end,
          },
        },
      },
      { finder, "create_finder", function(opts, state)
          captured_finder_opts = vim.deepcopy(opts)
          captured_state = { roots = vim.deepcopy(state.roots), idx = state.idx }
          return function() return {} end
        end,
      },
      { finder, "create_format_function", function()
          return function() end
        end,
      },
      { finder, "create_cleanup_function", function()
          return function() end
        end,
      },
      { history, "add_roots_to_history", function(roots)
          captured_history_roots = vim.deepcopy(roots)
        end,
      },
      { history, "add_to_history", function() end },
    }

    fb.setup { hidden = false }
    with_overrides(overrides, function()
      fb.file_browser { roots = { root_a, root_b } }
    end)

    eq(captured_finder_opts.use_file_finder, true)
    eq(#captured_state.roots, 2)
    eq(normalize(captured_state.roots[1]), normalize(root_a))
    eq(captured_state.idx, 1)
    eq(normalize(captured_history_roots[2]), normalize(root_b))
    ok(captured_pick.title:match("%[1/2"))
  end)
end)

add("file_browser resumes last directory when configured", function()
  with_tmpdir(function(dir)
    local resume_dir = vim.fn.fnamemodify(dir .. "/session", ":p")
    vim.fn.mkdir(resume_dir, "p")

    local fb = require "filebrowser-picker"
    local finder = require "filebrowser-picker.finder"
    local history = require "filebrowser-picker.history"

    local captured_pick, captured_finder_opts

    local overrides = {
      { package.loaded, "snacks", {
          picker = {
            pick = function(opts)
              captured_pick = opts
              return opts
            end,
          },
        },
      },
      { finder, "create_finder", function(opts)
          captured_finder_opts = vim.deepcopy(opts)
          return function() return {} end
        end,
      },
      { finder, "create_format_function", function()
          return function() end
        end,
      },
      { finder, "create_cleanup_function", function()
          return function() end
        end,
      },
      { history, "get_last_dir", function()
          return resume_dir
        end,
      },
      { history, "add_to_history", function() end },
      { history, "add_roots_to_history", function() end },
    }

    fb.setup { hidden = false }
    with_overrides(overrides, function()
      fb.file_browser { resume_last = true }
    end)

    eq(normalize(captured_pick.cwd), normalize(resume_dir))
    eq(captured_finder_opts.use_file_finder or false, false)
  end)
end)


add("file_browser emits lifecycle events and history updates", function()
  with_tmpdir(function(dir)
    local fb = require "filebrowser-picker"
    local finder = require "filebrowser-picker.finder"
    local history = require "filebrowser-picker.history"
    local events = require "filebrowser-picker.events"

    local captured_pick, captured_finder_opts
    local event_calls, history_calls = {}, {}
    local enter_payload, leave_called, dir_callback_arg

    local overrides = {
      { package.loaded, "snacks", {
          picker = {
            pick = function(opts)
              captured_pick = opts
              return opts
            end,
          },
        },
      },
      { finder, "create_finder", function(opts)
          captured_finder_opts = vim.deepcopy(opts)
          return function() return {} end
        end,
      },
      { finder, "create_format_function", function()
          return function() end
        end,
      },
      { finder, "create_cleanup_function", function()
          return function() end
        end,
      },
      { history, "add_roots_to_history", function() end },
      { history, "add_to_history", function(path)
          table.insert(history_calls, path)
        end,
      },
      { events, "create_callback_wrapper", function(event_name, user_cb)
          return function(...)
            table.insert(event_calls, { event = event_name, args = { ... } })
            if user_cb then
              user_cb(...)
            end
          end
        end,
      },
    }

    fb.setup { hidden = false }
    local new_dir = vim.fn.fnamemodify(dir .. "/child", ":p")
    with_overrides(overrides, function()
      fb.file_browser {
        cwd = dir,
        on_enter = function(opts)
          enter_payload = opts
        end,
        on_leave = function()
          leave_called = true
        end,
        on_dir_change = function(path)
          dir_callback_arg = path
        end,
      }

      captured_pick.on_cwd_change(new_dir)
      captured_pick.on_close()
    end)

    eq(captured_finder_opts.use_file_finder or false, false)
    ok(enter_payload and enter_payload.cwd == dir, "on_enter did not receive opts")
    ok(leave_called, "on_leave was not invoked")
    eq(dir_callback_arg, new_dir)
    eq(history_calls[#history_calls], new_dir)

    local event_names = vim.tbl_map(function(call)
      return call.event
    end, event_calls)
    ok(vim.tbl_contains(event_names, events.events.ENTER), "ENTER event missing")
    ok(vim.tbl_contains(event_names, events.events.LEAVE), "LEAVE event missing")
    ok(vim.tbl_contains(event_names, events.events.DIR_CHANGED), "DIR event missing")
  end)
end)

add("health.check reports dependency status", function()
  with_tmpdir(function(dir)
    local config = require "filebrowser-picker.config"
    local history_file = vim.fn.fnamemodify(dir .. "/history.json", ":p")
    local original_executable = vim.fn.executable

    local overrides = {
      { config, "get", function()
          return vim.tbl_deep_extend("force", {}, config.defaults, {
            use_fd = true,
            use_rg = true,
            history_file = history_file,
          })
        end,
      },
      { vim.fn, "executable", function(cmd)
          if cmd == "fd" then
            return 0
          elseif cmd == "rg" then
            return 1
          elseif cmd == "git" then
            return 0
          elseif cmd == "trash" or cmd == "trash-put" then
            return 0
          end
          return original_executable(cmd)
        end,
      },
      { package.loaded, "snacks", {} },
    }

    local recorder = with_health_recorder(function()
      with_overrides(overrides, function()
        package.loaded["filebrowser-picker.health"] = nil
        local health = require "filebrowser-picker.health"
        health.check()
        package.loaded["filebrowser-picker.health"] = nil
      end)
    end)

    local ok_msgs = recorder._calls.ok
    local warn_msgs = recorder._calls.warn
    eq(#recorder._calls.error, 0, "health check produced errors")
    ok(vim.tbl_contains(ok_msgs, "snacks.nvim found"), "missing snacks ok message")
    ok(vim.tbl_contains(warn_msgs, "fd not found; falling back to built-in scanner (set `use_fd=false` to silence)"), "fd warning missing")
    ok(vim.tbl_contains(warn_msgs, "git not found; git status badges will be disabled"), "git warning missing")
    ok(vim.tbl_contains(warn_msgs, "No icon provider detected; fallback glyphs will be used"), "icon warning missing")
    ok(vim.tbl_contains(warn_msgs, "No trash utility detected; deletions will be permanent unless `use_trash` is disabled"), "trash warning missing")
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
