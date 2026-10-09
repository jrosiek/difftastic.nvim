--- Difftastic side-by-side diff viewer for Neovim.
local M = {}

local binary = require("difftastic-nvim.binary")
local diff = require("difftastic-nvim.diff")
local tree = require("difftastic-nvim.tree")
local highlight = require("difftastic-nvim.highlight")
local keymaps = require("difftastic-nvim.keymaps")
local fold = require("difftastic-nvim.fold")

local record_position -- defined with the per-file positions below

--- Default configuration
M.config = {
    download = false,
    vcs = "jj",
    --- Highlight mode: "treesitter" (full syntax) or "difftastic" (no syntax, colored changes only)
    highlight_mode = "treesitter",
    --- When true, next_hunk at last hunk wraps to next file (and prev_hunk to prev file)
    hunk_wrap_file = true,
    --- When true, scroll to first hunk after opening a file
    scroll_to_first_hunk = true,
    --- When true, selecting a file in the tree also moves focus to its diff pane
    focus_diff_on_select = true,
    --- Unchanged lines kept unfolded around each change; 0 turns folding off
    context_size = 3,
    --- Smallest run of unchanged lines that gets folded
    min_fold_size = 2,
    --- When true, folds start closed
    fold_by_default = true,
    --- Character filling a closed fold's line (one screen cell)
    fold_fill = "━",
    --- Highlight group whose foreground colours closed folds
    fold_accent = "Directory",
    --- When true, a file is marked as reviewed when it is shown
    auto_review = false,
    --- Most difft processes run at once for a git diff; 0 uses one per CPU
    max_parallel_difft_calls = 0,
    --- When true, each diff opens in a tab of its own and stays open beside the
    --- others; when false, opening a diff replaces the open one
    multiple_diffs = false,
    keymaps = {
        next_file = "]f",
        prev_file = "[f",
        next_hunk = "]c",
        prev_hunk = "[c",
        close = "q",
        focus_tree = "<Tab>",
        focus_diff = "<Tab>",
        select = "<CR>",
        goto_file = "gf",
        toggle_reviewed = "R",
        next_unreviewed = "]u",
        prev_unreviewed = "[u",
    },
    tree = {
        width = 40,
        icons = {
            enable = true,
            dir_open = "",
            dir_closed = "",
            --- Review marker of a file not shown yet in this diff view
            unvisited = "•",
            --- Review marker of a file marked as reviewed
            reviewed = "✓",
        },
    },
    snacks_picker = {
        enabled = false,
        limit = 200,
        jj_log_revset = nil,
    },
}

--- The diff shown in each tab that has one, by tabpage handle.
--- @type table<number, table>
local diffs = {}

--- A diff state with nothing shown yet.
local function new_state()
    return {
        current_file_idx = 1,
        files = {},
        positions = {},
        fold_ranges = {},
        fold_states = {},
        saved_fold_options = {},
        visited = {},
        reviewed = {},
        hunk_positions = {},
    }
end

-- `M.state` is the diff state of the current tab (an empty one in a tab without
-- a diff). Code that may run while another tab is current, such as autocmds and
-- callbacks, keeps the state of its own diff instead.
setmetatable(M, {
    __index = function(_, key)
        if key == "state" then
            return diffs[vim.api.nvim_get_current_tabpage()] or new_state()
        end
    end,
})

--- Create an autocmd belonging to a diff, in the shared augroup `group`; closing
--- the diff deletes it.
--- @param owner table Diff state (or loading record) owning the autocmd
--- @param group string
--- @param event string|string[]
--- @param opts table As for nvim_create_autocmd, without `group`
function M.diff_autocmd(owner, group, event, opts)
    opts.group = vim.api.nvim_create_augroup(group, { clear = false })
    owner.autocmds = owner.autocmds or {}
    table.insert(owner.autocmds, vim.api.nvim_create_autocmd(event, opts))
end

--- Delete the autocmds created with `diff_autocmd` for `owner`.
local function delete_autocmds(owner)
    for _, id in ipairs(owner.autocmds or {}) do
        pcall(vim.api.nvim_del_autocmd, id)
    end
    owner.autocmds = {}
end

local function git_range_label(revset)
    if revset == nil then
        return "index → worktree"
    end
    if revset == "--staged" then
        return "HEAD → index"
    end

    if revset:find("...", 1, true) then
        local base, head = revset:match("^(.-)%.%.%.(.*)$")
        return (base or "") .. " … " .. (head or "")
    end

    if revset:find("..", 1, true) then
        local base, head = revset:match("^(.-)%.%.(.*)$")
        return (base or "") .. " → " .. (head or "")
    end

    return revset .. "^ → " .. revset
end

local function range_context(revset, vcs)
    if vcs == "git" then
        return "Base/Head", git_range_label(revset)
    end

    if revset == nil or revset == "--staged" then
        return "Revset", "@"
    end
    return "Revset", revset
end

