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
--- @param closed boolean
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
        for _, range in ipairs(ranges) do
            vim.cmd(("%d,%dfold"):format(range[1], range[2]))
            if not closed then
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
end

return M
