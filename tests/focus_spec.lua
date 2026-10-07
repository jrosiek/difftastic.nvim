-- Opening the diff view needs nui.nvim, which plugin managers install next to plenary.
if not pcall(require, "nui.tree") then
    local plenary_dir = vim.api.nvim_get_runtime_file("lua/plenary", false)[1]
    if plenary_dir then
        vim.opt.rtp:append(vim.fn.fnamemodify(plenary_dir, ":h:h:h") .. "/nui.nvim")
    end
end

local difft = require("difftastic-nvim")
local binary = require("difftastic-nvim.binary")

local function file_record(path)
    return {
        path = path,
        status = "changed",
        language = "Text",
        additions = 1,
        deletions = 1,
        hunk_starts = { 0 },
        aligned_lines = { { 0, 0 } },
        rows = {
            {
                left = { content = "old", highlights = {}, is_filler = false },
                right = { content = "new", highlights = {}, is_filler = false },
            },
        },
    }
end

describe("focus_diff from the tree", function()
    local original_get

    before_each(function()
        difft.config.vcs = "git"
        original_get = binary.get
        binary.get = function()
            return {
                run_diff = function()
                    return { files = { file_record("a.txt"), file_record("b.txt") } }
                end,
            }
        end
    end)

    after_each(function()
        difft.close()
        binary.get = original_get
    end)

    local function focus(win)
        vim.api.nvim_set_current_win(win)
    end

    local function press_focus_diff()
        vim.api.nvim_feedkeys(vim.keycode(difft.config.keymaps.focus_diff), "x", false)
    end

    it("goes to the pane focused when the view opened", function()
        difft.open("HEAD")
        local opened_in = vim.api.nvim_get_current_win()
        focus(difft.state.tree_win)

        press_focus_diff()

        assert.are.equal(opened_in, vim.api.nvim_get_current_win())
    end)

    it("returns to the head pane after it was used", function()
        difft.open("HEAD")
        focus(difft.state.left_win)
        focus(difft.state.right_win)
        focus(difft.state.tree_win)

        press_focus_diff()

        assert.are.equal(difft.state.right_win, vim.api.nvim_get_current_win())
    end)

    it("returns to the base pane after switching back to it", function()
        difft.open("HEAD")
        focus(difft.state.right_win)
        focus(difft.state.left_win)
        focus(difft.state.tree_win)

        press_focus_diff()

        assert.are.equal(difft.state.left_win, vim.api.nvim_get_current_win())
    end)

    it("keeps the last pane across a file switch", function()
        difft.open("HEAD")
        focus(difft.state.right_win)
        difft.show_file(2)
        focus(difft.state.tree_win)

        press_focus_diff()

        assert.are.equal(difft.state.right_win, vim.api.nvim_get_current_win())
    end)

    it("does not carry the last pane over to a new view", function()
        difft.open("HEAD")
        focus(difft.state.left_win)
        difft.close()

        difft.open("HEAD")
        local opened_in = vim.api.nvim_get_current_win()
        focus(difft.state.tree_win)
        press_focus_diff()

        assert.are.equal(opened_in, vim.api.nvim_get_current_win())
    end)

    it("removes its autocmd on the first window change after the view is closed", function()
        difft.open("HEAD")
        difft.close()

        vim.cmd("new")
        vim.cmd("close")

        local ok, cmds = pcall(vim.api.nvim_get_autocmds, { group = "DifftPaneSide" })
        assert.are.same({}, ok and cmds or {})
    end)
end)
