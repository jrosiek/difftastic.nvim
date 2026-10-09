--- Test helper: builds a file as the library returns it (`base`, `head`, `hunks`)
--- from aligned rows, the way specs describe diffs most readably.

local M = {}

local function is_changed(row)
    return row.left.is_filler or row.right.is_filler or #row.left.highlights > 0 or #row.right.highlights > 0
end

--- `record` with `rows` (`{ left, right }` sides: `content`, `highlights`,
--- `is_filler`) and `hunk_starts` (0-based rows) turned into `base`, `head` and
--- `hunks`; `rows`, `hunk_starts` and `aligned_lines` are dropped.
--- @param record table
--- @return table
function M.from_rows(record)
    local file = vim.deepcopy(record)
    local rows, hunk_starts = file.rows or {}, file.hunk_starts or {}
    file.rows, file.hunk_starts, file.aligned_lines = nil, nil, nil
    local sides = { base = { lines = {}, fillers = {} }, head = { lines = {}, fillers = {} } }
    local pending = { base = 0, head = 0 }
    local line_of = { base = {}, head = {} }
    for r, row in ipairs(rows) do
        for name, cell in pairs({ base = row.left, head = row.right }) do
            local side = sides[name]
            if cell.is_filler then
                pending[name] = pending[name] + 1
            else
                table.insert(side.fillers, pending[name])
                pending[name] = 0
                table.insert(side.lines, { content = cell.content, highlights = cell.highlights })
                line_of[name][r] = #side.lines
            end
        end
    end
    table.insert(sides.base.fillers, pending.base)
    table.insert(sides.head.fillers, pending.head)
    file.base, file.head = sides.base, sides.head

    file.hunks = {}
    for _, start in ipairs(hunk_starts) do
        local hunk = {}
        local r = start + 1
        while rows[r] and (r == start + 1 or is_changed(rows[r])) do
            hunk.base = hunk.base or line_of.base[r]
            hunk.head = hunk.head or line_of.head[r]
            r = r + 1
        end
        table.insert(file.hunks, hunk)
    end
    return file
end

return M
