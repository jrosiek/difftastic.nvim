--- A file that exists on one side only (added or deleted) is shown in one pane,
--- which takes the width of both; two panes come back, in their last ratio, for
--- a file with both sides.

-- Opening the diff view needs nui.nvim, which plugin managers install next to plenary.
if not pcall(require, "nui.tree") then
    local plenary_dir = vim.api.nvim_get_runtime_file("lua/plenary", false)[1]
    if plenary_dir then
        vim.opt.rtp:append(vim.fn.fnamemodify(plenary_dir, ":h:h:h") .. "/nui.nvim")
    end
end

local difft = require("difftastic-nvim")
local binary = require("difftastic-nvim.binary")

local function file_record(path, status)
    local rows = {}
    for i = 1, 30 do
        table.insert(rows, {
            left = { content = status == "created" and "" or ("old " .. i), highlights = {}, is_filler = status == "created" },
            right = { content = status == "deleted" and "" or ("new " .. i), highlights = {}, is_filler = status == "deleted" },
        })
    end
    return {
        path = path,
        status = status,
        language = "Text",
        additions = status == "deleted" and 0 or 30,
        deletions = status == "created" and 0 or 30,
        hunk_starts = { 0 },
        aligned_lines = {},
        rows = rows,
    }
end

describe("single pane", function()
    local original_get

    before_each(function()
        vim.o.columns = 200
        difft.config.vcs = "git"
        original_get = binary.get
        binary.get = function()
            return {
                run_diff = function()
                    return {
                        files = {
                            file_record("a.txt", "changed"),
                            file_record("b_new.txt", "created"),
                            file_record("c_gone.txt", "deleted"),
                        },
                    }
                end,
            }
        end
        difft.open("HEAD")
    end)

    after_each(function()
        difft.close()
        binary.get = original_get
    end)

    local function show(path)
        for i, file in ipairs(difft.state.files) do
            if file.path == path then
                difft.show_file(i)
                return
            end
        end
    end

    local function valid(win)
        return win ~= nil and vim.api.nvim_win_is_valid(win)
    end

    --- Width next to the side panel: everything right of its separator.
    local function space()
        return vim.o.columns - vim.api.nvim_win_get_width(difft.state.tree_win) - 1
    end

    it("shows an added file in the head pane only, over the width of both", function()
        show("b_new.txt")
        local s = difft.state
        assert.is_false(valid(s.left_win))
        assert.is_true(valid(s.right_win))
        assert.are.equal(space(), vim.api.nvim_win_get_width(s.right_win))
        assert.are.equal("new 1", vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(s.right_win), 0, 1, false)[1])
    end)

    it("shows a deleted file in the base pane only", function()
        show("c_gone.txt")
        local s = difft.state
        assert.is_true(valid(s.left_win))
        assert.is_false(valid(s.right_win))
        assert.are.equal(space(), vim.api.nvim_win_get_width(s.left_win))
    end)

    it("goes straight from an added file to a deleted one", function()
        show("b_new.txt")
        show("c_gone.txt")
        local s = difft.state
        assert.is_true(valid(s.left_win))
        assert.is_false(valid(s.right_win))
        assert.are.equal(space(), vim.api.nvim_win_get_width(s.left_win))
    end)

    it("moves focus to the remaining pane when the focused one closes", function()
        vim.api.nvim_set_current_win(difft.state.left_win)
        show("b_new.txt")
        assert.are.equal(difft.state.right_win, vim.api.nvim_get_current_win())
    end)

    -- Keeping the ratio through resizes is covered with the other pane sync
    -- specs (tests/focus_spec.lua), which need Neovim's main loop.
    it("brings two panes back in the panes' ratio", function()
        local s = difft.state
        s.pane_ratio = 1 / 3

        show("b_new.txt")
        show("c_gone.txt")
        show("a.txt")

        assert.is_true(valid(s.left_win) and valid(s.right_win))
        local l, r = vim.api.nvim_win_get_width(s.left_win), vim.api.nvim_win_get_width(s.right_win)
        assert.are.equal(math.floor((l + r) / 3 + 0.5), l)
        -- The base pane is back on the left, set up like the head pane.
        assert.is_true(vim.api.nvim_win_get_position(s.left_win)[2] < vim.api.nvim_win_get_position(s.right_win)[2])
        assert.are.equal(vim.wo[s.right_win].statuscolumn, vim.wo[s.left_win].statuscolumn)
        assert.is_true(vim.wo[s.left_win].scrollbind)
    end)

    it("keeps the pane buffers while a pane is closed, and deletes them with the view", function()
        local s = difft.state
        local left_buf, right_buf = s.left_buf, s.right_buf
        show("b_new.txt")
        assert.is_true(vim.api.nvim_buf_is_valid(left_buf))
        difft.close()
        assert.is_false(vim.api.nvim_buf_is_valid(left_buf))
        assert.is_false(vim.api.nvim_buf_is_valid(right_buf))
    end)

    it("focuses the one pane from the tree", function()
        show("c_gone.txt")
        vim.api.nvim_set_current_win(difft.state.tree_win)
        difft.focus_diff()
        assert.are.equal(difft.state.left_win, vim.api.nvim_get_current_win())
    end)
end)
