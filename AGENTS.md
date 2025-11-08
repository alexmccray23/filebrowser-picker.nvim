# Repository Guidelines

## Project Structure & Module Organization
Core source lives in `lua/filebrowser-picker/`; `init.lua` wires feature modules such as `actions.lua` (picker UX), `finder.lua` (scanner orchestration), `roots.lua` (workspace discovery), `git.lua` (status caching), `delete.lua` (fs ops), and helpers `notify.lua`, `events.lua`, `util.lua`. Profiling helpers (`bench.lua`, `perf.lua`, `perf_batch.lua`) sit alongside runtime code. User commands ship from `plugin/filebrowser-picker.lua`; register new entry points or hooks there so they load once.

## Build, Test, and Development Commands
- `nvim --headless +"lua require('filebrowser-picker').setup({})" +qa` — confirms the plugin loads without config.
- `nvim --headless +"lua require('filebrowser-picker').file_browser({ cwd = vim.loop.cwd(), roots = { vim.loop.cwd() } })" +qa` — smoke-tests picker startup/shutdown.
- `nvim --headless +"lua require('filebrowser-picker.bench').profile_scanners({ path = '.' })" +qa` — measures fd/rg/uv throughput before tweaking scanner logic.

## Coding Style & Naming Conventions
Use two-space indentation, `local M = {}` modules, and return `M`. Functions and locals stay in `snake_case`; exported APIs read like actions (`file_browser`, `delete_item`). Keep filesystem mutations in `delete.lua`, git logic in `git.lua`, and shared helpers in `util.lua` to preserve separation. Follow the existing EmmyLua annotations (`---@class`, `---@param`) for callable touch points. Prefer `string.format` for user-facing text and reuse existing keymap names when adding actions or commands.

## Testing Guidelines
`:FileBrowserTest` (declared in `plugin/filebrowser-picker.lua`) expects a `lua/filebrowser-picker/test.lua` module exposing `run_all_tests()`. Create or extend that module for headless Lua tests so CI and local scripts can call the same entry point. Until a full suite exists, record the manual steps you ran—open `:FileBrowser`, cycle multi-root navigation (`<C-n>/<C-p>`), toggle git indicators, and exercise create/rename/delete flows with `use_trash=true`. Document required external binaries (fd, rg, trash-cli) in the PR.

## Commit & Pull Request Guidelines
- Follow the log style: short imperative subjects such as `fix: avoid recursive git refresh callbacks` or `Add new async scanner`.
- Keep one logical change per commit and explain behavior or migration details in the body when needed.
- PRs should outline motivation, summarize changes, list manual/headless evidence, and link related issues.
- Include config snippets or screenshots for UX-facing tweaks, and call out breaking risks in a dedicated note.

## Performance & Diagnostics
Run `:FileBrowserPickerProfile ~/path` (or the headless variant above) before and after scanner or git changes, and paste the table in the PR. Attach `lua require('filebrowser-picker.perf').install()` during profiling to cache icons/stat formatting, and lean on `perf_batch.lua` when stress-testing refresh loops or bulk operations. Prefer fd/rg-backed scanners when benchmarking to match real user setups.
