--- Folds over the unchanged lines of the diff panes.
local M = {}

--- Whether a row is part of a change: highlighted or filler on either side.
--- @param row table
--- @return boolean
local function is_changed(row)
    return #row.left.highlights > 0 or #row.right.highlights > 0 or row.left.is_filler or row.right.is_filler
end

--- Line ranges to fold: each run of unchanged lines, less `context` lines next to
--- a change, when at least `min_size` lines remain. A file without changes is
--- one run.
--- @param rows table[] Display rows of a file
--- @param hunk_starts number[]|nil 0-based rows where hunks start; always changed
--- @param context number Unchanged lines kept around each change (> 0)
--- @param min_size number Smallest number of lines worth a fold (>= 1)
--- @return table[] ranges `{ first, last }`, 1-based and inclusive, in order
function M.ranges(rows, hunk_starts, context, min_size)
    local changed = {}
    for i, row in ipairs(rows) do
        changed[i] = is_changed(row)
    end
    for _, start in ipairs(hunk_starts or {}) do
        if rows[start + 1] then
            changed[start + 1] = true
        end
    end

    local ranges = {}
    local i, count = 1, #rows
    while i <= count do
        if changed[i] then
            i = i + 1
        else
            local first = i
            while i <= count and not changed[i] do
                i = i + 1
            end
            local last = i - 1
            -- Keep context next to the change before the run and the one after it.
            if first > 1 then
                first = first + context
            end
            if last < count then
                last = last - context
            end
            if last - first + 1 >= min_size then
                table.insert(ranges, { first, last })
            end
        end
    end
    return ranges
end

--- Fold text of a closed fold.
--- @return table[] Chunks of text and highlight group
--- A rule of the window's fold fill character with the count centred in it:
--- "━━━━ ▸ 42 unchanged lines ━━━━…".
--- @return table[] Chunks of text and highlight group
function M.text()
    local count = vim.v.foldend - vim.v.foldstart + 1
    local fill = vim.opt_local.fillchars:get().fold or "="
    local label = (" ▸ %d unchanged line%s "):format(count, count == 1 and "" or "s")
    -- Centred in the text area; Neovim fills the rest of the line with the fill
    -- character.
    local info = vim.fn.getwininfo(vim.api.nvim_get_current_win())[1]
    local width = info.width - info.textoff
    local left = math.max(2, math.floor((width - vim.fn.strdisplaywidth(label)) / 2))
    return { { fill:rep(left) .. label, "DifftFold" } }
end

local FOLD_OPTIONS = { "foldmethod", "foldenable", "foldminlines", "foldtext", "foldlevel", "fillchars", "winhighlight" }

--- Set the fold fill character of a window, keeping its other fill characters.
--- Falls back to "=" when Neovim rejects the character (it must take one cell:
--- box drawing characters take two with 'ambiwidth' set to "double").
--- @param win number
--- @param fill string
local function set_fill(win, fill)
    vim.api.nvim_win_call(win, function()
        if not pcall(function()
            vim.opt_local.fillchars:append({ fold = fill })
        end) then
            vim.opt_local.fillchars:append({ fold = "=" })
        end
    end)
end

