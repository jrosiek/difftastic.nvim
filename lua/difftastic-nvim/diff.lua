--- Side-by-side diff display with synchronized scrolling.
local M = {}

local FILLER = string.rep("╱", 500)

--- Marks tying each real line of a side to the buffer row showing it: one per
--- line, with the line number as its id. Rows inserted between lines (fillers)
--- carry none, and the marks move with their lines when rows are inserted.
local LINE_NS = vim.api.nvim_create_namespace("difft-lines")

--- The pane's 'statuscolumn': line numbers of the file, not of the buffer.
M.STATUSCOLUMN = "%!v:lua.require'difftastic-nvim.diff'.statuscolumn()"

--- Ensure treesitter is attached for a buffer/filetype.
--- @param buf number
--- @param ft string
local function ensure_treesitter(buf, ft)
    if not vim.api.nvim_buf_is_valid(buf) then
        return
    end

    if vim.bo[buf].filetype ~= ft then
        vim.bo[buf].filetype = ft
    end

    pcall(vim.treesitter.start, buf, ft)
end

--- Maps difftastic language names to Vim filetypes
local FILETYPES = {
    Rust = "rust",
    Lua = "lua",
    TOML = "toml",
    JSON = "json",
    JavaScript = "javascript",
    TypeScript = "typescript",
    Python = "python",
    Go = "go",
    C = "c",
    ["C++"] = "cpp",
    Java = "java",
    Ruby = "ruby",
    Shell = "sh",
    Bash = "bash",
    Markdown = "markdown",
    YAML = "yaml",
    HTML = "html",
    CSS = "css",
    Clojure = "clojure",
}

--- Set buffer options for diff buffers.
--- @param buf number Buffer handle
local function setup_diff_buffer(buf)
    vim.bo[buf].buftype = "nofile"
    -- Kept while its pane is closed for a file that exists on one side only;
    -- deleted with the view.
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].swapfile = false
    vim.bo[buf].modifiable = false
    vim.b[buf].difftastic_pane = true
end

--- Set window options for diff windows.
--- @param win number Window handle
local function setup_diff_window(win)
    vim.wo[win].scrollbind = true
    vim.wo[win].cursorbind = true
    -- A wrapped line takes more screen rows on one side than the other, which
    -- 'scrollbind' does not make up for; scroll long lines sideways instead.
    vim.wo[win].wrap = false
    vim.wo[win].number = true
    vim.wo[win].statuscolumn = M.STATUSCOLUMN
    vim.wo[win].signcolumn = "no"
    vim.wo[win].winhighlight = "WinBar:DifftBar,WinBarNC:DifftBarNC"
end

local function is_full_line_highlight(hl)
    return hl.start == 0 and hl["end"] == -1
end

local function range_covers(highlights, col)
    for _, hl in ipairs(highlights) do
        if col >= hl.start and col < hl["end"] then
            return true
        end
    end
    return false
end

local function covers_all_non_whitespace(content, highlights)
    local has_non_whitespace = false

    for col = 0, #content - 1 do
        local char = content:sub(col + 1, col + 1)
        if not char:match("%s") then
            has_non_whitespace = true
            if not range_covers(highlights, col) then
                return false
            end
        end
    end

    return has_non_whitespace
end

local function set_line_background(buf, ns, line, hl_group, priority)
    vim.api.nvim_buf_set_extmark(buf, ns, line, 0, {
        end_row = line + 1,
        end_col = 0,
        hl_eol = true,
        hl_group = hl_group,
        priority = priority,
    })
end

local function set_range_highlight(buf, ns, line, start_col, end_col, hl_group, priority)
    if start_col >= end_col then
        return
    end

    vim.api.nvim_buf_set_extmark(buf, ns, line, start_col, {
        end_row = line,
        end_col = end_col,
        hl_group = hl_group,
        priority = priority,
    })
end

