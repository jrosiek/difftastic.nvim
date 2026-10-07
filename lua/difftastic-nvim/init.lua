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
    },
    tree = {
        width = 40,
        icons = {
            enable = true,
            dir_open = "",
            dir_closed = "",
        },
    },
    snacks_picker = {
        enabled = false,
        limit = 200,
        jj_log_revset = nil,
    },
}

--- Current diff state
M.state = {
    current_file_idx = 1,
    files = {},
    range_label = nil,
    range_kind = nil,
    tree_win = nil,
    tree_buf = nil,
    left_win = nil,
    left_buf = nil,
    right_win = nil,
    right_buf = nil,
    original_tabpage = nil,
    diff_tabpage = nil,
    pane_side = nil,
    positions = {},
    shown_path = nil,
    fold_ranges = {},
    fold_closed = nil,
    saved_fold_options = {},
}

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

    local group = vim.api.nvim_create_augroup("DifftPaneSync", { clear = true })
    vim.api.nvim_create_autocmd("VimResized", {
        group = group,
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
    vim.api.nvim_create_autocmd("TabEnter", {
        group = group,
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
    vim.api.nvim_create_autocmd("WinResized", {
        group = group,
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
    vim.api.nvim_create_autocmd("SafeState", {
        group = group,
        callback = function()
            if not valid() then
                return true
            end
            fold.sync(state)
        end,
    })
    vim.api.nvim_create_autocmd("WinScrolled", {
        group = group,
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

--- Open diff view for a revision/commit range.
--- @param revset string|nil jj revset or git commit range (nil = unstaged, "--staged" = staged)
function M.open(revset)
    if M.state.tree_win or M.state.left_win or M.state.right_win then
        M.close()
    end

    local result
    if revset == nil then
        result = binary.get().run_diff_unstaged(M.config.vcs)
    elseif revset == "--staged" then
        result = binary.get().run_diff_staged(M.config.vcs)
    else
        result = binary.get().run_diff(revset, M.config.vcs)
    end
    if not result.files or #result.files == 0 then
        vim.notify("No changes found", vim.log.levels.INFO)
        return
    end

    M.state.files = result.files
    M.state.current_file_idx = 1
    -- Per-view tracking; also reset when the previous view was closed with :tabclose.
    M.state.positions = {}
    M.state.shown_path = nil
    M.state.pane_side = nil
    M.state.fold_ranges = {}
    M.state.saved_fold_options = {}
    M.state.range_kind, M.state.range_label = range_context(revset, M.config.vcs)

    -- Store original tabpage and create new one for diff view
    M.state.original_tabpage = vim.api.nvim_get_current_tabpage()
    vim.cmd("tabnew")
    M.state.diff_tabpage = vim.api.nvim_get_current_tabpage()

    tree.open(M.state)
    diff.open(M.state)
    keymaps.setup(M.state)

    -- Remember the diff pane used last, so focus can return to it from the tree.
    local state = M.state
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
    local group = vim.api.nvim_create_augroup("DifftPaneSide", { clear = true })
    vim.api.nvim_create_autocmd("WinEnter", {
        group = group,
        callback = function()
            if track_pane() then
                return true
            end
            record_position()
        end,
    })
    -- Keep the shown file's position current, not only when the file is left.
    vim.api.nvim_create_autocmd("CursorMoved", {
        group = group,
        callback = function()
            if not (state.left_win and vim.api.nvim_win_is_valid(state.left_win)) then
                return true -- diff view closed: drop this autocmd
            end
            local win = vim.api.nvim_get_current_win()
            if win == state.left_win or win == state.right_win then
                record_position()
            end
        end,
    })

    local first_idx = tree.first_file_in_display_order()
    if first_idx then
        M.show_file(first_idx)
    end
    -- The pane focused when the view opens counts as used.
    track_pane()

    setup_pane_sync(state)
end

--- Close the diff view.
function M.close()
    local diff_tabpage = M.state.diff_tabpage
    local original_tabpage = M.state.original_tabpage

    -- Drop the view's autocmds now rather than when their events next fire.
    pcall(vim.api.nvim_del_augroup_by_name, "DifftTreeResize")
    pcall(vim.api.nvim_del_augroup_by_name, "DifftPaneSide")
    pcall(vim.api.nvim_del_augroup_by_name, "DifftPaneSync")

    -- Reset state first
    M.state = {
        current_file_idx = 1,
        files = {},
        range_label = nil,
        range_kind = nil,
        tree_win = nil,
        tree_buf = nil,
        left_win = nil,
        left_buf = nil,
        right_win = nil,
        right_buf = nil,
        original_tabpage = nil,
        diff_tabpage = nil,
        pane_side = nil,
        positions = {},
        shown_path = nil,
        fold_ranges = {},
        fold_closed = nil,
        saved_fold_options = {},
    }

    -- Switch to original tabpage if valid
    if original_tabpage and vim.api.nvim_tabpage_is_valid(original_tabpage) then
        vim.api.nvim_set_current_tabpage(original_tabpage)
    end

    -- Close the diff tabpage
    if diff_tabpage and vim.api.nvim_tabpage_is_valid(diff_tabpage) then
        local tabnr = vim.api.nvim_tabpage_get_number(diff_tabpage)
        vim.cmd("tabclose " .. tabnr)
    end
end

--- Remember the cursor position in the shown file: line, column and the diff pane
--- used last.
function record_position()
    local path = M.state.shown_path
    if not path then
        return
    end
    local side = M.state.pane_side or "head"
    local pane = side == "head" and M.state.right_win or M.state.left_win
    if not (pane and vim.api.nvim_win_is_valid(pane)) then
        return
    end
    local cursor = vim.api.nvim_win_get_cursor(pane)
    M.state.positions[path] = { line = cursor[1], col = cursor[2], side = side }
end

--- Put the cursor at a position in the shown file: line, column and diff pane. Both
--- panes go to the line, as their rows are aligned. When a diff pane has focus,
--- focus moves to the given pane.
--- @param pos table `{ line, col, side }`
local function restore_position(pos)
    local head = pos.side == "head"
    local pane = head and M.state.right_win or M.state.left_win
    local partner = head and M.state.left_win or M.state.right_win
    local buf = head and M.state.right_buf or M.state.left_buf
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
    M.state.pane_side = pos.side
    local current = vim.api.nvim_get_current_win()
    if current == M.state.left_win or current == M.state.right_win then
        vim.api.nvim_set_current_win(pane)
    end
end

--- Move focus to the diff pane used last; the head (right) pane at first.
function M.focus_diff()
    local win = M.state.pane_side == "base" and M.state.left_win or M.state.right_win
    if win and vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_set_current_win(win)
    end
end

--- Give the two diff panes the same width, leaving the tree alone.
function M.equalize_panes()
    local left, right = M.state.left_win, M.state.right_win
    if not (left and right and vim.api.nvim_win_is_valid(left) and vim.api.nvim_win_is_valid(right)) then
        return
    end
    local total = vim.api.nvim_win_get_width(left) + vim.api.nvim_win_get_width(right)
    -- An exact half, kept for later resizes (see setup_pane_sync).
    M.state.pane_ratio = 0.5
    vim.api.nvim_win_set_width(left, math.floor(total / 2))
    M.state.pane_widths = { vim.api.nvim_win_get_width(left), vim.api.nvim_win_get_width(right) }
end

--- Give the side panel its configured width (tree.width); the diff panes keep
--- their ratio.
function M.reset_tree_width()
    local tree_win = M.state.tree_win
    if tree_win and vim.api.nvim_win_is_valid(tree_win) then
        vim.api.nvim_win_set_width(tree_win, M.config.tree.width)
    end
end

--- Act on a double click on a split of the view: the split between the diff panes
--- gives them the same width, the side panel's right border resets its width.
--- The action runs on the next tick.
--- @return boolean handled True when the last mouse event was on one of them
function M.split_double_click()
    local mouse = vim.fn.getmousepos()
    -- A separator belongs to the window on its left, one column past its width.
    local function on_right_border(win)
        return win
            and vim.api.nvim_win_is_valid(win)
            and mouse.winid == win
            and mouse.line == 0
            and mouse.wincol == vim.api.nvim_win_get_width(win) + 1
    end
    if on_right_border(M.state.left_win) then
        vim.schedule(M.equalize_panes)
        return true
    end
    if on_right_border(M.state.tree_win) then
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
    if idx < 1 or idx > #M.state.files then
        return
    end
    record_position()
    M.state.current_file_idx = idx
    local file = M.state.files[idx]
    diff.render(M.state, file)
    fold.render(M.state, file)
    M.state.shown_path = file.path
    local pos = M.state.positions[file.path]
    if not pos then
        -- A file not shown before opens at its first hunk (or its top) in the pane
        -- in use, which is also where <Tab> from the tree goes.
        local first = M.config.scroll_to_first_hunk and diff.hunk_positions[1] or 1
        pos = { line = first, col = 0, side = M.state.pane_side or "head" }
    end
    restore_position(pos)
    tree.highlight_current(M.state)
end

--- Show a file and jump to a specific hunk after rendering completes.
--- @param idx number File index to show
--- @param hunk_fn function Hunk function to call (e.g., diff.first_hunk or diff.last_hunk)
local function show_file_and_jump_to_hunk(idx, hunk_fn)
    M.show_file(idx)
    vim.schedule(function()
        hunk_fn(M.state)
    end)
end

--- Navigate to the next file.
function M.next_file()
    local next_idx = tree.next_file_in_display_order(M.state.current_file_idx)
    if next_idx then
        M.show_file(next_idx)
        return
    end

    local first_idx = tree.first_file_in_display_order()
    if first_idx and first_idx ~= M.state.current_file_idx then
        M.show_file(first_idx)
    end
end

--- Navigate to the previous file.
function M.prev_file()
    local prev_idx = tree.prev_file_in_display_order(M.state.current_file_idx)
    if prev_idx then
        M.show_file(prev_idx)
        return
    end

    local last_idx = tree.last_file_in_display_order()
    if last_idx and last_idx ~= M.state.current_file_idx then
        M.show_file(last_idx)
    end
end

--- Navigate to the next hunk.
--- If hunk_wrap_file is enabled and at the last hunk, wraps to the first hunk of the next file.
--- Otherwise, wraps to the first hunk of the current file.
function M.next_hunk()
    local jumped = diff.next_hunk(M.state)
    if not jumped then
        if M.config.hunk_wrap_file then
            local next_idx = tree.next_file_in_display_order(M.state.current_file_idx)
            if next_idx then
                show_file_and_jump_to_hunk(next_idx, diff.first_hunk)
            else
                -- At last file, wrap to first file
                local first_idx = tree.first_file_in_display_order()
                if first_idx and first_idx ~= M.state.current_file_idx then
                    show_file_and_jump_to_hunk(first_idx, diff.first_hunk)
                end
            end
        else
            -- Wrap within current file
            diff.first_hunk(M.state)
        end
    end
    vim.cmd("normal! zz")
end

--- Navigate to the previous hunk.
--- If hunk_wrap_file is enabled and at the first hunk, wraps to the last hunk of the previous file.
--- Otherwise, wraps to the last hunk of the current file.
function M.prev_hunk()
    local jumped = diff.prev_hunk(M.state)
    if not jumped then
        if M.config.hunk_wrap_file then
            local prev_idx = tree.prev_file_in_display_order(M.state.current_file_idx)
            if prev_idx then
                show_file_and_jump_to_hunk(prev_idx, diff.last_hunk)
            else
                -- At first file, wrap to last file
                local last_idx = tree.last_file_in_display_order()
                if last_idx and last_idx ~= M.state.current_file_idx then
                    show_file_and_jump_to_hunk(last_idx, diff.last_hunk)
                end
            end
        else
            -- Wrap within current file
            diff.last_hunk(M.state)
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
    local aligned = file.aligned_lines and file.aligned_lines[row]

    -- Find the target line number (right side = new version)
    local target_line
    if aligned and aligned[2] then
        -- Direct mapping exists
        target_line = aligned[2] + 1 -- 0-indexed to 1-indexed
    else
        -- Filler line - find nearest non-filler line
        -- Search upward first, then downward
        for offset = 1, #file.aligned_lines do
            -- Check above
            if row - offset >= 1 then
                local above = file.aligned_lines[row - offset]
                if above and above[2] then
                    target_line = above[2] + 1
                    break
                end
            end
            -- Check below
            if row + offset <= #file.aligned_lines then
                local below = file.aligned_lines[row + offset]
                if below and below[2] then
                    target_line = below[2] + 1
                    break
                end
            end
        end
    end

    -- Fallback to line 1 if no mapping found
    target_line = target_line or 1

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
