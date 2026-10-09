--- Pane rows mapped to file lines: line numbers of the file in the panes, none on
--- fillers.

local diff = require("difftastic-nvim.diff")
local model = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/model.lua")

local function cell(content, highlighted)
    return { content = content, highlights = highlighted and { { start = 0, ["end"] = -1 } } or {}, is_filler = false }
end
local FILLER = { content = "", highlights = {}, is_filler = true }

--- Rows: 1 a|a, 2 -|added, 3 -|added2, 4 c|c, 5 gone|-.
local function sample()
    return model.from_rows({
        language = "Lua",
        path = "sample.lua",
        rows = {
            { left = cell("a"), right = cell("a") },
            { left = FILLER, right = cell("added", true) },
            { left = FILLER, right = cell("added2", true) },
            { left = cell("c"), right = cell("c") },
            { left = cell("gone", true), right = FILLER },
        },
        hunk_starts = { 1, 4 },
    })
end

--- The pane's statuscolumn text on each buffer row, trimmed.
local function column(win)
    local result = {}
    for row = 1, vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win)) do
        local text = vim.api.nvim_eval_statusline(diff.STATUSCOLUMN, { winid = win, use_statuscol_lnum = row }).str
        result[row] = vim.trim(text)
    end
    return result
end

describe("line numbers", function()
    local state

    before_each(function()
        package.loaded["difftastic-nvim"] = { config = { highlight_mode = "difftastic" } }
        vim.cmd("tabnew")
        state = {}
        diff.open(state)
        diff.render(state, sample())
    end)

    after_each(function()
        vim.cmd("tabclose")
        package.loaded["difftastic-nvim"] = nil
    end)

    it("maps each row showing a line to that line, and back", function()
        local base, head = {}, {}
        for row = 1, 5 do
            base[row] = diff.file_line(state.left_buf, row) or false
            head[row] = diff.file_line(state.right_buf, row) or false
        end
        assert.are.same({ 1, false, false, 2, 3 }, base)
        assert.are.same({ 1, 2, 3, 4, false }, head)
        assert.are.equal(4, diff.buf_row(state.left_buf, 2))
        assert.are.equal(4, diff.buf_row(state.right_buf, 4))
        assert.is_nil(diff.buf_row(state.right_buf, 5))
    end)

    it("finds the nearest line from a filler row, the one above on a tie", function()
        assert.are.equal(1, diff.nearest_file_line(state.left_buf, 2))
        assert.are.equal(2, diff.nearest_file_line(state.left_buf, 3))
        assert.are.equal(4, diff.nearest_file_line(state.right_buf, 5))
        -- A single filler row between lines 2 and 3 is as near to both.
        vim.bo[state.left_buf].modifiable = true
        vim.api.nvim_buf_set_lines(state.left_buf, 4, 4, false, { "" })
        vim.bo[state.left_buf].modifiable = false
        assert.are.equal(2, diff.nearest_file_line(state.left_buf, 5))
    end)

    it("shows the file's line numbers, none on fillers", function()
        assert.are.same({ "1", "", "", "2", "3" }, column(state.left_win))
        assert.are.same({ "1", "2", "3", "4", "" }, column(state.right_win))
    end)

    it("shows relative numbers on lines with 'relativenumber'", function()
        vim.wo[state.left_win].relativenumber = true
        vim.api.nvim_win_set_cursor(state.left_win, { 4, 0 })
        assert.are.same({ "3", "", "", "2", "1" }, column(state.left_win))
    end)

    it("keeps the mapping when rows are inserted between lines", function()
        vim.bo[state.left_buf].modifiable = true
        vim.api.nvim_buf_set_lines(state.left_buf, 3, 3, false, { "", "" })
        vim.bo[state.left_buf].modifiable = false
        assert.are.same({ "1", "", "", "", "", "2", "3" }, column(state.left_win))
        assert.are.equal(6, diff.buf_row(state.left_buf, 2))
    end)

    it("clears the mapping when the next file is shown", function()
        diff.render(state, model.from_rows({
            language = "Lua",
            rows = { { left = FILLER, right = cell("new", true) } },
            hunk_starts = { 0 },
        }))
        assert.are.same({ "" }, column(state.left_win))
        assert.are.same({ "1" }, column(state.right_win))
    end)

    it("keeps the own line numbers of another buffer opened in a pane", function()
        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "x", "y" })
        vim.api.nvim_win_set_buf(state.left_win, buf)
        assert.are.same({ "1", "2" }, column(state.left_win))
        vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("does not wrap long lines and binds sideways scrolling", function()
        assert.is_false(vim.wo[state.left_win].wrap)
        assert.is_false(vim.wo[state.right_win].wrap)
        assert.is_truthy(vim.tbl_contains(vim.opt.scrollopt:get(), "hor"))
    end)

    it("shows no line number on a closed fold", function()
        vim.api.nvim_win_call(state.right_win, function()
            vim.wo.foldmethod = "manual"
            vim.cmd("2,3fold")
        end)
        assert.are.same({ "1", "", "", "4", "" }, column(state.right_win))
    end)
end)