local function apply_diff_highlights(buf, ns, line, content, highlights, range_hl, line_hl)
    if #highlights == 0 then
        return
    end

    if #highlights == 1 and is_full_line_highlight(highlights[1]) then
        set_line_background(buf, ns, line, line_hl, 100)
        return
    end

    if covers_all_non_whitespace(content, highlights) then
        set_line_background(buf, ns, line, line_hl, 100)
        return
    end

    set_line_background(buf, ns, line, line_hl, 100)

    for _, hl in ipairs(highlights) do
        set_range_highlight(buf, ns, line, hl.start, hl["end"], range_hl, 200)
    end
end

--- Open the side-by-side diff panes to the right of the current window, which
--- keeps its place. Focus ends in the head (right) pane.
--- @param state table Plugin state
function M.open(state)
    vim.cmd("rightbelow vsplit")
    state.left_win = vim.api.nvim_get_current_win()
    state.left_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(state.left_win, state.left_buf)

    vim.cmd("rightbelow vsplit")
    state.right_win = vim.api.nvim_get_current_win()
    state.right_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(state.right_win, state.right_buf)

    setup_diff_buffer(state.left_buf)
    setup_diff_buffer(state.right_buf)
    setup_diff_window(state.left_win)
    setup_diff_window(state.right_win)
    -- Keep sideways scrolling in step too ('scrollopt' is global).
    vim.opt.scrollopt:append("hor")

    -- :vsplit gives the new (current) pane at least 'winwidth' columns, so in a
    -- narrow terminal the base pane would get what is left; split evenly.
    local total = vim.api.nvim_win_get_width(state.left_win) + vim.api.nvim_win_get_width(state.right_win)
    vim.api.nvim_win_set_width(state.left_win, math.floor(total / 2))
end

--- How a file changed: its glyph, highlight group and name, as the tree and the
--- pane bars show it.
--- @param file table A file or its tree node (`status`, `moved_from`, `additions`, `deletions`)
--- @return string glyph
--- @return string hl_group
--- @return string name "renamed", "added", "deleted", "modified" or "unchanged"
function M.file_status(file)
    if file.moved_from then
        return "➜", "DifftTreeRenamed", "renamed"
    end
    if file.status == "created" then
        return "+", "DifftTreeAdded", "added"
    end
    if file.status == "deleted" then
        return "-", "DifftTreeDeleted", "deleted"
    end
    if (file.additions or 0) > 0 or (file.deletions or 0) > 0 then
        return "●", "DifftTreeModified", "modified"
    end
    return " ", "DifftTreeMuted", "unchanged"
end

--- Escape text for a statusline-like option ('winbar').
local function escape_bar(text)
    return (text:gsub("%%", "%%%%"))
end

--- The file-type icon of a file name and its highlight group, when icons are
--- enabled and nvim-web-devicons is installed.
--- @param name string
--- @return string|nil icon
--- @return string|nil hl_group
local function file_icon(name)
    local ok, devicons = pcall(require, "nvim-web-devicons")
    if not (ok and require("difftastic-nvim").config.tree.icons.enable) then
        return nil
    end
    return devicons.get_icon(name, nil, { default = true })
end

--- Cut text to at most `width` display cells, keeping its start (`keep_end`
--- false) or its end, with "…" where it was cut.
local function cut(text, width, keep_end)
    if vim.fn.strdisplaywidth(text) <= width then
        return text
    end
    if width <= 0 then
        return ""
    end
    local chars = vim.fn.strchars(text)
    local take = chars
    local function part(n)
        return keep_end and vim.fn.strcharpart(text, chars - n, n) or vim.fn.strcharpart(text, 0, n)
    end
    while take > 0 and vim.fn.strdisplaywidth(part(take)) > width - 1 do
        take = take - 1
    end
    return keep_end and ("…" .. part(take)) or (part(take) .. "…")
end

