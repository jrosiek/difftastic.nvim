--- File tree sidebar using nui.nvim.
local M = {}

local NuiTree = require("nui.tree")
local NuiLine = require("nui.line")

local DEFAULT_ICON = ""
local has_devicons, devicons = pcall(require, "nvim-web-devicons")

local GLYPHS = {
    branch = "│ ",
    expanded = "",
    collapsed = "",
    file = "  ",
}

-- Each diff keeps its panel in its state: `tree` (the NuiTree), `tree_row_width`
-- (display width rows are cut to; nil leaves them whole), `tree_header_width`,
-- `header_lines` (height of the header box, which grows with the diff's title)
-- and the totals `total_additions` / `total_deletions`.

--- @return table Tree configuration
local function get_config()
    return require("difftastic-nvim").config.tree
end

--- Get file icon from nvim-web-devicons if available.
--- @param filename string
--- @return string icon
--- @return string|nil highlight_group
local function get_file_icon(filename)
    local cfg = get_config()
    if cfg.icons.enable and has_devicons then
        local icon, hl = devicons.get_icon(filename, nil, { default = true })
        return icon or DEFAULT_ICON, hl
    end
    return DEFAULT_ICON, nil
end

local function status_icon(node)
    local glyph, hl_group = require("difftastic-nvim.diff").file_status(node)
    return glyph, hl_group
end

local function append_stat_chip(line, additions, deletions)
    if additions == 0 and deletions == 0 then
        return
    end

    line:append("  ", "DifftTreeMuted")
    if additions > 0 then
        line:append("+" .. additions, "DifftFileAdded")
    end
    if additions > 0 and deletions > 0 then
        line:append(" ", "DifftTreeMuted")
    end
    if deletions > 0 then
        line:append("-" .. deletions, "DifftFileDeleted")
    end
end

local function display_width(text)
    return vim.fn.strdisplaywidth(text)
end

local function pad_to_width(text, width)
    return text .. string.rep(" ", math.max(0, width - display_width(text)))
end

local function trim_to_width(text, width)
    if width <= 0 then
        return ""
    end

    if display_width(text) <= width then
        return text
    end

    local ellipsis = "…"
    local limit = math.max(0, width - display_width(ellipsis))
    local result = vim.fn.strcharpart(text, 0, limit)

    while display_width(result .. ellipsis) > width do
        result = vim.fn.strcharpart(result, 0, math.max(0, vim.fn.strchars(result) - 1))
    end

    return result .. ellipsis
end

local function fit_header_row(left, right, width)
    local gap = width - display_width(left) - display_width(right)
    if gap < 1 then
        local right_width = math.max(0, width - display_width(left) - 1)
        if right_width > 0 then
            return fit_header_row(left, trim_to_width(right, right_width), width)
        end
        return pad_to_width(trim_to_width(left, width), width)
    end

    return left .. string.rep(" ", gap) .. right
end

--- Wrap text to lines of at most `width` display cells. Breaks at spaces and at
--- explicit newlines; a word longer than the width is split.
--- @param text string
--- @param width number
--- @return string[]
local function wrap_to_width(text, width)
    local result = {}
    if width <= 0 then
        return result
    end
    for _, paragraph in ipairs(vim.split(text, "\n", { plain = true })) do
        local line = ""
        for word in paragraph:gmatch("%S+") do
            while display_width(word) > width do
                if line ~= "" then
                    table.insert(result, line)
                    line = ""
                end
                local take = vim.fn.strchars(word)
                while take > 1 and display_width(vim.fn.strcharpart(word, 0, take)) > width do
                    take = take - 1
                end
                table.insert(result, vim.fn.strcharpart(word, 0, take))
                word = vim.fn.strcharpart(word, take)
            end
            if word ~= "" then
                if line == "" then
                    line = word
                elseif display_width(line) + 1 + display_width(word) <= width then
                    line = line .. " " .. word
                else
                    table.insert(result, line)
                    line = word
                end
            end
        end
        if line ~= "" then
            table.insert(result, line)
        end
    end
    return result
end

--- Build an intermediate tree structure from flat file list.
--- @param files table[] List of file objects with path, status, additions, deletions
--- @return table Root node of the tree
local function build_intermediate_tree(files)
    local root = {
        name = "",
        path = "",
        is_dir = true,
        children = {},
        children_map = {},
        file_idx = nil,
        status = nil,
        additions = 0,
        deletions = 0,
    }

    for idx, file in ipairs(files) do
        local parts = {}
        for part in string.gmatch(file.path, "[^/]+") do
            table.insert(parts, part)
        end

        local node = root
        local current_path = ""
        for i, part in ipairs(parts) do
            local is_last = (i == #parts)
            current_path = current_path == "" and part or (current_path .. "/" .. part)

            if not node.children_map[part] then
                local child = {
                    name = part,
                    path = current_path,
                    is_dir = not is_last,
                    children = {},
                    children_map = {},
                    file_idx = nil,
                    status = nil,
                    additions = 0,
                    deletions = 0,
                }
                node.children_map[part] = child
                table.insert(node.children, child)
            end

            node = node.children_map[part]

            if is_last then
                node.file_idx = idx
                node.status = file.status
                node.additions = file.additions or 0
                node.deletions = file.deletions or 0
                node.moved_from = file.moved_from
            end
        end
    end

    return root
end

local function propagate_stats(node)
    if not node.is_dir then
        return node.additions, node.deletions
    end

    local total_add, total_del = 0, 0
    for _, child in ipairs(node.children) do
        local add, del = propagate_stats(child)
        total_add = total_add + add
        total_del = total_del + del
    end

    node.additions = total_add
    node.deletions = total_del
    return total_add, total_del
end

local function flatten_node(node)
    for _, child in ipairs(node.children) do
        flatten_node(child)
    end

    while #node.children == 1 and node.children[1].is_dir do
        local child = node.children[1]
        node.name = node.name == "" and child.name or (node.name .. "/" .. child.name)
        node.path = child.path
        node.children = child.children
        node.children_map = child.children_map
    end
end

local function sort_node(node)
    table.sort(node.children, function(a, b)
        if a.is_dir ~= b.is_dir then return a.is_dir end
        return a.name:lower() < b.name:lower()
    end)

    for _, child in ipairs(node.children) do
        if child.is_dir then sort_node(child) end
    end
end

local function convert_to_nui_nodes(node)
    local nui_children = {}

    for _, child in ipairs(node.children) do
        local grandchildren = nil
        if child.is_dir then
            grandchildren = convert_to_nui_nodes(child)
        end

        local nui_node = NuiTree.Node({
            id = child.path,
            name = child.name,
            path = child.path,
            is_dir = child.is_dir,
            file_idx = child.file_idx,
            status = child.status,
            additions = child.additions,
            deletions = child.deletions,
            moved_from = child.moved_from,
        }, grandchildren)

        if child.is_dir then
            nui_node:expand()
        end

        table.insert(nui_children, nui_node)
    end

    return nui_children
end

--- Cut a tree row to `width` display columns, ending it with "…" when it does not
--- fit. Highlights of the kept segments are preserved.
--- @param line table NuiLine
--- @param width number|nil
--- @return table NuiLine
local function fit_row(line, width)
    if not width or line:width() <= width then
        return line
    end
    if width <= 0 then
        return NuiLine()
    end
    local fitted = NuiLine()
    local used = 0
    for _, text in ipairs(line._texts) do
        if used + text:width() < width then
            fitted:append(text:content(), text.extmark)
            used = used + text:width()
        else
            local room = width - used
            local cut = vim.fn.strcharpart(text:content(), 0, room)
            while cut ~= "" and display_width(cut .. "…") > room do
                cut = vim.fn.strcharpart(cut, 0, vim.fn.strchars(cut) - 1)
            end
            fitted:append(cut .. "…", text.extmark)
            break
        end
    end
    return fitted
end

--- Review marker of a row: reviewed, not shown yet in this view, or none (blank).
--- @return string glyph, string highlight
local function review_marker(node, cfg, state)
    if node.is_dir then
        -- A directory is reviewed once every file in it is.
        local paths = M.file_paths(node, state)
        for _, path in ipairs(paths) do
            if not (state.reviewed and state.reviewed[path]) then
                return " ", "DifftTreeMuted"
            end
        end
        if #paths > 0 then
            return cfg.icons.reviewed, "DifftTreeReviewed"
        end
        return " ", "DifftTreeMuted"
    end
    local file = node.file_idx and state.files[node.file_idx]
    if not file then
        return " ", "DifftTreeMuted"
    end
    if state.reviewed and state.reviewed[file.path] then
        return cfg.icons.reviewed, "DifftTreeReviewed"
    end
    if state.visited and not state.visited[file.path] then
        return cfg.icons.unvisited, "DifftTreeUnvisited"
    end
    return " ", "DifftTreeMuted"
end

local function prepare_node(node, state)
    local cfg = get_config()
    local line = NuiLine()
    local depth = node:get_depth()

    for _ = 1, depth - 1 do
        line:append(GLYPHS.branch, "DifftTreeIndent")
    end

    if node.is_dir then
        line:append(node:is_expanded() and GLYPHS.expanded or GLYPHS.collapsed, "DifftTreeChevron")
        line:append(" ", "DifftTreeMuted")
    else
        line:append(GLYPHS.file, "DifftTreeMuted")
    end

    local marker, marker_hl = status_icon(node)
    line:append(marker .. " ", marker_hl)

    local icon, icon_hl
    if node.is_dir then
        icon = node:is_expanded() and cfg.icons.dir_open or cfg.icons.dir_closed
        icon_hl = "DifftDirectory"
    else
        icon, icon_hl = get_file_icon(node.name)
    end
    line:append(icon .. " ", icon_hl)

    if node.moved_from then
        line:append(node.moved_from, "DifftTreePathMuted")
        line:append(" → ", "DifftTreeMuted")
        line:append(node.name, "DifftFileAdded")
    elseif node.is_dir then
        line:append(node.name, "DifftTreeDirectory")
    else
        line:append(node.name, "DifftTreeFile")
    end

    append_stat_chip(line, node.additions, node.deletions)

    -- The review marker takes a column of its own at the right edge: the row is
    -- cut and padded to end just before it, so the text never overlaps it.
    local marker, marker_hl = review_marker(node, cfg, state)
    local column = math.max(display_width(cfg.icons.unvisited), display_width(cfg.icons.reviewed))
    if state.tree_row_width then
        line = fit_row(line, state.tree_row_width - column - 1)
        local pad = state.tree_row_width - column - 1 - line:width()
        if pad > 0 then
            line:append(string.rep(" ", pad), "DifftTreeMuted")
        end
    end
    line:append(" ", "DifftTreeMuted")
    line:append(marker .. string.rep(" ", column - display_width(marker)), marker_hl)
    return line
end

--- Width available for text in a window: its width minus the columns drawn left
--- of the text (number, sign, fold and status columns).
--- @param win number
--- @return number
function M.text_width(win)
    return vim.api.nvim_win_get_width(win) - vim.fn.getwininfo(win)[1].textoff
end

--- Turn off every column drawn left of the text. These are the only window
--- options that take width from the text; 'statuscolumn' takes space whenever
--- it is set, even with the other columns off.
--- @param win number
function M.hide_text_columns(win)
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"
    vim.wo[win].foldcolumn = "0"
    vim.wo[win].statuscolumn = ""
end

--- Create the nui tree from `state.tree_root` and render it right below the header.
--- @param state table Plugin state
--- @param collapsed table<string, boolean> Directory node ids to render collapsed
local function build_nui_tree(state, collapsed)
    state.tree = NuiTree({
        bufnr = state.tree_buf,
        nodes = convert_to_nui_nodes(state.tree_root),
        prepare_node = function(node)
            return prepare_node(node, state)
        end,
    })
    state.tree:render(state.header_lines + 1)
    -- Collapsed after the first render: nui maps rows to nodes wrongly when nodes
    -- are collapsed before it.
    if next(collapsed) then
        for id in pairs(collapsed) do
            local node = state.tree:get_node(id)
            if node then
                node:collapse()
            end
        end
        state.tree:render()
    end
end

--- Render the header with totals, sized to the tree window.
---
--- With a title (`state.title`, then `state.subtitle`) the box has two parts:
--- the wrapped title and subtitle on top, then a divider, then the file count
--- and range rows.
--- @param state table Plugin state
--- @param total_add number Total additions
--- @param total_del number Total deletions
--- @param replace_lines number|nil Existing header lines to replace (nil inserts)
local function render_header(state, total_add, total_del, replace_lines)
    local width = get_config().width
    if state.tree_win and vim.api.nvim_win_is_valid(state.tree_win) then
        width = M.text_width(state.tree_win)
    end

    local ns = vim.api.nvim_create_namespace("difft-tree-header")
    vim.api.nvim_buf_clear_namespace(state.tree_buf, ns, 0, state.header_lines or 0)

    local file_count = #(state.files or {})
    local file_label = file_count == 1 and "1 file" or (file_count .. " files")
    local reviewed_count = 0
    for _, file in ipairs(state.files or {}) do
        if state.reviewed and state.reviewed[file.path] then
            reviewed_count = reviewed_count + 1
        end
    end
    if reviewed_count > 0 then
        file_label = ("%d/%d reviewed"):format(reviewed_count, file_count)
    end

    local add_text = "+" .. total_add
    local del_text = "-" .. total_del
    local stat_text = add_text .. "  " .. del_text
    local inner_width = math.max(0, width - 4)
    local stats_inner = fit_header_row(file_label, stat_text, inner_width)
    local range_kind = state.range_kind or "Range"
    local range_text = state.range_label or ""
    local range_value_width = math.max(0, inner_width - display_width(range_kind) - 1)
    local range_display = range_value_width > 0 and trim_to_width(range_text, range_value_width) or ""
    local range_inner = fit_header_row(range_kind, range_display, inner_width)

    local rule = string.rep("─", math.max(0, width - 2))
    local top_line = "╭" .. rule .. "╮"
    local stats_line = "│ " .. stats_inner .. " │"
    local range_line = "│ " .. range_inner .. " │"

    local lines = { top_line }
    local title_rows = {}
    local function add_title_rows(text, hl_group)
        for _, row_text in ipairs(wrap_to_width(text or "", inner_width)) do
            table.insert(lines, "│ " .. pad_to_width(row_text, inner_width) .. " │")
            title_rows[#lines - 1] = { row_text, hl_group }
        end
    end
    add_title_rows(state.title, "DifftDiffTitle")
    if next(title_rows) then
        add_title_rows(state.subtitle, "DifftDiffSubtitle")
    end
    if next(title_rows) then
        table.insert(lines, "├" .. rule .. "┤")
    end
    table.insert(lines, stats_line)
    local stats_row = #lines - 1
    table.insert(lines, range_line)
    local range_row = #lines - 1
    table.insert(lines, "╰" .. rule .. "╯")

    vim.api.nvim_buf_set_lines(state.tree_buf, 0, replace_lines or 0, false, lines)
    state.header_lines = #lines
    state.tree_header_width = width

    -- Frame: rows with side borders get those muted; the top and bottom rules and
    -- the title divider are frame only.
    local left_border_end = #"│"
    local content_start = #"│ "
    for row = 0, #lines - 1 do
        local line = lines[row + 1]
        if vim.startswith(line, "│") then
            vim.api.nvim_buf_add_highlight(state.tree_buf, ns, "DifftTreeDivider", row, 0, left_border_end)
            vim.api.nvim_buf_add_highlight(state.tree_buf, ns, "DifftTreeDivider", row, #line - #"│", -1)
        else
            vim.api.nvim_buf_add_highlight(state.tree_buf, ns, "DifftTreeDivider", row, 0, -1)
        end
    end

    for row, title in pairs(title_rows) do
        vim.api.nvim_buf_add_highlight(state.tree_buf, ns, title[2], row, content_start, content_start + #title[1])
    end

    local file_label_col = stats_line:find(file_label, 1, true)
    if file_label_col then
        vim.api.nvim_buf_add_highlight(state.tree_buf, ns, "DifftTreeMuted", stats_row, file_label_col - 1, file_label_col + #file_label - 1)
    end
    local add_col = stats_line:find(add_text, 1, true)
    if add_col then
        vim.api.nvim_buf_add_highlight(state.tree_buf, ns, "DifftFileAdded", stats_row, add_col - 1, add_col + #add_text - 1)
    end
    local del_col = stats_line:find(del_text, add_col and (add_col + #add_text) or 1, true)
    if del_col then
        vim.api.nvim_buf_add_highlight(state.tree_buf, ns, "DifftFileDeleted", stats_row, del_col - 1, del_col + #del_text - 1)
    end
    local range_kind_col = range_line:find(range_kind, 1, true)
    if range_kind_col then
        vim.api.nvim_buf_add_highlight(state.tree_buf, ns, "DifftTreeMuted", range_row, range_kind_col - 1, range_kind_col + #range_kind - 1)
    end
    local range_value_col = range_display ~= "" and range_line:find(range_display, 1, true) or nil
    if range_value_col then
        vim.api.nvim_buf_add_highlight(state.tree_buf, ns, "DifftTreeRange", range_row, range_value_col - 1, #range_line - #" │")
    end
end

--- Show the side panel in the current window, at the configured width.
--- @param state table Plugin state
function M.open(state)
    state.tree_win = vim.api.nvim_get_current_win()
    state.tree_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(state.tree_win, state.tree_buf)
    vim.api.nvim_win_set_width(state.tree_win, get_config().width)

    M.hide_text_columns(state.tree_win)
    vim.wo[state.tree_win].winfixwidth = true
    vim.wo[state.tree_win].cursorline = true
    vim.wo[state.tree_win].scrollbind = false
    vim.wo[state.tree_win].cursorbind = false
    vim.wo[state.tree_win].list = false
    -- A long row is cut off at the panel edge rather than wrapped onto a second line.
    vim.wo[state.tree_win].wrap = false
    vim.wo[state.tree_win].winhl = table.concat({
        "Normal:DifftTreeNormal",
        "NormalNC:DifftTreeNormal",
        "EndOfBuffer:DifftTreeEndOfBuffer",
        "CursorLine:DifftTreeCursorLine",
        "WinBar:DifftBar",
        "WinBarNC:DifftBarNC",
    }, ",")

    vim.bo[state.tree_buf].buftype = "nofile"
    vim.bo[state.tree_buf].bufhidden = "wipe"
    vim.bo[state.tree_buf].swapfile = false
    vim.bo[state.tree_buf].filetype = "difft-tree"
    vim.bo[state.tree_buf].modifiable = true

    -- Build intermediate tree structure
    local root = build_intermediate_tree(state.files)
    propagate_stats(root)
    flatten_node(root)
    sort_node(root)

    -- Store totals for header
    state.total_additions = root.additions
    state.total_deletions = root.deletions
    state.tree_root = root

    -- Render header first, then the tree below it
    render_header(state, root.additions, root.deletions)
    state.tree_row_width = M.text_width(state.tree_win)
    build_nui_tree(state, {})

    -- Redraw the header box and the rows when the tree window changes width.
    require("difftastic-nvim").diff_autocmd(state, "DifftTreeResize", "WinResized", {
        callback = function()
            if not (state.tree_win and vim.api.nvim_win_is_valid(state.tree_win)) then
                return true -- diff view closed: drop this autocmd
            end
            if M.text_width(state.tree_win) ~= state.tree_header_width then
                M.refresh_header(state)
                M.refresh_rows(state)
            end
        end,
    })

    -- Keymaps
    local difft = require("difftastic-nvim")
    local keys = difft.config.keymaps

    local function select()
        local node = state.tree:get_node()
        if not node then return end

        if node.file_idx then
            difft.show_file(node.file_idx)
            if difft.config.focus_diff_on_select then
                difft.focus_diff()
            end
        elseif node.is_dir then
            if node:is_expanded() then
                node:collapse()
            else
                node:expand()
            end
            state.tree:render()
        end
    end
    vim.keymap.set("n", keys.select, select, { buffer = state.tree_buf })
    -- The first click of a double click has already put the cursor on the row. A
    -- double click on a split of the view acts on it (see split_double_click); one
    -- elsewhere keeps its default.
    vim.keymap.set("n", "<2-LeftMouse>", function()
        if difft.split_double_click() then
            return ""
        end
        local mouse = vim.fn.getmousepos()
        if mouse.winid ~= state.tree_win or mouse.line == 0 then
            return "<2-LeftMouse>"
        end
        vim.schedule(select)
        return ""
    end, { buffer = state.tree_buf, expr = true })

    vim.keymap.set("n", keys.close, difft.close, { buffer = state.tree_buf })
end

function M.render(state)
    if state.tree then
        state.tree:render()
    end
end

--- Redraw the header in place at the tree window's current width.
--- @param state table Plugin state
function M.refresh_header(state)
    if not (state.tree_buf and vim.api.nvim_buf_is_valid(state.tree_buf)) then
        return
    end
    -- nui leaves the tree buffer non-modifiable and read-only after rendering.
    local buf = vim.bo[state.tree_buf]
    local modifiable, readonly = buf.modifiable, buf.readonly
    buf.modifiable, buf.readonly = true, false
    -- A wrapped title can change the header height. nui keeps the tree's line range
    -- internally, so the tree is then rebuilt below the new header, keeping
    -- collapsed directories and the node under the cursor.
    local old_height = state.header_lines
    local cursor_node = state.tree and vim.api.nvim_win_is_valid(state.tree_win)
        and state.tree:get_node(vim.api.nvim_win_get_cursor(state.tree_win)[1])
    render_header(state, state.total_additions or 0, state.total_deletions or 0, old_height)
    if state.tree and state.header_lines ~= old_height then
        local collapsed = {}
        for id, node in pairs(state.tree.nodes.by_id) do
            if node:has_children() and not node:is_expanded() then
                collapsed[id] = true
            end
        end
        vim.api.nvim_buf_set_lines(state.tree_buf, state.header_lines, -1, false, {})
        build_nui_tree(state, collapsed)
        M.highlight_current(state)
        local _, linenr = state.tree:get_node(cursor_node and cursor_node:get_id() or "")
        if linenr then
            vim.api.nvim_win_set_cursor(state.tree_win, { linenr, 0 })
        end
    end
    buf.modifiable, buf.readonly = modifiable, readonly
end

--- Paths of the files a node stands for: itself, or every file below a directory.
--- @param node table NuiTree node
--- @param state table Plugin state
--- @return string[]
function M.file_paths(node, state)
    local paths = {}
    local function walk(n)
        if n.file_idx then
            local file = state.files[n.file_idx]
            if file then
                table.insert(paths, file.path)
            end
        end
        for _, id in ipairs(n:get_child_ids() or {}) do
            local child = state.tree:get_node(id)
            if child then
                walk(child)
            end
        end
    end
    walk(node)
    return paths
end

--- Redraw the tree rows at the tree window's current width, keeping the cursor
--- and the current-file highlight.
--- @param state table Plugin state
function M.refresh_rows(state)
    if not (state.tree and state.tree_win and vim.api.nvim_win_is_valid(state.tree_win)) then
        return
    end
    state.tree_row_width = M.text_width(state.tree_win)
    local cursor = vim.api.nvim_win_get_cursor(state.tree_win)
    state.tree:render()
    M.highlight_current(state)
    vim.api.nvim_win_set_cursor(state.tree_win, cursor)
end

--- File indices of every file in tree order, inside collapsed directories too.
--- @param state table Diff state
--- @return number[]
function M.all_files_in_order(state)
    local files = {}
    if not state.tree then
        return files
    end
    local function walk(parent_id)
        for _, node in ipairs(state.tree:get_nodes(parent_id)) do
            if node.file_idx then
                table.insert(files, node.file_idx)
            end
            if node:has_children() then
                walk(node:get_id())
            end
        end
    end
    walk(nil)
    return files
end

--- Expand the directories around a file, so its row is visible.
--- @param state table Diff state
--- @param file_idx number
function M.reveal_file(state, file_idx)
    if not state.tree then
        return
    end
    local changed = false
    local function walk(parent_id)
        for _, node in ipairs(state.tree:get_nodes(parent_id)) do
            if node.file_idx == file_idx then
                return true
            end
            if node:has_children() and walk(node:get_id()) then
                if not node:is_expanded() then
                    node:expand()
                    changed = true
                end
                return true
            end
        end
        return false
    end
    walk(nil)
    if changed then
        state.tree:render()
    end
end

local function collect_visible_files(tree)
    local files = {}

    local function walk(node_id)
        local nodes = tree:get_nodes(node_id)
        for _, node in ipairs(nodes) do
            if node.file_idx then
                table.insert(files, node.file_idx)
            end
            if node:has_children() and node:is_expanded() then
                walk(node:get_id())
            end
        end
    end

    walk()
    return files
end

function M.next_file_in_display_order(state, current_idx)
    if not state.tree then return nil end
    local files = collect_visible_files(state.tree)
    for i, idx in ipairs(files) do
        if idx == current_idx and files[i + 1] then
            return files[i + 1]
        end
    end
    return nil
end

function M.prev_file_in_display_order(state, current_idx)
    if not state.tree then return nil end
    local files = collect_visible_files(state.tree)
    for i, idx in ipairs(files) do
        if idx == current_idx and i > 1 then
            return files[i - 1]
        end
    end
    return nil
end

function M.first_file_in_display_order(state)
    if not state.tree then return nil end
    local files = collect_visible_files(state.tree)
    return files[1]
end

function M.last_file_in_display_order(state)
    if not state.tree then return nil end
    local files = collect_visible_files(state.tree)
    return files[#files]
end

function M.highlight_current(state)
    if not state.tree or not state.tree_buf then return end

    local ns = vim.api.nvim_create_namespace("difft-tree-current")
    vim.api.nvim_buf_clear_namespace(state.tree_buf, ns, state.header_lines, -1)

    -- Find the line number by iterating through rendered lines (after header)
    local line_count = vim.api.nvim_buf_line_count(state.tree_buf)
    for linenr = state.header_lines + 1, line_count do
        local node = state.tree:get_node(linenr)
        if node and node.file_idx == state.current_file_idx then
            vim.api.nvim_buf_add_highlight(state.tree_buf, ns, "DifftTreeCurrent", linenr - 1, 0, -1)
            if vim.api.nvim_win_is_valid(state.tree_win) then
                vim.api.nvim_win_set_cursor(state.tree_win, { linenr, 0 })
            end
            break
        end
    end
end

return M
