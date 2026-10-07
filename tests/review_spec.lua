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
            local node = tree.tree:get_node(linenr)
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
        vim.api.nvim_set_current_win(difft.state.left_win)
        press("R")
        assert.are.equal(" ", marker("dir/b.txt"))
        assert.is_nil(difft.state.reviewed["dir/b.txt"])
    end)

    it("toggles the file under the cursor with R in the tree, shown or not", function()
        difft.open("HEAD")
        in_tree_on((file_row("z.txt")))

        press("R")

        assert.are.equal("✓", marker("z.txt"))
        assert.is_nil(difft.state.visited["z.txt"])
        -- The tree cursor stays on the row.
        assert.are.equal((file_row("z.txt")), vim.api.nvim_win_get_cursor(difft.state.tree_win)[1])
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
        local rows = vim.api.nvim_buf_get_lines(difft.state.tree_buf, tree.header_lines, -1, false)
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
end)
