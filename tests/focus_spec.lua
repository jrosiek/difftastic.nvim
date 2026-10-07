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

    it("opens with focus in the head pane", function()
        difft.open("HEAD")

        assert.are.equal(difft.state.right_win, vim.api.nvim_get_current_win())
    end)

    it("goes to the head pane when no pane was used yet", function()
        difft.open("HEAD")
        difft.state.pane_side = nil
        focus(difft.state.tree_win)

        press_focus_diff()

        assert.are.equal(difft.state.right_win, vim.api.nvim_get_current_win())
    end)

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

--- A file of `count` rows with a single hunk at `hunk` (0-based row).
local function long_record(path, count, hunk)
    local rows = {}
    for i = 1, count do
        local changed = i - 1 == hunk
        rows[i] = {
            left = { content = (changed and "old " or "line ") .. i, highlights = {}, is_filler = false },
            right = { content = (changed and "new " or "line ") .. i, highlights = {}, is_filler = false },
        }
    end
    return {
        path = path,
        status = "changed",
        language = "Text",
        additions = 1,
        deletions = 1,
        hunk_starts = { hunk },
        aligned_lines = {},
        rows = rows,
    }
end

describe("per-file cursor positions", function()
    local original_get, original_config

    before_each(function()
        difft.config.vcs = "git"
        original_config = { difft.config.scroll_to_first_hunk, difft.config.hunk_wrap_file }
        difft.config.scroll_to_first_hunk = true
        original_get = binary.get
        binary.get = function()
            return {
                run_diff = function()
                    return {
                        files = {
                            long_record("a.txt", 30, 10),
                            long_record("b.txt", 30, 20),
                            long_record("c.txt", 30, 5),
                        },
                    }
                end,
            }
        end
    end)

    after_each(function()
        difft.close()
        binary.get = original_get
        difft.config.scroll_to_first_hunk, difft.config.hunk_wrap_file = unpack(original_config)
    end)

    local function cursor(win)
        return vim.api.nvim_win_get_cursor(win)
    end

    local function show(path)
        for idx, file in ipairs(difft.state.files) do
            if file.path == path then
                difft.show_file(idx)
                return
            end
        end
        error("no file " .. path)
    end

    it("opens an unvisited file at its first hunk", function()
        difft.open("HEAD")
        show("a.txt")
        vim.api.nvim_set_current_win(difft.state.left_win)

        show("b.txt")

        assert.are.equal(21, cursor(difft.state.left_win)[1])
    end)

    it("opens the first file at its first hunk in the head pane", function()
        difft.open("HEAD")

        local first = difft.state.files[difft.state.current_file_idx]
        local hunk = first.hunk_starts[1] + 1
        assert.are.equal(difft.state.right_win, vim.api.nvim_get_current_win())
        assert.are.same({ hunk, 0 }, cursor(difft.state.right_win))
        assert.are.same({ hunk, 0 }, cursor(difft.state.left_win))
    end)

    it("returns to the line and column a file was left at", function()
        difft.open("HEAD")
        show("a.txt")
        vim.api.nvim_set_current_win(difft.state.left_win)
        vim.api.nvim_win_set_cursor(difft.state.left_win, { 25, 3 })

        show("b.txt")
        show("a.txt")

        assert.are.same({ 25, 3 }, cursor(difft.state.left_win))
        assert.are.equal(difft.state.left_win, vim.api.nvim_get_current_win())
    end)

    it("moves focus to the pane a file was left in", function()
        difft.open("HEAD")
        show("a.txt")
        vim.api.nvim_set_current_win(difft.state.right_win)
        vim.api.nvim_win_set_cursor(difft.state.right_win, { 4, 2 })
        show("b.txt")
        vim.api.nvim_set_current_win(difft.state.left_win)

        show("a.txt")

        assert.are.equal(difft.state.right_win, vim.api.nvim_get_current_win())
        assert.are.same({ 4, 2 }, cursor(difft.state.right_win))
    end)

    it("returns to the base pane a file was left in, despite the head default", function()
        difft.open("HEAD")
        show("a.txt")
        vim.api.nvim_set_current_win(difft.state.left_win)
        vim.api.nvim_win_set_cursor(difft.state.left_win, { 9, 1 })
        show("b.txt")
        vim.api.nvim_set_current_win(difft.state.right_win)
        show("c.txt")
        vim.api.nvim_set_current_win(difft.state.tree_win)

        show("a.txt")
        vim.api.nvim_feedkeys(vim.keycode(difft.config.keymaps.focus_diff), "x", false)

        assert.are.equal(difft.state.left_win, vim.api.nvim_get_current_win())
        assert.are.same({ 9, 1 }, cursor(difft.state.left_win))
        -- And from a diff pane, focus moves to the stored pane directly.
        show("b.txt")
        vim.api.nvim_set_current_win(difft.state.right_win)
        show("a.txt")
        assert.are.equal(difft.state.left_win, vim.api.nvim_get_current_win())
    end)

    it("keeps the tree focused and sends <Tab> to the file's pane", function()
        difft.open("HEAD")
        show("a.txt")
        vim.api.nvim_set_current_win(difft.state.right_win)
        vim.api.nvim_win_set_cursor(difft.state.right_win, { 7, 0 })
        vim.api.nvim_set_current_win(difft.state.tree_win)
        show("b.txt")
        vim.api.nvim_set_current_win(difft.state.left_win)
        vim.api.nvim_set_current_win(difft.state.tree_win)

        show("a.txt")

        assert.are.equal(difft.state.tree_win, vim.api.nvim_get_current_win())
        vim.api.nvim_feedkeys(vim.keycode(difft.config.keymaps.focus_diff), "x", false)
        assert.are.equal(difft.state.right_win, vim.api.nvim_get_current_win())
        assert.are.equal(7, cursor(difft.state.right_win)[1])
    end)

    it("opens an unvisited file at its first hunk in the pane <Tab> goes to", function()
        difft.open("HEAD")
        show("a.txt")
        vim.api.nvim_set_current_win(difft.state.right_win)
        vim.api.nvim_win_set_cursor(difft.state.right_win, { 28, 4 })
        vim.api.nvim_set_current_win(difft.state.tree_win)

        show("c.txt")
        vim.api.nvim_feedkeys(vim.keycode(difft.config.keymaps.focus_diff), "x", false)

        assert.are.equal(difft.state.right_win, vim.api.nvim_get_current_win())
        assert.are.same({ 6, 0 }, cursor(difft.state.right_win))
        assert.are.same({ 6, 0 }, cursor(difft.state.left_win))
    end)

    it("opens an unvisited file at its first hunk in both panes", function()
        difft.open("HEAD")
        show("a.txt")
        vim.api.nvim_set_current_win(difft.state.left_win)
        vim.api.nvim_win_set_cursor(difft.state.left_win, { 28, 4 })

        show("c.txt")

        assert.are.same({ 6, 0 }, cursor(difft.state.left_win))
        assert.are.same({ 6, 0 }, cursor(difft.state.right_win))
    end)

    it("opens an unvisited file at the top without scroll_to_first_hunk", function()
        difft.config.scroll_to_first_hunk = false
        difft.open("HEAD")
        show("a.txt")
        vim.api.nvim_set_current_win(difft.state.right_win)
        vim.api.nvim_win_set_cursor(difft.state.right_win, { 28, 4 })

        show("c.txt")

        assert.are.same({ 1, 0 }, cursor(difft.state.right_win))
        assert.are.same({ 1, 0 }, cursor(difft.state.left_win))
    end)

    it("records the position as the cursor moves, not only when the file is left", function()
        difft.open("HEAD")
        show("a.txt")
        vim.api.nvim_set_current_win(difft.state.right_win)
        vim.api.nvim_win_set_cursor(difft.state.right_win, { 7, 2 })
        vim.api.nvim_exec_autocmds("CursorMoved", {})

        assert.are.same({ line = 7, col = 2, side = "head" }, difft.state.positions["a.txt"])

        vim.api.nvim_set_current_win(difft.state.left_win)
        vim.api.nvim_win_set_cursor(difft.state.left_win, { 9, 0 })
        vim.api.nvim_exec_autocmds("CursorMoved", {})

        assert.are.same({ line = 9, col = 0, side = "base" }, difft.state.positions["a.txt"])
    end)

    it("records the pane as soon as another pane is entered", function()
        difft.open("HEAD")
        show("a.txt")
        vim.api.nvim_set_current_win(difft.state.right_win)
        vim.api.nvim_win_set_cursor(difft.state.right_win, { 5, 0 })
        vim.api.nvim_exec_autocmds("CursorMoved", {})

        vim.api.nvim_set_current_win(difft.state.left_win)

        assert.are.equal("base", difft.state.positions["a.txt"].side)
    end)

    it("keeps positions of several files apart", function()
        difft.open("HEAD")
        vim.api.nvim_set_current_win(difft.state.left_win)
        show("a.txt")
        vim.api.nvim_win_set_cursor(difft.state.left_win, { 2, 0 })
        show("b.txt")
        vim.api.nvim_win_set_cursor(difft.state.left_win, { 3, 0 })
        show("c.txt")
        vim.api.nvim_win_set_cursor(difft.state.left_win, { 4, 0 })

        show("a.txt")
        assert.are.equal(2, cursor(difft.state.left_win)[1])
        show("c.txt")
        assert.are.equal(4, cursor(difft.state.left_win)[1])
        show("b.txt")
        assert.are.equal(3, cursor(difft.state.left_win)[1])
    end)

    it("still lands on a hunk when hunk navigation crosses into a visited file", function()
        difft.config.hunk_wrap_file = true
        difft.open("HEAD")
        vim.api.nvim_set_current_win(difft.state.left_win)
        show("b.txt")
        vim.api.nvim_win_set_cursor(difft.state.left_win, { 2, 0 })
        show("a.txt")
        local target = difft.state.files[require("difftastic-nvim.tree").next_file_in_display_order(difft.state.current_file_idx)]
        assert.are.equal("b.txt", target.path)
        vim.api.nvim_win_set_cursor(difft.state.left_win, { 11, 0 }) -- on a.txt's only hunk

        difft.next_hunk()

        assert.is_true(vim.wait(500, function()
            local shown = difft.state.files[difft.state.current_file_idx].path
            return shown == "b.txt" and cursor(difft.state.left_win)[1] == 21
        end))
    end)

    it("forgets positions when a new view opens", function()
        difft.open("HEAD")
        vim.api.nvim_set_current_win(difft.state.left_win)
        show("a.txt")
        show("b.txt")
        vim.api.nvim_win_set_cursor(difft.state.left_win, { 2, 0 })
        show("a.txt")
        -- Closed without going through the plugin.
        vim.cmd("tabclose")

        difft.open("HEAD")
        vim.api.nvim_set_current_win(difft.state.left_win)
        show("b.txt")

        assert.are.equal(21, cursor(difft.state.left_win)[1])
    end)
end)