--- The bar of a diff pane, laid out for the window being drawn (the 'winbar'
--- expression set by `set_bars`): the icon, the file name, the directory dimmed,
--- and the side's count on the right, with a one-cell margin on both sides. When
--- the pane is too narrow, the directory is cut from its left, then left out,
--- then the count, and only then is the file name cut.
--- @return string
function M.pane_bar()
    -- The window being drawn; nvim_eval_statusline() makes it current instead.
    local win = vim.g.statusline_winid or vim.api.nvim_get_current_win()
    local bar = vim.w[win].difft_bar
    if not bar then
        return ""
    end
    local width = vim.api.nvim_win_get_width(win) - 2
    if width < 1 then
        -- No room for a character between the margins: blank, never wider than
        -- the pane (Neovim would cut it with "<").
        return "%*" .. string.rep(" ", width + 2)
    end
    local function w(text)
        return vim.fn.strdisplaywidth(text)
    end
    local icon = bar.icon and (bar.icon .. " ") or ""
    if w(icon) >= width then
        -- Not even one character of the name next to the icon: the name alone.
        icon = ""
    end
    local count = bar.count and (" " .. bar.count) or ""
    local dir = bar.dir
    local fixed = w(icon) + w(bar.name)
    -- The directory, set off by two spaces, gets what is left after the rest; a
    -- cut one shows at least one character after the "…".
    local room = width - fixed - w(count) - 2
    if dir and room < math.min(w(dir), 2) then
        dir = nil
    elseif dir then
        dir = cut(dir, room, true)
    end
    if not dir and fixed + w(count) > width then
        count = ""
    end
    local name = cut(bar.name, width - w(icon), false)

    -- Neovim drops leading spaces of an expression's plain result; an item in
    -- front keeps the margin.
    local text = "%* "
    if icon ~= "" then
        text = text .. ("%%#%s#%s%%* "):format(bar.icon_hl or "DifftBarMuted", escape_bar(bar.icon))
    end
    text = text .. escape_bar(name)
    if dir then
        text = text .. "  %#DifftBarMuted#" .. escape_bar(dir) .. "%*"
    end
    if count ~= "" then
        text = text .. ("%%= %%#%s#%s%%*"):format(bar.count_hl, bar.count)
    end
    return text .. " "
end

--- The bar of the side panel (the 'winbar' expression set by `set_bars`): how the
--- shown file changed, right-aligned with a one-cell margin, its name cut with
--- "…" when the panel is too narrow.
--- @return string
function M.panel_bar()
    -- The window being drawn; nvim_eval_statusline() makes it current instead.
    local win = vim.g.statusline_winid or vim.api.nvim_get_current_win()
    local status = vim.w[win].difft_status
    if not status then
        return ""
    end
    local text = cut(status.glyph .. " " .. status.name, vim.api.nvim_win_get_width(win) - 1, false)
    return ("%%=%%#%s#%s%%* "):format(status.hl_group, escape_bar(text))
end

--- Show the shown file in bars at the top of the side panel and the panes. The
--- panel's bar has how the file changed, right-aligned next to the panes. Each
--- pane's bar has the file on that side (the base pane names the file as it was,
--- its old path for a rename) and that side's line count: removed lines in the
--- base pane, added lines in the head pane (see `pane_bar`).
--- @param state table Plugin state
--- @param file table File from the library
function M.set_bars(state, file)
    local glyph, hl_group, name = M.file_status(file)
    if state.tree_win and vim.api.nvim_win_is_valid(state.tree_win) then
        vim.w[state.tree_win].difft_status = { glyph = glyph, hl_group = hl_group, name = name }
        vim.wo[state.tree_win].winbar = "%{%v:lua.require'difftastic-nvim.diff'.panel_bar()%}"
    end

    -- A renamed file has the status "created", at its new path.
    local base = file.moved_from or (file.status ~= "created" and file.path or nil)
    local head = file.status ~= "deleted" and file.path or nil
    local panes = {
        { state.left_win, base, (file.deletions or 0) > 0 and ("-" .. file.deletions) or nil, "DifftFileDeleted" },
        { state.right_win, head, (file.additions or 0) > 0 and ("+" .. file.additions) or nil, "DifftFileAdded" },
    }
    for _, pane in ipairs(panes) do
        local win, path = pane[1], pane[2]
        if win and path and vim.api.nvim_win_is_valid(win) then
            local file_name, dir = vim.fn.fnamemodify(path, ":t"), vim.fn.fnamemodify(path, ":h")
            local icon, icon_hl = file_icon(file_name)
            vim.w[win].difft_bar = {
                name = file_name,
                dir = dir ~= "." and dir or nil,
                icon = icon,
                icon_hl = icon_hl,
                count = pane[3],
                count_hl = pane[4],
            }
            vim.wo[win].winbar = "%{%v:lua.require'difftastic-nvim.diff'.pane_bar()%}"
        end
    end
