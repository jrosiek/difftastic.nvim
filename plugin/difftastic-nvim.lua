if vim.g.loaded_difftastic_nvim then
    return
end
vim.g.loaded_difftastic_nvim = true

-- Generate helptags if needed
local source = debug.getinfo(1, "S").source:sub(2)
local doc_dir = vim.fn.fnamemodify(source, ":h:h") .. "/doc"
if vim.fn.isdirectory(doc_dir) == 1 and vim.fn.filereadable(doc_dir .. "/tags") == 0 then
    pcall(vim.cmd.helptags, doc_dir)
end

local function open_difft(revset)
    require("difftastic-nvim").open_when_ready(revset)
end

vim.api.nvim_create_user_command("Difft", function(opts)
    local args = opts.args
    if args == "" then
        -- No args: show unstaged changes
        open_difft(nil)
    elseif args == "--staged" then
        -- Show staged changes
        open_difft("--staged")
    else
        -- Revset/commit range
        local revset = args:gsub("^['\"](.+)['\"]$", "%1")
        open_difft(revset)
    end
end, {
    nargs = "?",
    desc = "Open difftastic diff view (no args = unstaged, --staged = staged, or revset/commit)",
})

vim.api.nvim_create_user_command("DifftToggleReviewed", function()
    require("difftastic-nvim").toggle_reviewed()
end, {
    desc = "Toggle the reviewed mark of the shown file (or of the tree row under the cursor)",
})

vim.api.nvim_create_user_command("DifftClose", function()
    require("difftastic-nvim").close()
end, {
    desc = "Close difftastic diff view",
})

vim.api.nvim_create_user_command("DifftUpdate", function()
    require("difftastic-nvim").update()
end, {
    desc = "Download the difftastic-nvim binary for the installed plugin version, and difft, again",
})

vim.api.nvim_create_user_command("DifftPick", function()
    require("difftastic-nvim").pick_revision()
end, {
    desc = "Pick a jj revision or git commit with snacks.nvim",
})

vim.api.nvim_create_user_command("DifftPickRange", function()
    require("difftastic-nvim").pick_range()
end, {
    desc = "Pick start/end revisions with snacks.nvim",
})