--- Initialize the plugin with user options.
--- @param opts table|nil User configuration
function M.setup(opts)
    opts = opts or {}

    -- Merge config
    if opts.download ~= nil then
        M.config.download = opts.download
    end
    if opts.vcs then
        M.config.vcs = opts.vcs
    end
    if opts.highlight_mode then
        M.config.highlight_mode = opts.highlight_mode
    end
    if opts.hunk_wrap_file ~= nil then
        M.config.hunk_wrap_file = opts.hunk_wrap_file
    end
    if opts.scroll_to_first_hunk ~= nil then
        M.config.scroll_to_first_hunk = opts.scroll_to_first_hunk
    end
    if opts.focus_diff_on_select ~= nil then
        M.config.focus_diff_on_select = opts.focus_diff_on_select
    end
    if opts.context_size ~= nil then
        if type(opts.context_size) ~= "number" or opts.context_size < 0 then
            vim.notify("difftastic-nvim: context_size must be 0 or more, ignoring " .. vim.inspect(opts.context_size), vim.log.levels.ERROR)
        else
            M.config.context_size = math.floor(opts.context_size)
        end
    end
    if opts.min_fold_size ~= nil then
        if type(opts.min_fold_size) ~= "number" or opts.min_fold_size < 1 then
            vim.notify("difftastic-nvim: min_fold_size must be 1 or more, ignoring " .. vim.inspect(opts.min_fold_size), vim.log.levels.ERROR)
        else
            M.config.min_fold_size = math.floor(opts.min_fold_size)
        end
    end
    if opts.fold_by_default ~= nil then
        M.config.fold_by_default = opts.fold_by_default
    end
    if opts.fold_accent ~= nil then
        if type(opts.fold_accent) ~= "string" or opts.fold_accent == "" then
            vim.notify("difftastic-nvim: fold_accent must be a highlight group name, ignoring " .. vim.inspect(opts.fold_accent), vim.log.levels.ERROR)
        else
            M.config.fold_accent = opts.fold_accent
        end
    end
    if opts.fold_fill ~= nil then
        if type(opts.fold_fill) ~= "string" or vim.fn.strchars(opts.fold_fill) ~= 1 or vim.fn.strdisplaywidth(opts.fold_fill) ~= 1 then
            vim.notify("difftastic-nvim: fold_fill must be a single one-cell character, ignoring " .. vim.inspect(opts.fold_fill), vim.log.levels.ERROR)
        else
            M.config.fold_fill = opts.fold_fill
        end
    end
    if opts.auto_review ~= nil then
        M.config.auto_review = opts.auto_review
    end
    if opts.multiple_diffs ~= nil then
        M.config.multiple_diffs = opts.multiple_diffs
    end
    if opts.max_parallel_difft_calls ~= nil then
        local value = opts.max_parallel_difft_calls
        if type(value) ~= "number" or value < 0 or value ~= math.floor(value) then
            vim.notify(
                "difftastic-nvim: max_parallel_difft_calls must be a whole number, 0 or more; ignoring " .. vim.inspect(value),
                vim.log.levels.ERROR
            )
        else
            M.config.max_parallel_difft_calls = value
        end
    end
    if opts.keymaps then
        -- Manual merge to preserve explicit false values (tbl_extend ignores them)
        -- Note: nil values are skipped by pairs(), so they keep the default
        for k, v in pairs(opts.keymaps) do
            M.config.keymaps[k] = v
        end
    end
    if opts.tree then
        if opts.tree.icons then
            M.config.tree.icons = vim.tbl_extend("force", M.config.tree.icons, opts.tree.icons)
        end
        if opts.tree.width then
            M.config.tree.width = opts.tree.width
        end
    end
    if opts.snacks_picker then
        M.config.snacks_picker = vim.tbl_extend("force", M.config.snacks_picker, opts.snacks_picker)
    end

    highlight.setup(opts.highlights)
    binary.ensure_exists(M.config.download)
end

--- Keep the two diff panes in step where Neovim does not:
--- - Resizing Neovim gives the whole change in width to the rightmost window. The
---   panes keep splitting the space next to the tree in their last ratio instead.
---   A resize while another tab is current is applied when the diff tab is entered.
--- - 'scrollbind' only follows the current window, so mouse-wheel scrolling the
---   other pane left its partner behind. Rows are aligned in both panes, so the
---   partner takes the same top line.
--- The autocmds remove themselves once the view is closed.
--- @param state table Plugin state of the opened view
local function setup_pane_sync(state)
    local function valid()
        return state.left_win
            and state.right_win
            and vim.api.nvim_win_is_valid(state.left_win)
            and vim.api.nvim_win_is_valid(state.right_win)
    end
    local function widths()
        return vim.api.nvim_win_get_width(state.left_win), vim.api.nvim_win_get_width(state.right_win)
    end

    -- The base pane's share of the space next to the tree, kept as a float so that
    -- repeated resizes do not round it away. The panes open evenly split.
    state.pane_ratio = 0.5
    -- The widths the plugin itself gave the panes, so that its own resizes are not
    -- taken for a split the user dragged.
    local function remember_widths()
        local l, r = widths()
        state.pane_widths = { l, r }
    end
    local pending = false

    local function apply_ratio()
        local l, r = widths()
        vim.api.nvim_win_set_width(state.left_win, math.floor((l + r) * state.pane_ratio + 0.5))
        remember_widths()
    end
    remember_widths()

    M.diff_autocmd(state, "DifftPaneSync", "VimResized", {
        callback = function()
            if not valid() then
                return true -- diff view closed: drop this autocmd
            end
            if vim.api.nvim_get_current_tabpage() == state.diff_tabpage then
                apply_ratio()
            else
                -- Window sizes of another tab are only updated when it is entered.
                pending = true
            end
        end,
    })
    M.diff_autocmd(state, "DifftPaneSync", "TabEnter", {
        callback = function()
            if not valid() then
                return true
            end
            if pending and vim.api.nvim_get_current_tabpage() == state.diff_tabpage then
                pending = false
                apply_ratio()
            end
        end,
    })
    -- A split the user drags between the panes sets the ratio for later resizes. A
    -- tree width change takes its columns from the base pane alone, so the panes
    -- are put back in their ratio instead.
    M.diff_autocmd(state, "DifftPaneSync", "WinResized", {
        callback = function()
            if not valid() then
                return true
            end
            if pending then
                return
            end
            local tree_resized, panes_resized = false, false
            for _, win in ipairs(vim.v.event.windows or {}) do
                if win == state.tree_win then
                    tree_resized = true
                elseif win == state.left_win or win == state.right_win then
                    panes_resized = true
                end
            end
            if tree_resized then
                apply_ratio()
            elseif panes_resized then
                local l, r = widths()
                local set = state.pane_widths
                if not (set and set[1] == l and set[2] == r) then
                    -- Dragged by the user: the new split sets the ratio.
                    state.pane_ratio = l / (l + r)
                    remember_widths()
                end
            end
        end,
    })
    -- Folds belong to each window; opening or closing one in a pane is copied to
    -- the other pane once Neovim is idle, whatever did it (keys, mouse, commands).
    M.diff_autocmd(state, "DifftPaneSync", "SafeState", {
        callback = function()
            if not valid() then
                return true
            end
            fold.sync(state)
        end,
    })
    M.diff_autocmd(state, "DifftPaneSync", "WinScrolled", {
        callback = function()
            if not valid() then
                return true
            end
            local scrolled = vim.v.event
            local left_scrolled = scrolled[tostring(state.left_win)] ~= nil
            local right_scrolled = scrolled[tostring(state.right_win)] ~= nil
            if not (left_scrolled or right_scrolled) then
                return
            end
            local source = left_scrolled and state.left_win or state.right_win
            if left_scrolled and right_scrolled then
                -- Both moved: the current pane leads.
                local current = vim.api.nvim_get_current_win()
                source = current == state.right_win and state.right_win or state.left_win
            end
            local target = source == state.left_win and state.right_win or state.left_win
            local top = vim.fn.getwininfo(source)[1].topline
            if vim.fn.getwininfo(target)[1].topline == top then
                return
            end
            vim.api.nvim_win_call(target, function()
                -- Keep the cursor inside the new view, or Neovim scrolls back to it.
                local height, scrolloff = vim.api.nvim_win_get_height(0), vim.wo.scrolloff
                local line = math.min(math.max(vim.fn.line("."), top + scrolloff), top + height - 1 - scrolloff)
                vim.fn.winrestview({ topline = top, lnum = math.max(line, top) })
            end)
        end,
    })