end

--- Show only the pane of the side a file exists on: an added file has no base
--- side, a deleted one no head side. The other pane's window is closed, so the
--- remaining pane takes the width of both, and opened again, on its side and in
--- the panes' last ratio, for a file with both sides.
--- @param state table Plugin state
--- @param file table File from the library
function M.set_panes(state, file)
    local function valid(win)
        return win and vim.api.nvim_win_is_valid(win)
    end
    -- A renamed file has the status "created", at its new path.
    local wanted = {
        base = file.moved_from ~= nil or file.status ~= "created",
        head = file.status ~= "deleted",
    }
    local panes = {
        base = { win = "left_win", buf = "left_buf", split = "left", other = "head" },
        head = { win = "right_win", buf = "right_buf", split = "right", other = "base" },
    }
    -- Open first, then close: from an added file straight to a deleted one, the
    -- base pane must be back before the head pane can go.
    local reopened = false
    for side, pane in pairs(panes) do
        local other = state[panes[pane.other].win]
        if wanted[side] and not valid(state[pane.win]) and valid(other) then
            local win = vim.api.nvim_open_win(state[pane.buf], false, { split = pane.split, win = other })
            setup_diff_window(win)
            state[pane.win] = win
            reopened = true
        end
    end
    for side, pane in pairs(panes) do
        local win, other = state[pane.win], state[panes[pane.other].win]
        if not wanted[side] and valid(win) and valid(other) then
            if vim.api.nvim_get_current_win() == win then
                vim.api.nvim_set_current_win(other)
                state.pane_side = pane.other
            end
            vim.api.nvim_win_close(win, true)
            state[pane.win] = nil
        end
    end
    if reopened then
        require("difftastic-nvim").restore_pane_split(state)
    end
end

