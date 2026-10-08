--- How a file's two sides line up: each side's real lines with the fillers before
--- them, as the library returns them, turned into the rows both panes show.
local M = {}

--- A side's rows in order: its line numbers, and `false` for each filler.
--- @param side table|nil `{ lines, fillers }`
--- @return (number|false)[]
local function side_rows(side)
    local rows = {}
    if not side then
        return rows
    end
    for i = 1, #side.lines + 1 do
        for _ = 1, side.fillers[i] or 0 do
            rows[#rows + 1] = false
        end
        if i <= #side.lines then
            rows[#rows + 1] = i
        end
    end
    return rows
end

--- Give a file its aligned rows, once: `file.rows` (both sides of each row, with
--- fillers), `file.aligned_lines` (each row's 0-based line per side, nil on a
--- filler) and `file.hunk_starts` (0-based first row of each hunk).
--- @param file table File from the library: `base`, `head`, `hunks`
function M.ensure_rows(file)
    if file.rows then
        return
    end
    local base, head = side_rows(file.base), side_rows(file.head)
    local rows, aligned = {}, {}
    local row_of = { base = {}, head = {} }
    local function cell(side, line)
        if not line then
            return { content = "", highlights = {}, is_filler = true }
        end
        local entry = side.lines[line]
        return { content = entry.content, highlights = entry.highlights, is_filler = false }
    end
    for r = 1, math.max(#base, #head) do
        local b, h = base[r] or false, head[r] or false
        rows[r] = { left = cell(file.base, b), right = cell(file.head, h) }
        aligned[r] = { b and b - 1 or nil, h and h - 1 or nil }
        if b then
            row_of.base[b] = r
        end
        if h then
            row_of.head[h] = r
        end
    end

    local hunk_starts = {}
    for _, hunk in ipairs(file.hunks or {}) do
        local first = math.min(
            hunk.base and row_of.base[hunk.base] or math.huge,
            hunk.head and row_of.head[hunk.head] or math.huge
        )
        if first ~= math.huge then
            table.insert(hunk_starts, first - 1)
        end
    end

    file.rows, file.aligned_lines, file.hunk_starts = rows, aligned, hunk_starts
end

return M
