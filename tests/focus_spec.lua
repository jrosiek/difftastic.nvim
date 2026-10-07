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

describe("focus_diff_on_select", function()
    local original_get, original_option
    local tree = require("difftastic-nvim.tree")

    before_each(function()
        difft.config.vcs = "git"
        original_option = difft.config.focus_diff_on_select
        original_get = binary.get
        binary.get = function()
            return {
                run_diff = function()
                    return { files = { long_record("a.txt", 30, 10), long_record("dir/b.txt", 30, 20) } }
                end,
            }
        end
    end)

    after_each(function()
        difft.close()
        binary.get = original_get
        difft.config.focus_diff_on_select = original_option
    end)

    --- Puts the tree cursor on the row whose node matches and presses select.
    local function select(match)
        vim.api.nvim_set_current_win(difft.state.tree_win)
        local count = vim.api.nvim_buf_line_count(difft.state.tree_buf)
        for linenr = 1, count do
            local node = tree.tree:get_node(linenr)
            if node and match(node) then
                vim.api.nvim_win_set_cursor(difft.state.tree_win, { linenr, 0 })
                vim.api.nvim_feedkeys(vim.keycode(difft.config.keymaps.select), "x", false)
                return
            end
        end
        error("no matching tree row")
    end

    local function file(path)
        return function(node)
            return node.file_idx and difft.state.files[node.file_idx].path == path
        end
    end

    it("is on by default", function()
        assert.is_true(require("difftastic-nvim").config.focus_diff_on_select)
    end)

    it("keeps focus in the tree when off", function()
        difft.config.focus_diff_on_select = false
        difft.open("HEAD")

        select(file("dir/b.txt"))

        assert.are.equal("dir/b.txt", difft.state.files[difft.state.current_file_idx].path)
        assert.are.equal(difft.state.tree_win, vim.api.nvim_get_current_win())
    end)

    it("focuses the head pane at the first hunk of an unvisited file", function()
        difft.config.focus_diff_on_select = true
        difft.open("HEAD")

        select(file("dir/b.txt"))

        assert.are.equal(difft.state.right_win, vim.api.nvim_get_current_win())
        assert.are.same({ 21, 0 }, vim.api.nvim_win_get_cursor(difft.state.right_win))
    end)

    it("focuses the pane and position a visited file was left at", function()
        difft.config.focus_diff_on_select = true
        difft.open("HEAD")
        select(file("a.txt"))
        vim.api.nvim_set_current_win(difft.state.left_win)
        vim.api.nvim_win_set_cursor(difft.state.left_win, { 3, 0 })
        select(file("dir/b.txt"))
        vim.api.nvim_set_current_win(difft.state.right_win)

        select(file("a.txt"))

        assert.are.equal(difft.state.left_win, vim.api.nvim_get_current_win())
        assert.are.same({ 3, 0 }, vim.api.nvim_win_get_cursor(difft.state.left_win))
    end)

    it("keeps focus in the tree when toggling a directory", function()
        difft.config.focus_diff_on_select = true
        difft.open("HEAD")

        select(function(node)
            return node.is_dir
        end)

        assert.are.equal(difft.state.tree_win, vim.api.nvim_get_current_win())
    end)

    it("is set through setup()", function()
        difft.setup({ focus_diff_on_select = true })
        assert.is_true(difft.config.focus_diff_on_select)
        difft.setup({ focus_diff_on_select = false })
        assert.is_false(difft.config.focus_diff_on_select)
    end)
end)

--- Starts a child Neovim with the diff view open on two 300-line files, a.txt
--- (hunk at row 150) and b.txt (hunk at row 10), at 200x40 with the mouse enabled.
--- Returns `remote(code, ...)` to run Lua in it, `settle()` to let its main loop
--- deliver events, and `stop()`.
local function child_nvim()
    local child = vim.fn.jobstart({ "nvim", "--clean", "--headless", "--embed" }, { rpc = true })
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
    local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
    local nui = vim.api.nvim_get_runtime_file("lua/nui/tree/init.lua", false)[1]
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
    return {
        remote = remote,
        settle = settle,
        stop = function()
            vim.fn.jobstop(child)
        end,
    }
end

