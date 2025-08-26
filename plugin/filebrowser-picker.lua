-- filebrowser-picker.nvim plugin entry point

-- Prevent loading twice
if vim.g.loaded_filebrowser_picker then
  return
end
vim.g.loaded_filebrowser_picker = 1

-- Create user commands
vim.api.nvim_create_user_command("FileBrowser", function(opts)
  local args = {}
  if opts.args and opts.args ~= "" then
    args.cwd = vim.fn.expand(opts.args)
  end
  require("filebrowser-picker").file_browser(args)
end, {
  nargs = "?",
  complete = "dir",
  desc = "Open file browser",
})

vim.api.nvim_create_user_command("FileBrowserTest", function()
  require("filebrowser-picker.test").run_all_tests()
end, {
  desc = "Run filebrowser-picker tests",
})