--- Render a file's diff content into the left/right panes.
--- @param state table Plugin state
--- @param file table File from the library (`base`, `head`, `hunks`, `language`)
function M.render(state, file)
    local config = require("difftastic-nvim").config
    require("difftastic-nvim.layout").ensure_rows(file)
    local rows = file.rows or {}
    M.set_panes(state, file)
    M.set_bars(state, file)

    -- Rows where hunks start (1-based).
    state.hunk_positions = {}
    for _, pos in ipairs(file.hunk_starts or {}) do
        table.insert(state.hunk_positions, pos + 1)
    end

    vim.api.nvim_buf_clear_namespace(state.left_buf, LINE_NS, 0, -1)
    vim.api.nvim_buf_clear_namespace(state.right_buf, LINE_NS, 0, -1)

    if #rows == 0 then
        vim.bo[state.left_buf].modifiable = true
        vim.bo[state.right_buf].modifiable = true
        vim.api.nvim_buf_set_lines(state.left_buf, 0, -1, false, { "-- Empty --" })
        vim.api.nvim_buf_set_lines(state.right_buf, 0, -1, false, { "-- Empty --" })
        vim.bo[state.left_buf].modifiable = false
        vim.bo[state.right_buf].modifiable = false
        return
    end

    local left_lines, right_lines = {}, {}
    for _, row in ipairs(rows) do
        table.insert(left_lines, row.left.content)
        table.insert(right_lines, row.right.content)
    end

    vim.bo[state.left_buf].modifiable = true
    vim.bo[state.right_buf].modifiable = true
    vim.api.nvim_buf_set_lines(state.left_buf, 0, -1, false, left_lines)
    vim.api.nvim_buf_set_lines(state.right_buf, 0, -1, false, right_lines)
    vim.bo[state.left_buf].modifiable = false
    vim.bo[state.right_buf].modifiable = false

    for i, lines in ipairs(file.aligned_lines or {}) do
        if lines[1] then
            vim.api.nvim_buf_set_extmark(state.left_buf, LINE_NS, i - 1, 0, { id = lines[1] + 1 })
        end
        if lines[2] then
            vim.api.nvim_buf_set_extmark(state.right_buf, LINE_NS, i - 1, 0, { id = lines[2] + 1 })
        end
    end

    -- Apply syntax highlighting based on mode
    local use_treesitter = config.highlight_mode ~= "difftastic"
    if use_treesitter then
        local ft = FILETYPES[file.language] or vim.filetype.match({ filename = vim.fn.fnamemodify(file.path, ":t"), })
        if ft then
            ensure_treesitter(state.left_buf, ft)
            ensure_treesitter(state.right_buf, ft)
        end
    end

    local left_ns = vim.api.nvim_create_namespace("difft-left")
    local right_ns = vim.api.nvim_create_namespace("difft-right")
    vim.api.nvim_buf_clear_namespace(state.left_buf, left_ns, 0, -1)
    vim.api.nvim_buf_clear_namespace(state.right_buf, right_ns, 0, -1)

    -- Choose highlight groups based on mode
    -- treesitter mode: background colors
    -- difftastic mode: foreground colors (like CLI, bold)
    local removed_hl = use_treesitter and "DifftRemoved" or "DifftRemovedFg"
    local added_hl = use_treesitter and "DifftAdded" or "DifftAddedFg"
    local removed_line_hl = "DifftRemovedLine"
    local added_line_hl = "DifftAddedLine"

    -- Apply diff highlights (additions/removals)
    for i, row in ipairs(rows) do
        local line = i - 1

        apply_diff_highlights(state.left_buf, left_ns, line, row.left.content, row.left.highlights, removed_hl, removed_line_hl)
        apply_diff_highlights(state.right_buf, right_ns, line, row.right.content, row.right.highlights, added_hl, added_line_hl)

        if row.left.is_filler then
            vim.api.nvim_buf_set_extmark(state.left_buf, left_ns, line, 0, {
                virt_text = { { FILLER, "DifftFiller" } },
                virt_text_pos = "overlay",
            })
        end

        if row.right.is_filler then
            vim.api.nvim_buf_set_extmark(state.right_buf, right_ns, line, 0, {
                virt_text = { { FILLER, "DifftFiller" } },
                virt_text_pos = "overlay",
            })
        end
    end

    for _, win in ipairs({ state.left_win, state.right_win }) do
        if win and vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_set_cursor(win, { 1, 0 })
        end
    end
end

--- The file line shown on a pane's buffer row.
--- @param buf number Pane buffer
--- @param row number Buffer row (1-based)
--- @return number|nil line File line (1-based), nil on a filler row
function M.file_line(buf, row)
    local mark = vim.api.nvim_buf_get_extmarks(buf, LINE_NS, { row - 1, 0 }, { row - 1, -1 }, { limit = 1 })[1]
    return mark and mark[1]
end

--- The buffer row showing a file line.
--- @param buf number Pane buffer
--- @param line number File line (1-based)
--- @return number|nil row Buffer row (1-based), nil when the side has no such line
function M.buf_row(buf, line)
    local pos = vim.api.nvim_buf_get_extmark_by_id(buf, LINE_NS, line, {})
    return pos[1] and pos[1] + 1
end