--- Pane sync reacts to VimResized, WinResized and WinScrolled. Those are delivered by
--- Neovim's main loop, which does not run while a spec runs, so these specs drive a
--- child Neovim over RPC instead.
describe("pane sync", function()
    local nvim

    local function remote(code, ...)
        return nvim.remote(code, ...)
    end

    local function settle()
        nvim.settle()
    end

    before_each(function()
        nvim = child_nvim()
    end)

    after_each(function()
        nvim.stop()
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

describe("double click in the tree", function()
    local nvim

    before_each(function()
        nvim = child_nvim()
    end)

    after_each(function()
        nvim.stop()
    end)

    --- Double clicks the tree row showing `path` and returns the shown file and
    --- the focused pane ("tree", "base" or "head").
    local function double_click(path)
        nvim.remote(
            [[
            local path = ...
            local s = require("difftastic-nvim").state
            local tree = require("difftastic-nvim.tree")
            local pos = vim.api.nvim_win_get_position(s.tree_win)
            for linenr = 1, vim.api.nvim_buf_line_count(s.tree_buf) do
                local node = tree.tree:get_node(linenr)
                if node and node.file_idx and s.files[node.file_idx].path == path then
                    for _ = 1, 2 do
                        vim.api.nvim_input_mouse("left", "press", "", 0, pos[1] + linenr - 1, pos[2] + 4)
                        vim.api.nvim_input_mouse("left", "release", "", 0, pos[1] + linenr - 1, pos[2] + 4)
                    end
                    return
                end
            end
            error("no tree row for " .. path)
        ]],
            path
        )
        nvim.settle()
        return nvim.remote([[
            local s = require("difftastic-nvim").state
            local win = vim.api.nvim_get_current_win()
            local focus = win == s.tree_win and "tree" or win == s.left_win and "base" or win == s.right_win and "head"
            return { s.files[s.current_file_idx].path, focus, vim.api.nvim_win_get_cursor(win)[1] }
        ]])
    end

    it("opens the file and focuses its diff pane", function()
        local shown = double_click("b.txt")

        assert.are.same({ "b.txt", "head", 11 }, shown)
    end)

    it("returns to the position a visited file was left at", function()
        nvim.remote([[
            local s = require("difftastic-nvim").state
            vim.api.nvim_set_current_win(s.left_win)
            vim.api.nvim_win_set_cursor(s.left_win, { 42, 0 })
        ]])
        nvim.settle()
        local visited = nvim.remote("local s = require('difftastic-nvim').state; return s.files[s.current_file_idx].path")
        local other = visited == "a.txt" and "b.txt" or "a.txt"

        double_click(other)
        local shown = double_click(visited)

        assert.are.same({ visited, "base", 42 }, shown)
    end)

    it("ignores a double click on a window separator while the tree has focus", function()
        nvim.remote([[
            local s = require("difftastic-nvim").state
            vim.api.nvim_set_current_win(s.tree_win)
            local pos = vim.api.nvim_win_get_position(s.left_win)
            local col = pos[2] + vim.api.nvim_win_get_width(s.left_win)
            for _ = 1, 2 do
                vim.api.nvim_input_mouse("left", "press", "", 0, pos[1] + 5, col)
                vim.api.nvim_input_mouse("left", "release", "", 0, pos[1] + 5, col)
            end
        ]])
        nvim.settle()

        local state = nvim.remote([[
            local s = require("difftastic-nvim").state
            return { vim.api.nvim_get_current_win() == s.tree_win, vim.api.nvim_get_mode().mode }
        ]])
        assert.are.same({ true, "n" }, state)
    end)

    it("keeps focus in the tree when focus_diff_on_select is off", function()
        nvim.remote("require('difftastic-nvim').config.focus_diff_on_select = false")

        local shown = double_click("b.txt")

        assert.are.equal("b.txt", shown[1])
        assert.are.equal("tree", shown[2])
    end)
end)

describe("double click on the split between the diff panes", function()
    local nvim

    before_each(function()
        nvim = child_nvim()
        -- Start from an uneven split.
        nvim.remote([[
            local s = require("difftastic-nvim").state
            local total = vim.api.nvim_win_get_width(s.left_win) + vim.api.nvim_win_get_width(s.right_win)
            vim.api.nvim_win_set_width(s.left_win, math.floor(total / 4))
        ]])
        nvim.settle()
    end)

    after_each(function()
        nvim.stop()
    end)

    local function widths()
        return nvim.remote([[
            local s = require("difftastic-nvim").state
            return {
                tree = vim.api.nvim_win_get_width(s.tree_win),
                left = vim.api.nvim_win_get_width(s.left_win),
                right = vim.api.nvim_win_get_width(s.right_win),
            }
        ]])
    end

    local function focus(name)
        nvim.remote("vim.api.nvim_set_current_win(require('difftastic-nvim').state[...])", name)
        nvim.settle()
    end

    --- Double clicks at a screen cell, given relative to a window of the view:
    --- `col` counts from the window's first column, so its width is the separator
    --- to its right.
    local function double_click(win_name, row, col)
        nvim.remote(
            [[
            local name, row, col = ...
            local win = require("difftastic-nvim").state[name]
            local pos = vim.api.nvim_win_get_position(win)
            if col == "split" then
                col = vim.api.nvim_win_get_width(win)
            end
            for _ = 1, 2 do
                vim.api.nvim_input_mouse("left", "press", "", 0, pos[1] + row, pos[2] + col)
                vim.api.nvim_input_mouse("left", "release", "", 0, pos[1] + row, pos[2] + col)
            end
        ]],
            win_name,
            row,
            col
        )
        nvim.settle()
    end

    local function assert_even(w, before)
        assert.are.equal(before.tree, w.tree)
        assert.are.equal(before.left + before.right, w.left + w.right)
        assert.is_true(math.abs(w.left - w.right) <= 1, vim.inspect(w))
    end

    for _, current in ipairs({ "left_win", "right_win", "tree_win" }) do
        it("gives both panes the same width with " .. current .. " focused", function()
            focus(current)
            local before = widths()
            assert.is_true(before.right - before.left > 10, "split did not start uneven")

            double_click("left_win", 5, "split")

            assert_even(widths(), before)
            assert.are.equal("n", nvim.remote("return vim.api.nvim_get_mode().mode"))
        end)
    end

    it("keeps the even split when Neovim is resized", function()
        focus("left_win")
        local before = widths()
        double_click("left_win", 5, "split")

        nvim.remote("vim.o.columns = 260")
        nvim.settle()

        assert_even(widths(), { tree = before.tree, left = before.left + 30, right = before.right + 30 })
    end)

    it("restores an exact half that survives many resizes", function()
        -- An odd number of columns for the panes, where whole widths cannot be a half.
        nvim.remote("vim.o.columns = 201")
        nvim.settle()
        focus("left_win")
        double_click("left_win", 5, "split")
        nvim.remote("vim.o.columns = 200")
        nvim.settle()
        local even = widths()

        for _ = 1, 3 do
            for _, columns in ipairs({ 157, 211, 133, 199, 171, 240, 183, 200 }) do
                nvim.remote("vim.o.columns = ...", columns)
                nvim.settle()
                local w = widths()
                assert.is_true(math.abs(w.left - w.right) <= 1, columns .. ": " .. vim.inspect(w))
            end
        end

        assert.are.same(even, widths())
    end)

    it("leaves the split alone on a double click in a pane", function()
        focus("right_win")
        local before = widths()

        double_click("right_win", 5, 2)

        assert.are.same(before, widths())
        -- The default double click selects the word under the mouse.
        assert.are.equal("v", nvim.remote("return vim.api.nvim_get_mode().mode"))
    end)

    it("leaves the panes alone on a double click on the tree border", function()
        focus("left_win")
        local before = widths()

        double_click("tree_win", 5, "split")

        assert.are.same(before, widths())
    end)
end)

describe("double click on the side panel's right border", function()
    local nvim

    before_each(function()
        nvim = child_nvim()
    end)

    after_each(function()
        nvim.stop()
    end)

    local function widths()
        return nvim.remote([[
            local s = require("difftastic-nvim").state
            return {
                tree = vim.api.nvim_win_get_width(s.tree_win),
                left = vim.api.nvim_win_get_width(s.left_win),
                right = vim.api.nvim_win_get_width(s.right_win),
            }
        ]])
    end

    local function double_click_tree_border()
        nvim.remote([[
            local win = require("difftastic-nvim").state.tree_win
            local pos = vim.api.nvim_win_get_position(win)
            local col = pos[2] + vim.api.nvim_win_get_width(win)
            for _ = 1, 2 do
                vim.api.nvim_input_mouse("left", "press", "", 0, pos[1] + 5, col)
                vim.api.nvim_input_mouse("left", "release", "", 0, pos[1] + 5, col)
            end
        ]])
        nvim.settle()
    end

    for _, current in ipairs({ "tree_win", "left_win", "right_win" }) do
        it("resets the panel to its configured width with " .. current .. " focused", function()
            nvim.remote([[
                local s = require("difftastic-nvim").state
                vim.api.nvim_win_set_width(s.tree_win, 70)
                vim.api.nvim_set_current_win(s[...])
            ]], current)
            nvim.settle()
            local before = widths()
            assert.are.equal(70, before.tree)

            double_click_tree_border()

            local w = widths()
            local configured = nvim.remote("return require('difftastic-nvim').config.tree.width")
            assert.are.equal(configured, w.tree)
            assert.are.equal(before.tree + before.left + before.right, w.tree + w.left + w.right)
            local ratio = before.left / (before.left + before.right)
            assert.is_true(math.abs(w.left / (w.left + w.right) - ratio) < 0.02, vim.inspect(w))
            assert.are.equal("n", nvim.remote("return vim.api.nvim_get_mode().mode"))
        end)
    end

    it("uses the width set in setup()", function()
        nvim.remote([[
            local difft = require("difftastic-nvim")
            difft.config.tree.width = 55
            vim.api.nvim_win_set_width(difft.state.tree_win, 70)
        ]])
        nvim.settle()

        double_click_tree_border()

        assert.are.equal(55, widths().tree)
    end)
end)