--- Replace the folds of a diff pane with the given ranges, closed or open. The
--- window's own fold options are saved the first time, so they can be restored.
--- @param state table Plugin state
--- @param win number
--- @param ranges table[]
--- @param closed boolean|boolean[] One state for all folds, or one per range
local function apply(state, win, ranges, closed)
    state.saved_fold_options = state.saved_fold_options or {}
    if not state.saved_fold_options[win] then
        local saved = {}
        for _, name in ipairs(FOLD_OPTIONS) do
            saved[name] = vim.wo[win][name]
        end
        state.saved_fold_options[win] = saved
    end

    vim.wo[win].foldmethod = "manual"
    vim.wo[win].foldenable = true
    vim.wo[win].foldminlines = 0
    vim.wo[win].foldlevel = 0
    vim.wo[win].foldtext = "v:lua.require'difftastic-nvim.fold'.text()"
    set_fill(win, require("difftastic-nvim").config.fold_fill)
    -- Closed folds use DifftFold in the panes, fill included, not the theme's Folded.
    local own = state.saved_fold_options[win].winhighlight
    vim.wo[win].winhighlight = (own ~= "" and own .. "," or "") .. "Folded:DifftFold"
    vim.api.nvim_win_call(win, function()
        vim.cmd("normal! zE")
        for i, range in ipairs(ranges) do
            vim.cmd(("%d,%dfold"):format(range[1], range[2]))
            local fold_closed = closed
            if type(closed) == "table" then
                fold_closed = closed[i]
            end
            if not fold_closed then
                vim.cmd(("%d,%dfoldopen"):format(range[1], range[2]))
            end
        end
    end)
end

--- Undo `apply`: drop the folds and give the window its own fold options back.
--- @param state table Plugin state
--- @param win number
local function restore(state, win)
    local saved = state.saved_fold_options and state.saved_fold_options[win]
    if not saved then
        return
    end
    vim.api.nvim_win_call(win, function()
        vim.cmd("normal! zE")
    end)
    for name, value in pairs(saved) do
        vim.wo[win][name] = value
    end
    state.saved_fold_options[win] = nil
end

--- Closed state of each fold range in a window.
--- @param win number
--- @param ranges table[]
--- @return boolean[]
local function snapshot(win, ranges)
    return vim.api.nvim_win_call(win, function()
        local closed = {}
        for i, range in ipairs(ranges) do
            closed[i] = vim.fn.foldclosed(range[1]) ~= -1
        end
        return closed
    end)
end

--- Open or close the folds `indices` of a window to match `closed`.
local function set_closed(win, ranges, indices, closed)
    if #indices == 0 then
        return
    end
    vim.api.nvim_win_call(win, function()
        for _, i in ipairs(indices) do
            local range = ranges[i]
            -- A fold the user deleted (zE, zd) is skipped rather than raising E490.
            pcall(vim.cmd, ("%d,%dfold%s"):format(range[1], range[2], closed[i] and "close" or "open"))
        end
    end)
end

--- Rebuild the folds of a pane whose folds no longer match the ranges, keeping
--- its view; the folds take the given open or closed states.
local function repair(state, win, ranges, closed)
    local view = vim.api.nvim_win_call(win, vim.fn.winsaveview)
    apply(state, win, ranges, closed)
    vim.api.nvim_win_call(win, function()
        vim.fn.winrestview(view)
    end)
end

--- Inspect a window's folds against the ranges. A range is intact when its lines
--- have fold depth 1 and the lines just outside it depth 0; the window is intact
--- when every range is and no other line is folded. Anything else means folds
--- were deleted, added or changed (zE, zd, zf, :fold, the API).
--- @param win number
--- @param ranges table[]
--- @return boolean window_intact
--- @return table[] per range `{ intact = boolean, closed = boolean }`
local function inspect(win, ranges)
    -- nvim_win_call passes back a single value.
    local result = vim.api.nvim_win_call(win, function()
        local level = vim.fn.foldlevel
        local count = vim.api.nvim_buf_line_count(0)
        local window_intact, info, line = true, {}, 1
        for i, range in ipairs(ranges) do
            for l = line, range[1] - 1 do
                if level(l) ~= 0 then
                    window_intact = false
                end
            end
            local ok = (range[1] == 1 or level(range[1] - 1) == 0) and (range[2] == count or level(range[2] + 1) == 0)
            for l = range[1], range[2] do
                if not ok then
                    break
                end
                ok = level(l) == 1
            end
            info[i] = { intact = ok, closed = ok and vim.fn.foldclosed(range[1]) ~= -1 }
            window_intact = window_intact and ok
            line = range[2] + 1
        end
        for l = line, count do
            if level(l) ~= 0 then
                window_intact = false
            end
        end
        return { window_intact, info }
    end)
    return result[1], result[2]
