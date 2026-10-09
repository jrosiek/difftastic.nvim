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

describe("header resize", function()
    local original_get

    before_each(function()
        vim.o.columns = 200
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

    local function lines()
        return vim.api.nvim_buf_get_lines(difft.state.tree_buf, 0, -1, false)
    end

    local function header_widths()
        local widths = {}
        for i, line in ipairs(lines()) do
            if i > difft.state.header_lines then
                break
            end
            widths[i] = vim.fn.strdisplaywidth(line)
        end
        return widths
    end

    -- Headless Neovim does not redraw, so WinResized is fired by hand.
    local function resize(width)
        vim.api.nvim_win_set_width(difft.state.tree_win, width)
        vim.api.nvim_exec_autocmds("WinResized", {})
    end

    local function resize_autocmds()
        local ok, cmds = pcall(vim.api.nvim_get_autocmds, { group = "DifftTreeResize", event = "WinResized" })
        return ok and cmds or {}
    end

    it("draws the box at the window width when opened", function()
        difft.open("HEAD")

        local width = vim.api.nvim_win_get_width(difft.state.tree_win)
        assert.are.same({ width, width, width, width }, header_widths())
    end)

    for _, width in ipairs({ 60, 30 }) do
        it("redraws the box when the panel is resized to " .. width, function()
            difft.open("HEAD")
            local before = lines()

            resize(width)

            assert.are.same({ width, width, width, width }, header_widths())
            -- Header height and the tree rows' text are unchanged; only the padding up
            -- to the review marker column follows the width.
            local after = lines()
            assert.are.equal(#before, #after)
            local function text(rows)
                local result = {}
                for i, row in ipairs(vim.list_slice(rows, difft.state.header_lines + 1)) do
                    local marker = vim.fn.strcharpart(row, vim.fn.strchars(row) - 1, 1)
                    result[i] = { (vim.fn.strcharpart(row, 0, vim.fn.strchars(row) - 1):gsub("%s+$", "")), marker }
                end
                return result
            end
            assert.are.same(text(before), text(after))
        end)
    end

    describe("with side columns enabled globally", function()
        local saved

        before_each(function()
            saved = {}
            for _, name in ipairs({ "number", "relativenumber", "signcolumn", "foldcolumn", "statuscolumn" }) do
                saved[name] = vim.go[name]
            end
            vim.go.number = true
            vim.go.relativenumber = true
            vim.go.signcolumn = "yes:2"
            vim.go.foldcolumn = "1"
            vim.go.statuscolumn = "%s%C%l "
        end)

        after_each(function()
            for name, value in pairs(saved) do
                vim.go[name] = value
            end
        end)

        it("turns off every column left of the text in the panel", function()
            difft.open("HEAD")
            local win = difft.state.tree_win

            assert.is_false(vim.wo[win].number)
            assert.is_false(vim.wo[win].relativenumber)
            assert.are.equal("no", vim.wo[win].signcolumn)
            assert.are.equal("0", vim.wo[win].foldcolumn)
            assert.are.equal("", vim.wo[win].statuscolumn)
            assert.are.equal(0, vim.fn.getwininfo(win)[1].textoff)
            local width = vim.api.nvim_win_get_width(win)
            assert.are.same({ width, width, width, width }, header_widths())
        end)
    end)

    it("narrows the box to the text width when a column appears later", function()
        difft.open("HEAD")
        local win = difft.state.tree_win
        -- e.g. a statuscolumn plugin that sets the option on every window
        vim.wo[win].statuscolumn = "XXX"
        vim.cmd.redraw() -- the status column width is measured when drawing
        assert.are.equal(3, vim.fn.getwininfo(win)[1].textoff)

        vim.api.nvim_exec_autocmds("WinResized", {})

        local width = vim.api.nvim_win_get_width(win) - 3
        assert.are.same({ width, width, width, width }, header_widths())
    end)

    it("keeps long tree rows on one line in a narrow panel", function()
        vim.go.wrap = true
        binary.get = function()
            return {
                run_diff = function()
                    return { files = { file_record(string.rep("long_directory_name/", 4) .. "file.txt") } }
                end,
            }
        end
        difft.open("HEAD")
        resize(30)

        local win = difft.state.tree_win
        assert.is_false(vim.wo[win].wrap)
        -- Every buffer line takes exactly one screen row.
        local rows = vim.api.nvim_win_text_height(win, {}).all
        assert.are.equal(vim.api.nvim_buf_line_count(difft.state.tree_buf), rows)
    end)

    describe("with rows wider than the panel", function()
        local long = string.rep("long_directory_name/", 4) .. "file.txt"

        before_each(function()
            binary.get = function()
                return {
                    run_diff = function()
                        return { files = { file_record("a.txt"), file_record(long) } }
                    end,
                }
            end
        end)

        local function tree_rows()
            return vim.list_slice(lines(), difft.state.header_lines + 1)
        end

        it("ends a row that does not fit with an ellipsis", function()
            difft.open("HEAD")
            resize(30)

            local cut = 0
            for _, row in ipairs(tree_rows()) do
                assert.are.equal(30, vim.fn.strdisplaywidth(row), row)
                if row:find("…", 1, true) then
                    cut = cut + 1
                    -- The ellipsis ends the text, just before the marker column.
                    assert.are.equal("…", vim.fn.strcharpart(row, vim.fn.strchars(row) - 3, 1), row)
                end
            end
            assert.is_true(cut > 0, "no row was cut")
        end)

        it("shows the whole row again when the panel widens", function()
            difft.open("HEAD")
            resize(30)
            resize(120)

            local found = false
            for _, row in ipairs(tree_rows()) do
                assert.is_nil(row:find("…", 1, true), row)
                found = found or row:find("file.txt", 1, true) ~= nil
            end
            assert.is_true(found)
        end)

        it("keeps the tree cursor and the current-file highlight across a resize", function()
            difft.open("HEAD")
            local win = difft.state.tree_win
            local count = vim.api.nvim_buf_line_count(difft.state.tree_buf)
            vim.api.nvim_win_set_cursor(win, { count, 0 })

            resize(30)

            assert.are.equal(count, vim.api.nvim_win_get_cursor(win)[1])
            local ns = vim.api.nvim_create_namespace("difft-tree-current")
            local marks = vim.api.nvim_buf_get_extmarks(difft.state.tree_buf, ns, 0, -1, {})
            assert.are.equal(1, #marks)
        end)
    end)

    it("ignores resizes that leave the panel width unchanged", function()
        difft.open("HEAD")
        local before = lines()

        vim.api.nvim_exec_autocmds("WinResized", {})

        assert.are.same(before, lines())
    end)

    it("removes its autocmd on the first resize after the view is closed", function()
        difft.open("HEAD")
        assert.are.equal(1, #resize_autocmds())
        difft.close()

        vim.api.nvim_exec_autocmds("WinResized", {})

        assert.are.equal(0, #resize_autocmds())
    end)
end)
