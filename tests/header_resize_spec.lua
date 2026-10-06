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
            if i > tree.header_lines then
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
            -- Header height and the file tree below it are unchanged.
            local after = lines()
            assert.are.equal(#before, #after)
            assert.are.same(vim.list_slice(before, tree.header_lines + 1), vim.list_slice(after, tree.header_lines + 1))
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