--- The file line on a buffer row or, from a filler row, the nearest one (the one
--- above on a tie).
--- @param buf number Pane buffer
--- @param row number Buffer row (1-based)
--- @return number|nil line File line (1-based), nil when the side has no lines
function M.nearest_file_line(buf, row)
    local above = vim.api.nvim_buf_get_extmarks(buf, LINE_NS, { row - 1, 0 }, 0, { limit = 1 })[1]
    local below = vim.api.nvim_buf_get_extmarks(buf, LINE_NS, { row - 1, 0 }, -1, { limit = 1 })[1]
    if above and (not below or row - 1 - above[2] <= below[2] - (row - 1)) then
        return above[1]
    end
    return below and below[1]
end

--- The 'statuscolumn' of a pane: the file line number (or the relative number,
--- with 'relativenumber') on rows showing a line, blank on fillers and closed
--- folds.
--- @return string
function M.statuscolumn()
    local win = vim.g.statusline_winid
    local buf = vim.api.nvim_win_get_buf(win)
    local width = math.max(vim.wo[win].numberwidth - 1, #tostring(vim.api.nvim_buf_line_count(buf)))
    local line
    if vim.v.virtnum ~= 0 then
        line = nil
    elseif vim.b[buf].difftastic_pane then
        -- None on a closed fold: its line shows the folded lines' count.
        local folded = vim.api.nvim_win_call(win, function()
            return vim.fn.foldclosed(vim.v.lnum) ~= -1
        end)
        line = not folded and M.file_line(buf, vim.v.lnum) or nil
    else
        -- Another buffer opened in the pane: its own line numbers
        line = vim.v.lnum
    end
    local text, group = "", "LineNr"
    if line then
        if vim.wo[win].relativenumber and vim.v.relnum ~= 0 then
            text = tostring(vim.v.relnum)
        else
            text = tostring(line)
            if vim.v.relnum == 0 and vim.wo[win].cursorline then
                group = "CursorLineNr"
            end
        end
    end
    return ("%%#%s#%s%s "):format(group, string.rep(" ", width - #text), text)
end

--- Get the current diff window (left or right).
--- @param state table Plugin state
--- @return number|nil Window handle or nil if invalid
local function get_diff_win(state)
    local current = vim.api.nvim_get_current_win()
    local win = current == state.right_win and state.right_win or state.left_win
    if win and vim.api.nvim_win_is_valid(win) then
        return win
    end
    return nil
end

--- Jump to the next hunk.
--- @param state table Plugin state
--- @return boolean True if jumped to a hunk, false if at/past last hunk
function M.next_hunk(state)
    if #state.hunk_positions == 0 then
        return false
    end
    local win = get_diff_win(state)
    if not win then
        return false
    end

    local line = vim.api.nvim_win_get_cursor(win)[1]
    for _, pos in ipairs(state.hunk_positions) do
        if pos > line then
            vim.api.nvim_win_set_cursor(win, { pos, 0 })
            return true
        end
    end
    return false
end

--- Jump to the previous hunk.
--- @param state table Plugin state
--- @return boolean True if jumped to a hunk, false if at/before first hunk
function M.prev_hunk(state)
    if #state.hunk_positions == 0 then
        return false
    end
    local win = get_diff_win(state)
    if not win then
        return false
    end

    local line = vim.api.nvim_win_get_cursor(win)[1]
    for i = #state.hunk_positions, 1, -1 do
        if state.hunk_positions[i] < line then
            vim.api.nvim_win_set_cursor(win, { state.hunk_positions[i], 0 })
            return true
        end
    end
    return false
end

--- Jump to the first hunk.
--- @param state table Plugin state
function M.first_hunk(state)
    if #state.hunk_positions == 0 then
        return
    end
    local win = get_diff_win(state)
    if win then
        vim.api.nvim_win_set_cursor(win, { state.hunk_positions[1], 0 })
    end
end

--- Jump to the last hunk.
--- @param state table Plugin state
function M.last_hunk(state)
    if #state.hunk_positions == 0 then
        return
    end
    local win = get_diff_win(state)
    if win then
        vim.api.nvim_win_set_cursor(win, { state.hunk_positions[#state.hunk_positions], 0 })
    end
end

return M
