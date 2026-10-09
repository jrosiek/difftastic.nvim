-- Minimal init for running tests
-- Add plugin to runtime path
local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(plugin_root)
vim.opt.swapfile = false
-- A data directory of its own, so tests never use a library or difft the
-- plugin downloaded for the user.
vim.env.XDG_DATA_HOME = vim.fn.tempname()

-- Try to load plenary if available
local ok, _ = pcall(require, "plenary")
if not ok then
    print("Warning: plenary.nvim not found. Some tests may fail.")
end