end

--- How long the screen size must stay unchanged after startup before a diff opened
--- during startup is shown, and the longest wait (milliseconds).
M.startup_settle_ms = 150
M.startup_settle_max_ms = 1000

--- Open a diff view, as `open()`, on the next main loop iteration (as the
--- :Difft command always did). When called while Neovim starts up (for example
--- `nvim -c 'Difft'`), only once startup has finished and the screen size has
--- settled: a GUI may resize the grid right after startup (Neovide applies its
--- scale factor then), and since computing the diff blocks Neovim, a resize
--- arriving meanwhile would leave the view laid out for the old size.
--- @param revset string|nil As for open()
function M.open_when_ready(revset)
    if vim.v.vim_did_enter == 1 then
        vim.schedule(function()
            M.open(revset)
        end)
        return
    end
    vim.api.nvim_create_autocmd("VimEnter", {
        once = true,
        callback = function()
            local start = vim.uv.now()
            local last_resize = start
            local group = vim.api.nvim_create_augroup("DifftStartupSettle", { clear = true })
            vim.api.nvim_create_autocmd("VimResized", {
                group = group,
                callback = function()
                    last_resize = vim.uv.now()
                end,
            })
            local timer, done = vim.uv.new_timer(), false
            timer:start(25, 25, vim.schedule_wrap(function()
                local now = vim.uv.now()
                if done or (now - last_resize < M.startup_settle_ms and now - start < M.startup_settle_max_ms) then
                    return
                end
                done = true
                timer:stop()
                timer:close()
                pcall(vim.api.nvim_del_augroup_by_id, group)
                M.open(revset)
            end))
        end,
    })
end

--- Width of the loading window that shows progress, so it does not jump as the
--- progress text changes.
local PROGRESS_WIDTH = 48

--- Place a loading window centred on the editor.
--- @param win number
--- @param width number
--- @param height number
local function center_loading(win, width, height)
    width = math.min(width, math.max(1, vim.o.columns - 4))
    vim.api.nvim_win_set_config(win, {
        relative = "editor",
        width = width,
        height = height,
        row = math.max(0, math.floor((vim.o.lines - height - 2) / 2)),
        col = math.max(0, math.floor((vim.o.columns - width - 2) / 2)),
    })
end

