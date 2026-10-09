-- Opening the diff view needs nui.nvim, which plugin managers install next to plenary.
if not pcall(require, "nui.tree") then
    local plenary_dir = vim.api.nvim_get_runtime_file("lua/plenary", false)[1]
    if plenary_dir then
        vim.opt.rtp:append(vim.fn.fnamemodify(plenary_dir, ":h:h:h") .. "/nui.nvim")
    end
end

local difft = require("difftastic-nvim")
local binary = require("difftastic-nvim.binary")
local tree = require("difftastic-nvim.tree")

local function record(path)
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
                left = { content = "old", highlights = { { start = 0, ["end"] = -1 } }, is_filler = false },
                right = { content = "new", highlights = { { start = 0, ["end"] = -1 } }, is_filler = false },
            },
        },
    }
end

describe("review markers", function()
    local original_get, original_config

    before_each(function()
        original_config = vim.deepcopy(difft.config)
        difft.config.vcs = "git"
        original_get = binary.get
        binary.get = function()
            return {
                run_diff = function()
                    return { files = { record("a.txt"), record("dir/b.txt"), record("dir/c.txt"), record("z.txt") } }
                end,
            }
        end
    end)

    after_each(function()
        difft.close()
        binary.get = original_get
        difft.config = original_config
    end)

    --- Tree row of a file or directory: its line number and text.
    local function row(match)
        local buf = difft.state.tree_buf
        for linenr = 1, vim.api.nvim_buf_line_count(buf) do
            local node = difft.state.tree:get_node(linenr)
            if node and match(node) then
                return linenr, vim.api.nvim_buf_get_lines(buf, linenr - 1, linenr, false)[1]
            end
        end
        error("no tree row")
    end

    local function file_row(path)
        return row(function(node)
            return node.file_idx and difft.state.files[node.file_idx].path == path
        end)
    end

    local function dir_row(name)
        return row(function(node)
            return node.is_dir and node.name == name
        end)
    end

    --- The review marker of a file: the row's last character.
    local function marker(path)
        local _, text = file_row(path)
        return vim.fn.strcharpart(text, vim.fn.strchars(text) - 1, 1)
    end

    local function markers()
        local result = {}
        for _, path in ipairs({ "a.txt", "dir/b.txt", "dir/c.txt", "z.txt" }) do
            result[path] = marker(path)
        end
        return result
    end

    local function show(path)
        for idx, file in ipairs(difft.state.files) do
            if file.path == path then
                difft.show_file(idx)
                return
            end
        end
    end

    local function press(keys)
        vim.api.nvim_feedkeys(vim.keycode(keys), "x", false)
    end

    local function in_tree_on(linenr)
        vim.api.nvim_set_current_win(difft.state.tree_win)
        vim.api.nvim_win_set_cursor(difft.state.tree_win, { linenr, 0 })
    end

    it("marks every file not shown yet", function()
        difft.open("HEAD")
        local shown = difft.state.shown_path

        local m = markers()
        for path, glyph in pairs(m) do
            assert.are.equal(path == shown and " " or "•", glyph, path)
        end
    end)

    it("drops the marker of a file once it is shown", function()
        difft.open("HEAD")
        show("z.txt")

        assert.are.equal(" ", marker("z.txt"))
        assert.is_true(difft.state.visited["z.txt"])
    end)

    it("toggles the shown file with R in a diff pane", function()
        difft.open("HEAD")
        show("dir/b.txt")
        vim.api.nvim_set_current_win(difft.state.right_win)

        press("R")
        assert.are.equal("✓", marker("dir/b.txt"))
        assert.is_true(difft.state.reviewed["dir/b.txt"])
        show("dir/b.txt")
        vim.api.nvim_set_current_win(difft.state.left_win)
        press("R")
        assert.are.equal(" ", marker("dir/b.txt"))
        assert.is_nil(difft.state.reviewed["dir/b.txt"])
    end)

    it("moves on to the next unreviewed file once R marks the shown one", function()
        difft.open("HEAD")
        show("dir/b.txt")
        vim.api.nvim_set_current_win(difft.state.left_win)

        press("R")
        assert.are.equal("dir/c.txt", difft.state.shown_path)
        assert.are.equal(difft.state.left_win, vim.api.nvim_get_current_win())
        -- Unmarking leaves the shown file alone.
        show("dir/b.txt")
        press("R")
        assert.are.equal("dir/b.txt", difft.state.shown_path)
    end)

    it("moves on from the tree to the next unreviewed file after the marked row", function()
        difft.open("HEAD")
        in_tree_on((file_row("dir/c.txt")))

        press("R")

        assert.is_true(difft.state.reviewed["dir/c.txt"])
        assert.are.equal("a.txt", difft.state.shown_path)
        -- Focus stays in the tree, on the row of the file now shown.
        assert.are.equal(difft.state.tree_win, vim.api.nvim_get_current_win())
        assert.are.equal((file_row("a.txt")), vim.api.nvim_win_get_cursor(difft.state.tree_win)[1])
    end)

    it("moves on from the tree past a directory it marks", function()
        difft.open("HEAD")
        in_tree_on((dir_row("dir")))

        press("R")

        assert.are.equal("a.txt", difft.state.shown_path)
        -- Unmarking keeps the shown file.
        in_tree_on((dir_row("dir")))
        press("R")
        assert.are.equal("a.txt", difft.state.shown_path)
    end)

    it("toggles the file under the cursor with R in the tree, shown or not", function()
        difft.open("HEAD")
        in_tree_on((file_row("z.txt")))

        press("R")

        assert.are.equal("✓", marker("z.txt"))
        assert.is_nil(difft.state.visited["z.txt"])
        in_tree_on((file_row("z.txt")))
        press("R")
        assert.are.equal("•", marker("z.txt"))
    end)

    it("marks every file of a directory, and unmarks them once all are marked", function()
        difft.open("HEAD")
        local linenr = dir_row("dir")

        in_tree_on(linenr)
        press("R")
        assert.are.equal("✓", marker("dir/b.txt"))
        assert.are.equal("✓", marker("dir/c.txt"))
        assert.are_not.equal("✓", marker("a.txt"))

        in_tree_on(linenr)
        press("R")
        assert.are_not.equal("✓", marker("dir/b.txt"))
        assert.are_not.equal("✓", marker("dir/c.txt"))
    end)

    it("marks the rest of a partly reviewed directory", function()
        difft.open("HEAD")
        in_tree_on((file_row("dir/b.txt")))
        press("R")

        in_tree_on((dir_row("dir")))
        press("R")

        assert.are.equal("✓", marker("dir/b.txt"))
        assert.are.equal("✓", marker("dir/c.txt"))
    end)

    it("toggles with :DifftToggleReviewed", function()
        difft.open("HEAD")
        local shown = difft.state.shown_path
        vim.api.nvim_set_current_win(difft.state.right_win)
        -- The test runner starts Neovim without plugin files.
        vim.cmd.runtime("plugin/difftastic-nvim.lua")

        vim.cmd("DifftToggleReviewed")

        assert.are.equal("✓", marker(shown))
    end)

    it("marks shown files as reviewed with auto_review", function()
        difft.config.auto_review = true
        difft.open("HEAD")
        local shown = difft.state.shown_path
        show("z.txt")

        assert.are.equal("✓", marker(shown))
        assert.are.equal("✓", marker("z.txt"))
        assert.are.equal("•", marker("dir/c.txt"))
    end)

    --- Every tree row (header excluded) with its marker column checked: rows are
    --- exactly as wide as the panel, end in the marker, and keep a blank column
    --- before it.
    local function assert_marker_column()
        local width = tree.text_width(difft.state.tree_win)
        local rows = vim.api.nvim_buf_get_lines(difft.state.tree_buf, difft.state.header_lines, -1, false)
        for _, text in ipairs(rows) do
            local count = vim.fn.strchars(text)
            assert.are.equal(width, vim.fn.strdisplaywidth(text), text)
            assert.truthy(vim.tbl_contains({ "•", "✓", " " }, vim.fn.strcharpart(text, count - 1, 1)), text)
            assert.are.equal(" ", vim.fn.strcharpart(text, count - 2, 1), text)
        end
    end

    it("puts the marker in the last column at any depth", function()
        difft.open("HEAD")
        in_tree_on((file_row("dir/c.txt")))
        press("R")

        assert_marker_column()
        assert.are.equal("✓", marker("dir/c.txt"))
        assert.are.equal("•", marker("z.txt"))
    end)

    for _, width in ipairs({ 30, 20, 12 }) do
        it(("keeps the text clear of the markers in a %d column panel"):format(width), function()
            difft.open("HEAD")
            in_tree_on((file_row("z.txt")))
            press("R")

            vim.api.nvim_win_set_width(difft.state.tree_win, width)
            vim.api.nvim_exec_autocmds("WinResized", {})

            assert_marker_column()
            assert.are.equal("✓", marker("z.txt"))
            assert.are.equal("•", marker("dir/c.txt"))
            -- A row that no longer fits is cut before the blank column.
            local _, text = file_row("dir/c.txt")
            local count = vim.fn.strchars(text)
            if text:find("…", 1, true) then
                assert.are.equal("…", vim.fn.strcharpart(text, count - 3, 1), text)
            end
        end)
    end

    it("keeps the marker column for wider custom glyphs", function()
        difft.setup({ tree = { icons = { reviewed = "OK" } } })
        difft.open("HEAD")
        in_tree_on((file_row("z.txt")))
        press("R")

        local _, text = file_row("z.txt")
        assert.are.equal("OK", text:sub(-2))
        local _, other = file_row("dir/c.txt")
        assert.are.equal("• ", vim.fn.strcharpart(other, vim.fn.strchars(other) - 2, 2))
    end)

    it("highlights the markers", function()
        difft.open("HEAD")
        in_tree_on((file_row("z.txt")))
        press("R")

        --- Highlight group covering the row's last (marker) byte.
        local function group_at(path)
            local linenr, text = file_row(path)
            local col = #text - 1
            local marks = vim.api.nvim_buf_get_extmarks(difft.state.tree_buf, -1, { linenr - 1, 0 }, { linenr - 1, -1 }, { details = true })
            for _, m in ipairs(marks) do
                local d = m[4]
                if d.hl_group and m[3] <= col and (d.end_col or 0) > col and d.hl_group:find("^DifftTree") and d.hl_group ~= "DifftTreeCurrent" then
                    return d.hl_group
                end
            end
        end
        assert.are.equal("DifftTreeReviewed", group_at("z.txt"))
        assert.are.equal("DifftTreeUnvisited", group_at("dir/c.txt"))
        -- Distinct from the reviewed marker's Added colour in most themes.
        assert.are.equal("Directory", vim.api.nvim_get_hl(0, { name = "DifftTreeUnvisited" }).link)
        assert.are.equal("Added", vim.api.nvim_get_hl(0, { name = "DifftTreeReviewed" }).link)
    end)

    it("uses the glyphs set in tree.icons", function()
        difft.setup({ tree = { icons = { unvisited = "N", reviewed = "R" } } })
        difft.open("HEAD")
        in_tree_on((file_row("z.txt")))
        press("R")

        assert.are.equal("R", marker("z.txt"))
        assert.are.equal("N", marker("dir/c.txt"))
    end)

    it("leaves R alone when the toggle_reviewed key is disabled", function()
        difft.config.keymaps.toggle_reviewed = false
        difft.open("HEAD")

        assert.are.same({}, vim.fn.maparg("R", "n", false, true))
        vim.api.nvim_set_current_win(difft.state.right_win)
        assert.are.same({}, vim.fn.maparg("R", "n", false, true))
    end)

    it("starts over in a new view", function()
        difft.open("HEAD")
        show("z.txt")
        vim.api.nvim_set_current_win(difft.state.right_win)
        press("R")
        difft.close()

        difft.open("HEAD")

        assert.are.same({}, difft.state.reviewed)
        assert.are.equal("•", marker("z.txt"))
    end)

    describe("navigation to unreviewed files", function()
        local function shown()
            return difft.state.shown_path
        end

        --- Mark files as reviewed without moving on (as `R` would).
        local function mark(paths)
            for _, path in ipairs(paths) do
                difft.state.reviewed[path] = true
            end
            tree.refresh_rows(difft.state)
        end

        it("goes to the next and previous unreviewed file in tree order", function()
            difft.open("HEAD")
            assert.are.equal("dir/b.txt", shown())
            vim.api.nvim_set_current_win(difft.state.right_win)

            press("]u")
            assert.are.equal("dir/c.txt", shown())
            press("[u")
            assert.are.equal("dir/b.txt", shown())
        end)

        it("skips reviewed files and wraps around", function()
            difft.open("HEAD")
            mark({ "dir/c.txt", "a.txt" })
            vim.api.nvim_set_current_win(difft.state.right_win)

            press("]u")
            assert.are.equal("z.txt", shown())
            press("]u")
            assert.are.equal("dir/b.txt", shown())
            press("[u")
            assert.are.equal("z.txt", shown())
        end)

        it("works from the tree", function()
            difft.open("HEAD")
            vim.api.nvim_set_current_win(difft.state.tree_win)

            press("]u")

            assert.are.equal("dir/c.txt", shown())
        end)

        it("says so when no other file is left to review", function()
            difft.open("HEAD")
            mark({ "dir/b.txt", "dir/c.txt", "a.txt", "z.txt" })
            -- Unmark the shown file.
            vim.api.nvim_set_current_win(difft.state.right_win)
            press("R")
            local messages, original_notify = {}, vim.notify
            vim.notify = function(msg)
                table.insert(messages, msg)
            end

            press("]u")
            vim.notify = original_notify

            assert.are.equal("dir/b.txt", shown())
            assert.are.equal(1, #messages)
            assert.truthy(messages[1]:find("no other file left to review", 1, true))
        end)

        it("stays on the last file R marks when none is left to review", function()
            difft.open("HEAD")
            mark({ "dir/c.txt", "a.txt", "z.txt" })
            vim.api.nvim_set_current_win(difft.state.right_win)
            local messages, original_notify = {}, vim.notify
            vim.notify = function(msg)
                table.insert(messages, msg)
            end

            press("R")
            vim.notify = original_notify

            assert.are.equal("dir/b.txt", shown())
            assert.is_true(difft.state.reviewed["dir/b.txt"])
            assert.truthy(messages[1] and messages[1]:find("no other file left to review", 1, true))
        end)

        it("opens a collapsed directory around the file it goes to", function()
            difft.open("HEAD")
            show("a.txt")
            local node = difft.state.tree:get_node((dir_row("dir")))
            node:collapse()
            difft.state.tree:render()
            vim.api.nvim_set_current_win(difft.state.right_win)

            press("[u")

            assert.are.equal("dir/c.txt", shown())
            assert.is_true(difft.state.tree:get_node((dir_row("dir"))):is_expanded())
            local ns = vim.api.nvim_create_namespace("difft-tree-current")
            local marks = vim.api.nvim_buf_get_extmarks(difft.state.tree_buf, ns, 0, -1, {})
            assert.are.equal(file_row("dir/c.txt") - 1, marks[1][2])
        end)

        it("leaves ]u and [u alone when the keys are disabled", function()
            difft.config.keymaps.next_unreviewed = false
            difft.config.keymaps.prev_unreviewed = false
            difft.open("HEAD")

            vim.api.nvim_set_current_win(difft.state.right_win)
            assert.are.same({}, vim.fn.maparg("]u", "n", false, true))
            assert.are.same({}, vim.fn.maparg("[u", "n", false, true))
        end)
    end)

    describe("progress in the header", function()
        local function file_line()
            return vim.api.nvim_buf_get_lines(difft.state.tree_buf, 0, 1, false)[1]
        end

        it("shows the file count while nothing is reviewed", function()
            difft.open("HEAD")

            assert.truthy(file_line():find("4 files", 1, true), file_line())
        end)

        it("counts reviewed files as they are marked and unmarked", function()
            difft.open("HEAD")
            vim.api.nvim_set_current_win(difft.state.right_win)

            press("R")
            assert.truthy(file_line():find("1/4 reviewed", 1, true), file_line())
            in_tree_on((dir_row("dir")))
            press("R")
            assert.truthy(file_line():find("2/4 reviewed", 1, true), file_line())
            in_tree_on((dir_row("dir")))
            press("R")
            assert.truthy(file_line():find("4 files", 1, true), file_line())
        end)

        it("updates the header without warnings about the read-only tree buffer", function()
            difft.open("HEAD")
            -- Neovim warns only on the first change to an unmodified buffer.
            vim.bo[difft.state.tree_buf].modified = false
            vim.v.warningmsg = ""
            vim.api.nvim_set_current_win(difft.state.right_win)

            press("R")

            assert.are.equal("", vim.v.warningmsg)
        end)

        it("counts files reviewed automatically", function()
            difft.config.auto_review = true
            difft.open("HEAD")
            show("z.txt")

            assert.truthy(file_line():find("2/4 reviewed", 1, true), file_line())
        end)
    end)

    describe("directory marker", function()
        local function dir_marker()
            local _, text = dir_row("dir")
            return vim.fn.strcharpart(text, vim.fn.strchars(text) - 1, 1)
        end

        it("shows reviewed once every file in the directory is", function()
            difft.open("HEAD")
            assert.are.equal(" ", dir_marker())

            in_tree_on((file_row("dir/b.txt")))
            press("R")
            assert.are.equal(" ", dir_marker())
            in_tree_on((file_row("dir/c.txt")))
            press("R")
            assert.are.equal("✓", dir_marker())
            in_tree_on((file_row("dir/c.txt")))
            press("R")
            assert.are.equal(" ", dir_marker())
        end)

        it("never shows the unvisited marker", function()
            difft.open("HEAD")
            show("a.txt")

            assert.are.equal(" ", dir_marker())
        end)
    end)
end)
