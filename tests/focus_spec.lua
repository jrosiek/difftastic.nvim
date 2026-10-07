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

    it("leaves no autocmds of the view behind once it is closed", function()
        for _ = 1, 3 do
            difft.open("HEAD")
            difft.close()
        end

        for _, group in ipairs({ "DifftTreeResize", "DifftPaneSide", "DifftPaneSync" }) do
            local ok, cmds = pcall(vim.api.nvim_get_autocmds, { group = group })
            assert.are.same({}, ok and cmds or {}, group)
        end
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

--- Pane sync reacts to VimResized, WinResized and WinScrolled. Those are delivered by
--- Neovim's main loop, which does not run while a spec runs, so these specs drive a
--- child Neovim over RPC instead.
describe("pane sync", function()
    local child

    --- Runs Lua in the child and returns its result.
    local function remote(code, ...)
        return vim.rpcrequest(child, "nvim_exec_lua", code, { ... })
    end

    -- Waits until the child has no input left and its windows (layout, views,
    -- cursors, closed folds) read the same on two polls in a row. Each poll is a
    -- request through the child's event queue, so work it scheduled runs first.
    local function settle()
        local last
        local settled = vim.wait(5000, function()
            local snapshot = remote([[
                if vim.fn.getchar(1) ~= 0 or vim.api.nvim_get_mode().blocking then
                    return nil
                end
                local wins = {}
                for _, win in ipairs(vim.api.nvim_list_wins()) do
                    wins[#wins + 1] = vim.api.nvim_win_call(win, function()
                        local closed = {}
                        for lnum = 1, vim.fn.line("$") do
                            if vim.fn.foldclosed(lnum) == lnum then
                                closed[#closed + 1] = lnum
                            end
                        end
                        return { win, vim.fn.winlayout(), vim.fn.winsaveview(), vim.api.nvim_win_get_width(win), vim.api.nvim_win_get_height(win), closed }
                    end)
                end
                return vim.inspect({ vim.api.nvim_get_current_win(), vim.api.nvim_get_mode().mode, wins })
            ]])
            local stable = snapshot ~= nil and snapshot == last
            last = snapshot
            return stable
        end, 1)
        if not settled then
            error("child Neovim did not settle within 5000 ms", 2)
        end
    end

    before_each(function()
        local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
        local nui = vim.api.nvim_get_runtime_file("lua/nui/tree/init.lua", false)[1]
        child = vim.fn.jobstart({ "nvim", "--clean", "--headless", "--embed" }, { rpc = true })
        remote(
            [[
            local root, nui = ...
            vim.opt.rtp:prepend(root)
            vim.opt.rtp:append(vim.fn.fnamemodify(nui, ":h:h:h:h"))
            vim.opt.swapfile = false
            vim.o.columns, vim.o.lines, vim.o.mouse = 200, 40, "a"
            local function record(path, hunk)
                local rows = {}
                for i = 1, 300 do
                    rows[i] = {
                        left = { content = "line " .. i, highlights = {}, is_filler = false },
                        right = { content = "line " .. i, highlights = {}, is_filler = false },
                    }
                end
                return { path = path, status = "changed", language = "Text", additions = 1, deletions = 1,
                    hunk_starts = { hunk }, aligned_lines = {}, rows = rows }
            end
            require("difftastic-nvim.binary").get = function()
                return { run_diff = function() return { files = { record("a.txt", 150), record("b.txt", 10) } } end }
            end
            local difft = require("difftastic-nvim")
            difft.config.vcs = "git"
            difft.open("HEAD")
        ]],
            root,
            nui
        )
        settle()
    end)

    after_each(function()
        vim.fn.jobstop(child)
    end)

    local function widths()
        return remote([[
            local s = require("difftastic-nvim").state
            return {
                tree = vim.api.nvim_win_get_width(s.tree_win),
                left = vim.api.nvim_win_get_width(s.left_win),
                right = vim.api.nvim_win_get_width(s.right_win),
            }
        ]])
    end

    local function toplines()
        return remote([[
            local s = require("difftastic-nvim").state
            return { vim.fn.getwininfo(s.left_win)[1].topline, vim.fn.getwininfo(s.right_win)[1].topline }
        ]])
    end

    local function set_columns(n)
        remote("vim.o.columns = ...", n)
        settle()
    end

    local function assert_split(w, total)
        assert.are.equal(total, w.left + w.right)
        assert.is_true(math.abs(w.left - w.right) <= 1, vim.inspect(w))
    end

    describe("on Neovim resize", function()
        it("splits the space between the panes in their ratio", function()
            local before = widths()

            set_columns(260)
            local grown = widths()
            assert.are.equal(before.tree, grown.tree)
            assert.are.equal(before.left + before.right + 60, grown.left + grown.right)
            assert.is_true(math.abs(grown.left / (grown.left + grown.right) - before.left / (before.left + before.right)) < 0.02)

            set_columns(150)
            local shrunk = widths()
            assert.are.equal(before.tree, shrunk.tree)
            assert.are.equal(before.left + before.right - 50, shrunk.left + shrunk.right)
            assert.is_true(math.abs(shrunk.left / (shrunk.left + shrunk.right) - before.left / (before.left + before.right)) < 0.02)
        end)

        it("keeps a ratio the user set by resizing a pane", function()
            local w = widths()
            remote("vim.api.nvim_win_set_width(require('difftastic-nvim').state.left_win, ...)", math.floor((w.left + w.right) / 4))
            settle()

            set_columns(300)

            w = widths()
            assert.is_true(math.abs(w.left / (w.left + w.right) - 0.25) < 0.02, vim.inspect(w))
        end)

        it("keeps the pane ratio when the tree width changes", function()
            local w = widths()
            remote("vim.api.nvim_win_set_width(require('difftastic-nvim').state.left_win, ...)", math.floor((w.left + w.right) / 4))
            settle()
            local total = w.left + w.right

            remote("vim.api.nvim_win_set_width(require('difftastic-nvim').state.tree_win, ...)", w.tree + 20)
            settle()

            w = widths()
            assert.are.equal(total - 20, w.left + w.right)
            assert.is_true(math.abs(w.left / (w.left + w.right) - 0.25) < 0.02, vim.inspect(w))
            -- And the next Neovim resize still uses that ratio.
            set_columns(300)
            w = widths()
            assert.is_true(math.abs(w.left / (w.left + w.right) - 0.25) < 0.02, vim.inspect(w))
        end)

        --- Resizes Neovim through a series of odd and even widths, back to 200.
        local function cycle_sizes(check)
            for _ = 1, 3 do
                for _, columns in ipairs({ 157, 211, 133, 199, 171, 240, 183, 200 }) do
                    set_columns(columns)
                    if check then
                        check(widths(), columns)
                    end
                end
            end
        end

        it("keeps an even split through many resizes", function()
            local start = widths()

            cycle_sizes(function(w, columns)
                assert.is_true(math.abs(w.left - w.right) <= 1, columns .. ": " .. vim.inspect(w))
            end)

            assert.are.same(start, widths())
        end)

        it("keeps a dragged split through many resizes", function()
            local w = widths()
            remote("vim.api.nvim_win_set_width(require('difftastic-nvim').state.left_win, ...)", math.floor((w.left + w.right) / 4))
            settle()
            local dragged = widths()

            cycle_sizes()

            assert.are.same(dragged, widths())
        end)

        it("applies a resize made in another tab when the diff tab is entered", function()
            local before = widths()
            remote("vim.cmd('tabnew')")
            settle()

            set_columns(260)
            remote("vim.api.nvim_set_current_tabpage(require('difftastic-nvim').state.diff_tabpage)")
            settle()

            local w = widths()
            assert.are.equal(before.tree, w.tree)
            assert.are.equal(before.left + before.right + 60, w.left + w.right)
            assert.is_true(math.abs(w.left / (w.left + w.right) - before.left / (before.left + before.right)) < 0.02, vim.inspect(w))
        end)
    end)

    describe("on mouse-wheel scroll", function()
        local function focus(side)
            remote("local s = require('difftastic-nvim').state; vim.api.nvim_set_current_win(s[...]); vim.api.nvim_win_set_cursor(0, { 1, 0 })", side)
            settle()
        end

        local function wheel(side)
            remote(
                [[
                local win = require("difftastic-nvim").state[...]
                local pos = vim.api.nvim_win_get_position(win)
                vim.api.nvim_input_mouse("wheel", "down", "", 0, pos[1] + 2, pos[2] + 2)
            ]],
                side
            )
            settle()
        end

        for _, case in ipairs({
            { name = "the head pane while the base pane has focus", focus = "left_win", scroll = "right_win" },
            { name = "the base pane while the head pane has focus", focus = "right_win", scroll = "left_win" },
            { name = "the focused pane", focus = "left_win", scroll = "left_win" },
        }) do
            it("keeps both panes at the same line when scrolling " .. case.name, function()
                focus(case.focus)

                wheel(case.scroll)
                wheel(case.scroll)

                local tops = toplines()
                assert.is_true(tops[1] > 1, "pane did not scroll")
                assert.are.equal(tops[1], tops[2])
                remote("vim.cmd('redraw')")
                settle()
                tops = toplines()
                assert.are.equal(tops[1], tops[2])
            end)
        end

        it("still keeps keyboard scrolling in sync", function()
            focus("left_win")
            for _, keys in ipairs({ "<C-d>", "<C-e><C-e>", "G", "gg" }) do
                remote("vim.api.nvim_input(...)", keys)
                settle()
                local tops = toplines()
                assert.are.equal(tops[1], tops[2], keys)
            end
        end)
    end)
end)
