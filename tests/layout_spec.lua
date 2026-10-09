--- Rows rebuilt from each side's lines and fillers.

local layout = require("difftastic-nvim.layout")
local model = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/model.lua")

local function cell(content, highlighted)
    return { content = content, highlights = highlighted and { { start = 0, ["end"] = -1 } } or {}, is_filler = false }
end
local FILLER = { content = "", highlights = {}, is_filler = true }

describe("layout", function()
    it("gives each side its lines and the fillers before each line", function()
        local file = model.from_rows({
            rows = {
                { left = cell("a"), right = cell("a") },
                { left = FILLER, right = cell("added", true) },
                { left = cell("c"), right = cell("c") },
                { left = cell("gone", true), right = FILLER },
            },
            hunk_starts = { 1, 3 },
        })
        assert.are.same({ 0, 1, 0, 0 }, file.base.fillers)
        assert.are.same({ 0, 0, 0, 1 }, file.head.fillers)
        assert.are.same({ { head = 2 }, { base = 3 } }, file.hunks)
    end)

    for name, rows in pairs({
        ["a change in the middle"] = {
            { left = cell("a"), right = cell("a") },
            { left = cell("x", true), right = cell("y", true) },
            { left = FILLER, right = cell("added", true) },
            { left = cell("z"), right = cell("z") },
        },
        ["fillers at both ends"] = {
            { left = FILLER, right = cell("top", true) },
            { left = cell("a"), right = cell("a") },
            { left = cell("bottom", true), right = FILLER },
        },
        ["a created file"] = {
            { left = FILLER, right = cell("1", true) },
            { left = FILLER, right = cell("2", true) },
        },
        ["a deleted file"] = {
            { left = cell("1", true), right = FILLER },
        },
    }) do
        it("rebuilds the rows both panes show for " .. name, function()
            local starts = {}
            local in_hunk = false
            for i, row in ipairs(rows) do
                local changed = row.left.is_filler or row.right.is_filler or #row.left.highlights > 0 or #row.right.highlights > 0
                if changed and not in_hunk then
                    table.insert(starts, i - 1)
                end
                in_hunk = changed
            end
            local file = model.from_rows({ rows = rows, hunk_starts = starts })

            layout.ensure_rows(file)

            assert.are.same(rows, file.rows)
            assert.are.same(starts, file.hunk_starts)
            for i, row in ipairs(rows) do
                assert.are.equal(row.left.is_filler, file.aligned_lines[i][1] == nil)
                assert.are.equal(row.right.is_filler, file.aligned_lines[i][2] == nil)
            end
        end)
    end

    it("leaves rows already built alone", function()
        local rows = { { left = cell("a"), right = cell("b") } }
        local file = { rows = rows, hunk_starts = { 0 } }
        layout.ensure_rows(file)
        assert.are.equal(rows, file.rows)
    end)
end)