--- Show a centred loading window over the current tab, styled like the side
--- panel's header box: "Loading…" in the top border and the range row below it.
--- @param kind string Range kind ("Base/Head", "Revset")
--- @param label string|nil Range label
--- @return number window
local function show_loading(kind, label)
    label = label or ""
    local row = " " .. kind .. "  " .. label .. " "
    local width = math.min(vim.fn.strdisplaywidth(row), math.max(1, vim.o.columns - 4))
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { row })
    local ns = vim.api.nvim_create_namespace("difft-loading")
    vim.api.nvim_buf_set_extmark(buf, ns, 0, 1, { end_col = 1 + #kind, hl_group = "DifftTreeMuted" })
    if label ~= "" then
        local start = 1 + #kind + 2
        vim.api.nvim_buf_set_extmark(buf, ns, 0, start, { end_col = start + #label, hl_group = "DifftTreeRange" })
    end
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].modifiable = false
    local win = vim.api.nvim_open_win(buf, false, {
        relative = "editor",
        width = width,
        height = 1,
        row = math.max(0, math.floor((vim.o.lines - 3) / 2)),
        col = math.max(0, math.floor((vim.o.columns - width - 2) / 2)),
        style = "minimal",
        border = "rounded",
        title = { { " Loading… ", "DifftTreeTitle" } },
        title_pos = "center",
        focusable = false,
        noautocmd = true,
    })
    vim.wo[win].winhl = "NormalFloat:DifftTreeNormal,FloatBorder:DifftTreeDivider,FloatTitle:DifftTreeTitle"
    return win
end

--- One row of `width` cells with a one-cell margin: `left` aligned left, `right`
--- aligned right, `right` cut at its start ("…") when both do not fit.
--- @return string row
--- @return number right_start Byte offset of `right` in the row
local function spread(left, right, width)
    local inner = math.max(0, width - 2)
    local room = inner - vim.fn.strdisplaywidth(left) - ((left ~= "" and right ~= "") and 1 or 0)
    if vim.fn.strdisplaywidth(right) > room then
        local cut, start = right, 0
        while cut ~= "" and vim.fn.strdisplaywidth(cut) > room - 1 do
            start = start + 1
            cut = vim.fn.strcharpart(right, start)
        end
        right = room > 0 and ("…" .. cut) or ""
    end
    local gap = math.max(0, inner - vim.fn.strdisplaywidth(left) - vim.fn.strdisplaywidth(right))
    return " " .. left .. string.rep(" ", gap) .. right .. " ", 1 + #left + gap
end

--- Draw a progress box's two rows at its window's width: the range kind left and
--- the range right, then the progress numbers left (in the Directory colour) and
--- the last message right (in normal text).
--- @param box table From `show_progress_box`
local function draw_progress_box(box)
    if not vim.api.nvim_win_is_valid(box.win) then
        return
    end
    local width = vim.api.nvim_win_get_width(box.win)
    local range, range_start = spread(box.kind, box.label, width)
    local progress = spread(box.numbers, box.message, width)
    vim.bo[box.buf].modifiable = true
    vim.api.nvim_buf_set_lines(box.buf, 0, -1, false, { range, progress })
    vim.bo[box.buf].modifiable = false
    local ns = vim.api.nvim_create_namespace("difft-loading")
    vim.api.nvim_buf_clear_namespace(box.buf, ns, 0, -1)
    vim.api.nvim_buf_set_extmark(box.buf, ns, 0, 1, { end_col = 1 + #box.kind, hl_group = "DifftTreeMuted" })
    if #range - 1 > range_start then
        vim.api.nvim_buf_set_extmark(box.buf, ns, 0, range_start, { end_col = #range - 1, hl_group = "DifftTreeRange" })
    end
    if box.numbers ~= "" then
        vim.api.nvim_buf_set_extmark(box.buf, ns, 1, 1, { end_col = 1 + #box.numbers, hl_group = "Directory" })
    end
end

--- Show the loading window of a diff computed in the background, styled like
--- `show_loading`, with a second row for the progress.
--- @param kind string Range kind ("Base/Head", "Revset")
--- @param label string|nil Range label
--- @return table box `{ win, buf, width, kind, label, numbers, message }`; `width`
---   is the width wanted, before limiting it to the screen
local function show_progress_box(kind, label)
    label = label or ""
    local box = { kind = kind, label = label, numbers = "", message = "Starting…" }
    box.width = math.max(vim.fn.strdisplaywidth(" " .. kind .. "  " .. label .. " "), PROGRESS_WIDTH)
    local width = math.min(box.width, math.max(1, vim.o.columns - 4))
    box.buf = vim.api.nvim_create_buf(false, true)
    vim.bo[box.buf].bufhidden = "wipe"
    box.win = vim.api.nvim_open_win(box.buf, false, {
        relative = "editor",
        width = width,
        height = 2,
        row = math.max(0, math.floor((vim.o.lines - 4) / 2)),
        col = math.max(0, math.floor((vim.o.columns - width - 2) / 2)),
        style = "minimal",
        border = "rounded",
        title = { { " Loading… ", "DifftTreeTitle" } },
        title_pos = "center",
        focusable = false,
        noautocmd = true,
    })
    vim.wo[box.win].winhl = "NormalFloat:DifftTreeNormal,FloatBorder:DifftTreeDivider,FloatTitle:DifftTreeTitle"
    draw_progress_box(box)
    return box
end

--- Show progress in a progress box: "3/12 files" left, the last message right.
--- @param box table From `show_progress_box`
--- @param count number Steps done
--- @param total number Steps in all, -1 while unknown
--- @param message string What was done last; empty keeps the previous message
local function show_progress(box, count, total, message)
    box.numbers = total >= 0 and ("%d/%d files"):format(count, total) or ""
    if message ~= "" then
        box.message = message
    end
    draw_progress_box(box)
end

--- How often running diffs are polled for progress and results (milliseconds).
M.poll_interval_ms = 50

local poll_timer = nil

local function stop_polling()
    if poll_timer then
        poll_timer:stop()
        poll_timer:close()
        poll_timer = nil
    end
end

--- Deliver what running diffs reported; stop polling once none is left.
local function poll()
    local ok, pending = pcall(function()
        return binary.get().poll()
    end)
    if not ok then
        vim.notify("difftastic-nvim: " .. tostring(pending), vim.log.levels.ERROR)
        return
    end
    if pending == 0 then
        stop_polling()
    end
end

--- Poll while diffs run. Started with each diff; stops by itself.
local function ensure_polling()
    if poll_timer then
        return
    end
    poll_timer = vim.uv.new_timer()
    -- Timer callbacks run where most of the API is unavailable: poll on the main loop.
    poll_timer:start(M.poll_interval_ms, M.poll_interval_ms, vim.schedule_wrap(function()
        if poll_timer then
            poll()
        end
    end))
end

--- Stop a diff being computed in the background (`state.loading`): cancel its
--- job and close its loading window, and with `close_tab` also its tab (going
--- back to the tab the diff was opened from when the loading tab is current).
--- @param state table Diff state
--- @param close_tab boolean
local function cancel_loading(state, close_tab)
    local record = state.loading
    if not record then
        return
    end
    state.loading = nil
    record.closed = true
    if record.job then
        record.job:cancel()
    end
    delete_autocmds(record)
    if record.win and vim.api.nvim_win_is_valid(record.win) then
        vim.api.nvim_win_close(record.win, true)
    end
    if close_tab and vim.api.nvim_tabpage_is_valid(record.tab) then
        if vim.api.nvim_get_current_tabpage() == record.tab and vim.api.nvim_tabpage_is_valid(record.original_tab) then
            vim.api.nvim_set_current_tabpage(record.original_tab)
        end
        vim.cmd("tabclose " .. vim.api.nvim_tabpage_get_number(record.tab))
    end
end

--- Forget a diff: stop its computation and delete its autocmds. Its tab is left
--- alone.
--- @param state table Diff state
local function drop(state)
    cancel_loading(state, false)
    delete_autocmds(state)
    if diffs[state.diff_tabpage] == state then
        diffs[state.diff_tabpage] = nil
    end
end

-- A diff tab closed by other means than closing the diff (:tabclose, :tabonly):
-- forget its diff. The closed tab's handle is still valid while TabClosed runs.
vim.api.nvim_create_autocmd("TabClosed", {
    group = vim.api.nvim_create_augroup("DifftTabs", { clear = true }),
    callback = function()
        vim.schedule(function()
            for tab, state in pairs(diffs) do
                if not vim.api.nvim_tabpage_is_valid(tab) then
                    drop(state)
                end
            end
        end)
    end,
})

--- Leave the tab opened for a diff that has nothing to show, back to the tab the
--- diff was opened from.
--- @param state table Diff state
local function leave_diff_tab(state)
    drop(state)
    local original_tabpage, diff_tabpage = state.original_tabpage, state.diff_tabpage
    if vim.api.nvim_get_current_tabpage() == diff_tabpage and vim.api.nvim_tabpage_is_valid(original_tabpage) then
        vim.api.nvim_set_current_tabpage(original_tabpage)
    end
    if vim.api.nvim_tabpage_is_valid(diff_tabpage) then
        vim.cmd("tabclose " .. vim.api.nvim_tabpage_get_number(diff_tabpage))
    end
end

--- Build the diff view for computed files in the current tab, the diff tab.
--- @param state table Diff state of the tab
local function present(state, files, revset)
    state.files = files
    state.current_file_idx = 1
    state.range_kind, state.range_label = range_context(revset, M.config.vcs)

    -- The tab's window becomes the side panel and keeps its place at the left
    -- edge, the panes open to its right: no window already shown moves, which
    -- GUIs animating window positions (Neovide) would show sliding in.
    local panel_win = vim.api.nvim_get_current_win()
    diff.open(state)
    vim.api.nvim_set_current_win(panel_win)
    tree.open(state)
    vim.api.nvim_set_current_win(state.right_win)
    -- Narrowing the panel gave its columns to the base pane: split evenly again.
    local total = vim.api.nvim_win_get_width(state.left_win) + vim.api.nvim_win_get_width(state.right_win)
    vim.api.nvim_win_set_width(state.left_win, math.floor(total / 2))
    keymaps.setup(state)

    -- Remember the diff pane used last, so focus can return to it from the tree.
    local function track_pane()
        if not (state.left_win and vim.api.nvim_win_is_valid(state.left_win)) then
            return true -- diff view closed: drop this autocmd
        end
        local win = vim.api.nvim_get_current_win()
        if win == state.left_win then
            state.pane_side = "base"
        elseif win == state.right_win then
            state.pane_side = "head"
        end
    end
    M.diff_autocmd(state, "DifftPaneSide", "WinEnter", {
        callback = function()
            if track_pane() then
                return true
            end
            record_position(state)
        end,
    })
    -- Keep the shown file's position current, not only when the file is left.
    M.diff_autocmd(state, "DifftPaneSide", "CursorMoved", {
        callback = function()
            if not (state.left_win and vim.api.nvim_win_is_valid(state.left_win)) then
                return true -- diff view closed: drop this autocmd
            end
            local win = vim.api.nvim_get_current_win()
            if win == state.left_win or win == state.right_win then
                record_position(state)
            end
        end,
    })

    local first_idx = tree.first_file_in_display_order(state)
    if first_idx then
        M.show_file(first_idx)
    end
    -- The pane focused when the view opens counts as used.
    track_pane()

    setup_pane_sync(state)
end

--- Compute the diff while Neovim stays responsive: the loading window shows the
--- progress, and the view is built in the diff tab once the result arrives (on
--- entering that tab, if another tab is current then). Closing the tab, closing
--- the view, opening another diff or quitting Neovim cancels the computation.
--- @param state table Diff state of the new tab
local function open_async(lib, revset, state)
    local record = { tab = state.diff_tabpage, original_tab = state.original_tabpage, closed = false }
    record.box = show_progress_box(range_context(revset, M.config.vcs))
    record.win = record.box.win
    -- The close key works in the loading tab as in the view: it cancels the diff.
    if M.config.keymaps.close then
        vim.keymap.set("n", M.config.keymaps.close, function()
            M.close()
        end, { buffer = vim.api.nvim_get_current_buf(), nowait = true, desc = "Cancel loading the diff" })
    end
    state.loading = record

    local function stale()
        return state.loading ~= record or record.closed or not vim.api.nvim_tabpage_is_valid(record.tab)
    end

    local function finish(result, err)
        if err or not result.files or #result.files == 0 then
            leave_diff_tab(state)
            if err then
                vim.notify("difftastic-nvim: " .. err, vim.log.levels.ERROR)
            else
                vim.notify("No changes found", vim.log.levels.INFO)
            end
            return
        end
        local function build()
            if stale() then
                return
            end
            state.loading = nil
            delete_autocmds(record)
            if vim.api.nvim_win_is_valid(record.win) then
                vim.api.nvim_win_close(record.win, true)
            end
            present(state, result.files, revset)
        end
        if vim.api.nvim_get_current_tabpage() == record.tab then
            build()
        else
            -- Windows are laid out in the current tab: wait until the diff tab is.
            M.diff_autocmd(record, "DifftLoading", "TabEnter", {
                callback = function()
                    if vim.api.nvim_get_current_tabpage() == record.tab then
                        build()
                        return true
                    end
                end,
            })
        end
    end

    M.diff_autocmd(record, "DifftLoading", "VimResized", {
        callback = function()
            if vim.api.nvim_win_is_valid(record.win) then
                center_loading(record.win, record.box.width, 2)
                draw_progress_box(record.box)
            end
        end,
    })
    M.diff_autocmd(record, "DifftLoading", "VimLeavePre", {
        callback = function()
            cancel_loading(state, false)
        end,
    })

    local spec = { vcs = M.config.vcs, max_parallel = M.config.max_parallel_difft_calls }
    if revset == nil then
        spec.mode = "unstaged"
    elseif revset == "--staged" then
        spec.mode = "staged"
    else
        spec.mode, spec.revset = "range", revset
    end
    local ok, job = pcall(lib.run_diff_async, spec, function(count, total, message)
        if stale() then
            return false
        end
        show_progress(record.box, count, total, message)
    end, function(result, err)
        if not stale() then
            finish(result, err)
        end
    end)
    if not ok then
        leave_diff_tab(state)
        error(job, 0)
    end
    record.job = job
    ensure_polling()
end

--- Open diff view for a revision/commit range.
--- @param revset string|nil jj revset or git commit range (nil = unstaged, "--staged" = staged)
function M.open(revset)
    if M.config.multiple_diffs then
        -- A diff of the same revset already open (or loading): go to its tab.
        for tab, state in pairs(diffs) do
            if state.revset == revset and vim.api.nvim_tabpage_is_valid(tab) then
                vim.api.nvim_set_current_tabpage(tab)
                return
            end
        end
    else
        -- One diff at a time: a new one replaces the one open (or still loading).
        for _, state in pairs(diffs) do
            M.close(state)
        end
    end
    -- The theme may have changed without a ColorScheme event since setup().
    highlight.refresh()

    -- Show the new tab with a loading message while the diff is computed.
    local state = new_state()
    state.revset = revset
    state.original_tabpage = vim.api.nvim_get_current_tabpage()
    vim.cmd("tabnew")
    state.diff_tabpage = vim.api.nvim_get_current_tabpage()
    diffs[state.diff_tabpage] = state
    -- Let Neovim handle input still queued, such as a terminal resize reported while
    -- it started up, so the message is centred on the current screen size.
    vim.wait(0)

    local ok_lib, lib = pcall(binary.get)
    if ok_lib and type(lib) == "table" and lib.run_diff_async and lib.poll then
        return open_async(lib, revset, state)
    end

    -- A library without asynchronous diffs: compute the diff here, blocking.
    local loading_win = show_loading(range_context(revset, M.config.vcs))
    vim.cmd("redraw")

    local ok, result = pcall(function()
        if not ok_lib then
            error(lib, 0)
        end
        if revset == nil then
            return lib.run_diff_unstaged(M.config.vcs, M.config.max_parallel_difft_calls)
        elseif revset == "--staged" then
            return lib.run_diff_staged(M.config.vcs, M.config.max_parallel_difft_calls)
        end
        return lib.run_diff(revset, M.config.vcs, M.config.max_parallel_difft_calls)
    end)
    if vim.api.nvim_win_is_valid(loading_win) then
        vim.api.nvim_win_close(loading_win, true)
    end
    if not ok or not result.files or #result.files == 0 then
        -- Nothing to show: leave the loading tab.
        leave_diff_tab(state)
        if not ok then
            error(result, 0)
        end
        vim.notify("No changes found", vim.log.levels.INFO)
        return
    end

    present(state, result.files, revset)
end

--- Close a diff view: the current tab's, else (without `multiple_diffs`) the
--- one open.
--- @param state table|nil Diff state to close (internal)
function M.close(state)
    state = state or diffs[vim.api.nvim_get_current_tabpage()]
    if not state and not M.config.multiple_diffs then
        state = select(2, next(diffs))
    end
    if not state then
        return
    end
    -- A diff still being computed: stop it and close its tab.
    cancel_loading(state, true)
    -- Settle the state before it is dropped: a fold change still in one pane.
    fold.sync(state)
    -- Drop the view's autocmds now rather than when their events next fire.
    drop(state)

    -- Switch to original tabpage if valid
    local diff_tabpage, original_tabpage = state.diff_tabpage, state.original_tabpage
    if vim.api.nvim_get_current_tabpage() == diff_tabpage and original_tabpage and vim.api.nvim_tabpage_is_valid(original_tabpage) then
        vim.api.nvim_set_current_tabpage(original_tabpage)
    end

    -- Close the diff tabpage
    if diff_tabpage and vim.api.nvim_tabpage_is_valid(diff_tabpage) then
        vim.cmd("tabclose " .. vim.api.nvim_tabpage_get_number(diff_tabpage))
    end
end

--- Remember the cursor position in the shown file: line, column and the diff pane
--- used last.
--- @param state table Diff state
function record_position(state)
    local path = state.shown_path
    if not path then
        return
    end
    local side = state.pane_side or "head"
    local pane = side == "head" and state.right_win or state.left_win
    if not (pane and vim.api.nvim_win_is_valid(pane)) then
        return
    end
    local cursor = vim.api.nvim_win_get_cursor(pane)
    state.positions[path] = { line = cursor[1], col = cursor[2], side = side }
end

--- Put the cursor at a position in the shown file: line, column and diff pane. Both
--- panes go to the line, as their rows are aligned. When a diff pane has focus,
--- focus moves to the given pane.
--- @param state table Diff state
--- @param pos table `{ line, col, side }`
local function restore_position(state, pos)
    local head = pos.side == "head"
    local pane = head and state.right_win or state.left_win
    local partner = head and state.left_win or state.right_win
    local buf = head and state.right_buf or state.left_buf
    if not (pane and vim.api.nvim_win_is_valid(pane)) then
        return
    end
    local line = math.max(1, math.min(pos.line, vim.api.nvim_buf_line_count(buf)))
    -- nvim_win_set_cursor clamps the column to the line length.
    vim.api.nvim_win_set_cursor(pane, { line, pos.col })
    if partner and vim.api.nvim_win_is_valid(partner) then
        local partner_buf = vim.api.nvim_win_get_buf(partner)
        vim.api.nvim_win_set_cursor(partner, { math.min(line, vim.api.nvim_buf_line_count(partner_buf)), pos.col })
    end
    state.pane_side = pos.side
    local current = vim.api.nvim_get_current_win()
    if current == state.left_win or current == state.right_win then
        vim.api.nvim_set_current_win(pane)
    end
end

--- Toggle the reviewed mark: in the tree, of the file under the cursor, or of all
--- files in the directory under it (marking them all unless all are marked);
--- elsewhere, of the shown file.
function M.toggle_reviewed()
    local state = M.state
    local paths = {}
    if vim.api.nvim_get_current_win() == state.tree_win and state.tree then
        local node = state.tree:get_node()
        if node then
            paths = tree.file_paths(node, state)
        end
    elseif state.shown_path then
        paths = { state.shown_path }
    end
    if #paths == 0 then
        return
    end
    local all_reviewed = true
    for _, path in ipairs(paths) do
        all_reviewed = all_reviewed and state.reviewed[path] == true
    end
    for _, path in ipairs(paths) do
        state.reviewed[path] = not all_reviewed or nil
    end
    tree.refresh_header(state)
    tree.refresh_rows(state)
end

--- Show the next (direction 1) or previous (-1) file not marked as reviewed, in
--- tree order and wrapping around; collapsed directories around it are opened.
local function step_unreviewed(direction)
    local state = M.state
    local order = tree.all_files_in_order(state)
    local current = state.current_file_idx
    local pos = 0
    for i, idx in ipairs(order) do
        if idx == current then
            pos = i
        end
    end
    for step = 1, #order do
        local idx = order[(pos - 1 + direction * step) % #order + 1]
        local file = state.files[idx]
        if idx ~= current and file and not state.reviewed[file.path] then
            tree.reveal_file(state, idx)
            M.show_file(idx)
            return
        end
    end
    vim.notify("difftastic-nvim: no other file left to review", vim.log.levels.INFO)
end

--- Show the next file not marked as reviewed.
function M.next_unreviewed()
    step_unreviewed(1)
end

--- Show the previous file not marked as reviewed.
function M.prev_unreviewed()
    step_unreviewed(-1)
end

--- Move focus to the diff pane used last; the head (right) pane at first.
function M.focus_diff()
    local state = M.state
    local win = state.pane_side == "base" and state.left_win or state.right_win
    if win and vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_set_current_win(win)
    end
end

--- Give the two diff panes the same width, leaving the tree alone.
function M.equalize_panes()
    local state = M.state
    local left, right = state.left_win, state.right_win
    if not (left and right and vim.api.nvim_win_is_valid(left) and vim.api.nvim_win_is_valid(right)) then
        return
    end
    local total = vim.api.nvim_win_get_width(left) + vim.api.nvim_win_get_width(right)
    -- An exact half, kept for later resizes (see setup_pane_sync).
    state.pane_ratio = 0.5
    vim.api.nvim_win_set_width(left, math.floor(total / 2))
    state.pane_widths = { vim.api.nvim_win_get_width(left), vim.api.nvim_win_get_width(right) }
end

--- Give the side panel its configured width (tree.width); the diff panes keep
--- their ratio.
function M.reset_tree_width()
    local state = M.state
    local tree_win = state.tree_win
    if tree_win and vim.api.nvim_win_is_valid(tree_win) then
        vim.api.nvim_win_set_width(tree_win, M.config.tree.width)
    end
end

--- Act on a double click on a split of the view: the split between the diff panes
--- gives them the same width, the side panel's right border resets its width.
--- The action runs on the next tick.
--- @return boolean handled True when the last mouse event was on one of them
function M.split_double_click()
    local state = M.state
    local mouse = vim.fn.getmousepos()
    -- A separator belongs to the window on its left, one column past its width.
    local function on_right_border(win)
        return win
            and vim.api.nvim_win_is_valid(win)
            and mouse.winid == win
            and mouse.line == 0
            and mouse.wincol == vim.api.nvim_win_get_width(win) + 1
    end
    if on_right_border(state.left_win) then
        vim.schedule(M.equalize_panes)
        return true
    end
    if on_right_border(state.tree_win) then
        vim.schedule(M.reset_tree_width)
        return true
    end
    return false
end

--- Show a specific file by index. A file shown before gets its cursor position
--- back; otherwise the cursor goes to the first hunk (with scroll_to_first_hunk)
--- or the top.
--- @param idx number File index (1-based)
function M.show_file(idx)
    local state = M.state
    if idx < 1 or idx > #state.files then
        return
    end
    -- Settle the file being left: a fold change still in one pane, the cursor.
    fold.sync(state)
    record_position(state)
    state.current_file_idx = idx
    local file = state.files[idx]
    diff.render(state, file)
    state.shown_path = file.path
    state.visited[file.path] = true
    if M.config.auto_review and not state.reviewed[file.path] then
        state.reviewed[file.path] = true
        tree.refresh_header(state)
    end
    local folds_restored = fold.render(state, file, state.fold_states[file.path])
    local pos = state.positions[file.path]
    if not pos then
        -- A file not shown before opens at its first hunk (or its top) in the pane
        -- in use, which is also where <Tab> from the tree goes.
        local first = M.config.scroll_to_first_hunk and state.hunk_positions[1] or 1
        pos = { line = first, col = 0, side = state.pane_side or "head" }
    elseif not folds_restored then
        -- The folds were rebuilt with their default states (their layout changed),
        -- so the remembered line may now be hidden: open the fold over it.
        fold.reveal(state, pos.line)
    end
    restore_position(state, pos)
    -- The review marker of the shown file may have changed.
    tree.refresh_rows(state)
    tree.highlight_current(state)
end

--- Show a file and jump to a specific hunk after rendering completes.
--- @param idx number File index to show
--- @param hunk_fn function Hunk function to call (e.g., diff.first_hunk or diff.last_hunk)
local function show_file_and_jump_to_hunk(idx, hunk_fn)
    local state = M.state
    M.show_file(idx)
    vim.schedule(function()
        hunk_fn(state)
    end)
end

--- Navigate to the next file.
function M.next_file()
    local state = M.state
    local next_idx = tree.next_file_in_display_order(state, state.current_file_idx)
    if next_idx then
        M.show_file(next_idx)
        return
    end

    local first_idx = tree.first_file_in_display_order(state)
    if first_idx and first_idx ~= state.current_file_idx then
        M.show_file(first_idx)
    end
end

--- Navigate to the previous file.
function M.prev_file()
    local state = M.state
    local prev_idx = tree.prev_file_in_display_order(state, state.current_file_idx)
    if prev_idx then
        M.show_file(prev_idx)
        return
    end

    local last_idx = tree.last_file_in_display_order(state)
    if last_idx and last_idx ~= state.current_file_idx then
        M.show_file(last_idx)
    end
end

--- Navigate to the next hunk.
--- If hunk_wrap_file is enabled and at the last hunk, wraps to the first hunk of the next file.
--- Otherwise, wraps to the first hunk of the current file.
function M.next_hunk()
    local state = M.state
    local jumped = diff.next_hunk(state)
    if not jumped then
        if M.config.hunk_wrap_file then
            local next_idx = tree.next_file_in_display_order(state, state.current_file_idx)
            if next_idx then
                show_file_and_jump_to_hunk(next_idx, diff.first_hunk)
            else
                -- At last file, wrap to first file
                local first_idx = tree.first_file_in_display_order(state)
                if first_idx and first_idx ~= state.current_file_idx then
                    show_file_and_jump_to_hunk(first_idx, diff.first_hunk)
                end
            end
        else
            -- Wrap within current file
            diff.first_hunk(state)
        end
    end
    vim.cmd("normal! zz")
end

--- Navigate to the previous hunk.
--- If hunk_wrap_file is enabled and at the first hunk, wraps to the last hunk of the previous file.
--- Otherwise, wraps to the last hunk of the current file.
function M.prev_hunk()
    local state = M.state
    local jumped = diff.prev_hunk(state)
    if not jumped then
        if M.config.hunk_wrap_file then
            local prev_idx = tree.prev_file_in_display_order(state, state.current_file_idx)
            if prev_idx then
                show_file_and_jump_to_hunk(prev_idx, diff.last_hunk)
            else
                -- At first file, wrap to last file
                local last_idx = tree.last_file_in_display_order(state)
                if last_idx and last_idx ~= state.current_file_idx then
                    show_file_and_jump_to_hunk(last_idx, diff.last_hunk)
                end
            end
        else
            -- Wrap within current file
            diff.last_hunk(state)
        end
    end
    vim.cmd("normal! zz")
end

--- Go to the file at the current cursor position in an editable buffer.
--- Opens in a previous tabpage if one exists, otherwise creates a new tab.
--- Only works from the right pane (new/working version of the file).
function M.goto_file()
    local state = M.state
    local current_win = vim.api.nvim_get_current_win()

    -- Only works from right pane (new version), not tree or left pane
    if current_win ~= state.right_win or current_win == state.tree_win then
        return
    end

    local file = state.files[state.current_file_idx]
    if not file then
        return
    end

    -- Deleted files have no right-side content to navigate to
    if file.status == "deleted" then
        return
    end

    -- Get current cursor position (row is 1-indexed, col is 0-indexed)
    local cursor = vim.api.nvim_win_get_cursor(current_win)
    local row, col = cursor[1], cursor[2]
    -- Right side = new version; from a filler row, the nearest line
    local target_line = diff.nearest_file_line(state.right_buf, row) or 1

    local filepath = file.path

    -- Close diff view (switches to original tab, closes diff tab)
    M.close()

    -- Open file and jump to line and column
    vim.cmd("edit " .. vim.fn.fnameescape(filepath))
    -- Clamp column to line length to avoid errors on shorter lines
    local line_content = vim.api.nvim_buf_get_lines(0, target_line - 1, target_line, false)[1] or ""
    local target_col = math.min(col, math.max(0, #line_content - 1))
    vim.api.nvim_win_set_cursor(0, { target_line, target_col })
end

--- Update binary to latest release.
function M.update()
    binary.update()
end

--- Pick a revision/commit with snacks.nvim and open diff view.
function M.pick_revision()
    if not M.config.snacks_picker.enabled then
        vim.notify("snacks picker integration is disabled; set snacks_picker.enabled = true", vim.log.levels.WARN)
        return
    end

    require("difftastic-nvim.picker").pick(M.config.vcs, M.config.snacks_picker, function(rev)
        M.open(rev)
    end)
end

--- Pick a start/end revision range with snacks.nvim and open diff view.
function M.pick_range()
    if not M.config.snacks_picker.enabled then
        vim.notify("snacks picker integration is disabled; set snacks_picker.enabled = true", vim.log.levels.WARN)
        return
    end

    require("difftastic-nvim.picker").pick_range(M.config.vcs, M.config.snacks_picker, function(start_rev, end_rev)
        M.open(string.format("%s..%s", start_rev, end_rev))
    end)
end

return M