end

--- Give both panes the same, intact folds.
---
--- Each fold gets one state: the state of the pane where it changed since the
--- last sync, the current pane breaking ties (several keys can be handled before
--- a sync, as with a mapping like `zo<C-w>l`). A fold missing or broken in one
--- pane takes its state from the other pane, and one broken in both its last
--- synced state. A pane whose folds were deleted, added or changed is rebuilt
--- with those states, which also removes folds that were added.
--- @param state table Plugin state
function M.sync(state)
    local ranges = state.fold_ranges
    local left, right = state.left_win, state.right_win
    local last = state.fold_closed
    if not (ranges and #ranges > 0 and last) then
        return
    end
    if not (left and right and vim.api.nvim_win_is_valid(left) and vim.api.nvim_win_is_valid(right)) then
        return
    end
    local left_ok, l = inspect(left, ranges)
    local right_ok, r = inspect(right, ranges)
    local current = vim.api.nvim_get_current_win()

    local wanted, changed_left, changed_right = {}, {}, {}
    for i = 1, #ranges do
        local a, b = l[i], r[i]
        if a.intact and b.intact then
            if a.closed == b.closed then
                wanted[i] = a.closed
            elseif a.closed ~= last[i] and b.closed == last[i] then
                wanted[i] = a.closed
            elseif b.closed ~= last[i] and a.closed == last[i] then
                wanted[i] = b.closed
            elseif current == right then
                wanted[i] = b.closed
            else
                wanted[i] = a.closed
            end
        elseif a.intact then
            wanted[i] = a.closed
        elseif b.intact then
            wanted[i] = b.closed
        else
            wanted[i] = last[i]
        end
        if not a.intact or a.closed ~= wanted[i] then
            table.insert(changed_left, i)
        end
        if not b.intact or b.closed ~= wanted[i] then
            table.insert(changed_right, i)
        end
    end

    if left_ok then
        set_closed(left, ranges, changed_left, wanted)
    else
        repair(state, left, ranges, wanted)
    end
    if right_ok then
        set_closed(right, ranges, changed_right, wanted)
    else
        repair(state, right, ranges, wanted)
    end
    state.fold_closed = wanted

    local left_touched = not left_ok or #changed_left > 0
    local right_touched = not right_ok or #changed_right > 0
    if left_touched or right_touched then
        -- 'scrollbind' does not follow a fold change made in the other window, so
        -- line the changed pane's view up with the other one (the current pane
        -- leads when both changed).
        local source
        if left_touched and right_touched then
            source = current == right and right or left
        else
            source = left_touched and right or left
        end
        local target = source == left and right or left
        local view = vim.api.nvim_win_call(source, vim.fn.winsaveview)
        vim.api.nvim_win_call(target, function()
            vim.fn.winrestview({ topline = view.topline, lnum = view.lnum })
        end)
    end
end

--- Fold the unchanged lines of the rendered file in both panes, following the
--- context_size, min_fold_size and fold_by_default settings. With context_size 0
--- the panes are left without plugin folds.
--- @param state table Plugin state
--- @param file table File data with rows and hunk_starts
function M.render(state, file)
    local config = require("difftastic-nvim").config
    local wins = {}
    for _, win in ipairs({ state.left_win, state.right_win }) do
        if win and vim.api.nvim_win_is_valid(win) then
            table.insert(wins, win)
        end
    end

    state.fold_ranges = {}
    state.fold_closed = nil
    if config.context_size == 0 or not file.rows or #file.rows == 0 then
        for _, win in ipairs(wins) do
            restore(state, win)
        end
        return
    end

    local ranges = M.ranges(file.rows, file.hunk_starts, config.context_size, config.min_fold_size)
    state.fold_ranges = ranges
    for _, win in ipairs(wins) do
        apply(state, win, ranges, config.fold_by_default)
    end
    if wins[1] then
        state.fold_closed = snapshot(wins[1], ranges)
    end
end

return M
