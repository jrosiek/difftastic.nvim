--- Highlight group definitions.
local M = {}

--- Opacity of the neutral blend behind the panel's current row (0-1)
M.neutral_opacity = 0.38
--- Opacity of the comment colour that fillers are drawn in, over the
--- background (0-1)
M.filler_opacity = 0.3
--- Opacity of the added/removed backgrounds of changed text (0-1); soft enough
--- for dim text such as comments to stay readable on them
M.bg_opacity = 0.137
--- Opacity of the lighter backgrounds of whole changed lines (0-1)
M.line_bg_opacity = 0.0475

--- Blend two colors with a given alpha.
--- @param fg string Foreground hex color (e.g., "#ff0000")
--- @param bg string Background hex color
--- @param alpha number Blend factor (0 = all bg, 1 = all fg)
--- @return string Blended hex color
local function blend(fg, bg, alpha)
    local function hex_to_rgb(hex)
        hex = hex:gsub("#", "")
        return tonumber(hex:sub(1, 2), 16), tonumber(hex:sub(3, 4), 16), tonumber(hex:sub(5, 6), 16)
    end

    local fg_r, fg_g, fg_b = hex_to_rgb(fg)
    local bg_r, bg_g, bg_b = hex_to_rgb(bg)

    local r = math.floor(fg_r * alpha + bg_r * (1 - alpha))
    local g = math.floor(fg_g * alpha + bg_g * (1 - alpha))
    local b = math.floor(fg_b * alpha + bg_b * (1 - alpha))

    return string.format("#%02x%02x%02x", r, g, b)
end

--- The global definition of a highlight group, links followed.
---
--- The obvious read, `nvim_get_hl(0, { name = name, link = false })`, is not
--- global: resolving the final group goes through the current window's
--- 'winhighlight' (a window highlight namespace). With the side panel current,
--- whose 'winhighlight' maps Normal to DifftTreeNormal, it returns that
--- background-only group for `Normal`, and colours derived from it are wrong
--- (seen on Neovim 0.11.5). The same happens with `create = false` and with
--- `synIDattr(synIDtrans(hlID(name)), ...)`; `nvim_set_hl_ns(0)` around the
--- read does not help, as the active namespace already is 0. A read without
--- `link = false` returns the raw global entry (a link stays a link), so links
--- are followed here one step at a time.
--- @param name string Highlight group name
--- @return table
local function global_hl(name)
    for _ = 1, 100 do
        local hl = vim.api.nvim_get_hl(0, { name = name })
        if not hl.link then
            return hl
        end
        name = hl.link
    end
    return {}
end

--- Get the foreground color from a highlight group.
--- @param name string Highlight group name
--- @return string|nil Hex color or nil
local function get_fg(name)
    local hl = global_hl(name)
    if hl.fg then
        return string.format("#%06x", hl.fg)
    end
    return nil
end

--- Get the background color from Normal or fallback.
--- @return string Hex color
local function get_normal_bg()
    local hl = global_hl("Normal")
    if hl.bg then
        return string.format("#%06x", hl.bg)
    end
    return "#1a1b26" -- fallback dark background
end

--- Linked highlight definitions (inherit from colorscheme)
--- @type table<string, vim.api.keyset.highlight>
M.linked = {
    -- Tree highlights
    DifftFileAdded = { link = "Added" },
    DifftFileDeleted = { link = "Removed" },
    DifftDirectory = { link = "Directory" },
    DifftTreeDirectory = { link = "Directory" },
    DifftTreeAdded = { link = "Added" },
    DifftTreeDeleted = { link = "Removed" },
    DifftTreeModified = { link = "Changed" },
    DifftTreeRenamed = { link = "Directory" },
    DifftTreeReviewed = { link = "Added" },
    DifftTreeUnvisited = { link = "Directory" },
    DifftTreeRange = { link = "BlueItalic" },
    DifftDiffTitle = { link = "Title" },

    -- Picker text highlights
    DifftPickerJjIconCurrent = { link = "Added" },
    DifftPickerJjIconImmutable = { link = "Removed" },
    DifftPickerJjIconNormal = { link = "Directory" },
    DifftPickerJjRevset = { link = "Identifier" },
    DifftPickerJjAge = { link = "Comment" },
}


--- Apply all highlight groups.
--- @param overrides table<string, vim.api.keyset.highlight> User overrides
--- The theme colours the derived groups were last made from.
local derived_from = nil

--- The theme colours the derived groups are made from, as one comparable string.
local function source_colors()
    local plugin = package.loaded["difftastic-nvim"]
    local accent = plugin and plugin.config and plugin.config.fold_accent or "Directory"
    local parts = {}
    for _, name in ipairs({ "Normal", "Comment", "Added", "Removed", "Changed", "Identifier", "Directory", accent }) do
        local hl = global_hl(name)
        table.insert(parts, tostring(hl.fg) .. "/" .. tostring(hl.bg))
    end
    return table.concat(parts, ",")
end

local function apply_highlights(overrides)
    derived_from = source_colors()
    -- Setup linked highlights
    for name, default in pairs(M.linked) do
        local hl = vim.tbl_extend("force", default, overrides[name] or {})
        vim.api.nvim_set_hl(0, name, hl)
    end

    -- Setup derived highlights
    local normal_bg = get_normal_bg()
    local normal_fg = get_fg("Normal") or "#c0caf5"
    local comment_fg = get_fg("Comment") or "#565f89"
    -- Secondary text (a subtitle, a directory): text blended into the background,
    -- readable with any theme (some give NonText the background colour itself).
    local muted_fg = blend(normal_fg, normal_bg, 0.45)
    local added_fg = get_fg("Added") or "#9ece6a"
    local removed_fg = get_fg("Removed") or "#f7768e"
    local changed_fg = get_fg("Changed") or get_fg("Identifier") or "#7aa2f7"
    -- Closed folds take their colour from the group named by fold_accent.
    local plugin = package.loaded["difftastic-nvim"]
    local fold_accent = plugin and plugin.config and plugin.config.fold_accent or "Directory"
    local accent_fg = get_fg(fold_accent) or get_fg("Directory") or "#7aa2f7"

    local added_bg = blend(added_fg, normal_bg, M.bg_opacity)
    local removed_bg = blend(removed_fg, normal_bg, M.bg_opacity)
    local added_line_bg = blend(added_fg, normal_bg, M.line_bg_opacity)
    local removed_line_bg = blend(removed_fg, normal_bg, M.line_bg_opacity)
    local normal_blend = blend(normal_fg, normal_bg, M.neutral_opacity)
    local tree_cursor_bg = blend(normal_fg, normal_bg, 0.14)
    local tree_panel_bg = blend(normal_fg, normal_bg, 0.03)

    local derived = {
        -- Background highlights (blended from fg colors)
        -- Changed text: a background and an underline in the added/removed colour
        -- half blended into the background (in the text's own colour where
        -- terminals draw no underline colours).
        DifftAdded = { bg = added_bg, underline = true, sp = blend(added_fg, normal_bg, 0.5) },
        DifftRemoved = { bg = removed_bg, underline = true, sp = blend(removed_fg, normal_bg, 0.5) },
        DifftAddedLine = { bg = added_line_bg },
        DifftRemovedLine = { bg = removed_line_bg },
        DifftTreeCurrent = { bg = normal_blend, bold = true },
        DifftTreeNormal = { bg = tree_panel_bg },
        DifftDiffSubtitle = { fg = muted_fg },
        DifftBarMuted = { fg = muted_fg },
        -- The bars on top of the side panel and the diff panes share the panel's
        -- background and are underlined in its frame colour; the text of an
        -- unfocused window's bar is dimmed.
        DifftBar = { fg = normal_fg, bg = tree_panel_bg, underline = true, sp = comment_fg },
        DifftBarNC = { fg = blend(normal_fg, normal_bg, 0.6), bg = tree_panel_bg, underline = true, sp = comment_fg },
        -- The rules of the side panel's header, drawn like the bars' underlines:
        -- in the frame colour where terminals support underline colours, else in
        -- the unfocused bars' text colour.
        DifftTreeRule = { fg = blend(normal_fg, normal_bg, 0.6), underline = true, sp = comment_fg },
        -- The percentage done in the loading window's bar.
        DifftLoadingDone = { fg = accent_fg, underline = true, sp = accent_fg },
        DifftTreeCursorLine = { bg = tree_cursor_bg },
        DifftTreeEndOfBuffer = { fg = tree_panel_bg, bg = tree_panel_bg },
        DifftTreeMuted = { fg = comment_fg },
        DifftTreeIndent = { fg = comment_fg },
        DifftTreeChevron = { fg = comment_fg },
        DifftTreeFile = { fg = normal_fg },
        DifftTreePathMuted = { fg = comment_fg },
        DifftTreeRange = { fg = changed_fg, italic = true },
        DifftTreeModified = { fg = changed_fg, bold = true },
        DifftPickerPreviewHover = { bg = normal_blend, bold = true },
        DifftPickerJjDesc = { fg = normal_fg },
        -- Foreground highlights
        DifftAddedFg = { fg = added_fg, bold = true },
        DifftRemovedFg = { fg = removed_fg, bold = true },
        DifftFiller = { fg = blend(comment_fg, normal_bg, M.filler_opacity) },
        -- A faint band of the accent colour across a closed fold, with text in
        -- the accent colour half blended into the background.
        DifftFold = { fg = blend(accent_fg, normal_bg, 0.5), bg = blend(accent_fg, normal_bg, 0.09) },
    }

    for name, default in pairs(derived) do
        local hl = vim.tbl_extend("force", default, overrides[name] or {})
        vim.api.nvim_set_hl(0, name, hl)
    end
end

--- Overrides given to setup(), reused whenever the groups are derived again.
local current_overrides = nil

--- Derive the highlight groups again from the current colours. Some theme loaders
--- set the colours without a ColorScheme event, after setup() ran (NvChad applies
--- its theme from precompiled files once plugins are set up), which would leave
--- the derived groups blended from Neovim's default theme.
function M.refresh()
    if current_overrides then
        apply_highlights(current_overrides)
    end
end

--- Setup highlight groups with optional overrides.
--- @param overrides table<string, vim.api.keyset.highlight>|nil User overrides
function M.setup(overrides)
    overrides = overrides or {}
    current_overrides = overrides

    -- Apply highlights now
    apply_highlights(overrides)

    -- Reapply when the colorscheme or background mode changes
    vim.api.nvim_create_autocmd("ColorScheme", {
        group = vim.api.nvim_create_augroup("DifftHighlights", { clear = true }),
        callback = function()
            apply_highlights(overrides)
        end,
    })
    vim.api.nvim_create_autocmd("OptionSet", {
        group = vim.api.nvim_create_augroup("DifftHighlightOptions", { clear = true }),
        pattern = "background",
        callback = function()
            apply_highlights(overrides)
        end,
    })
    local function refresh_if_changed()
        if source_colors() ~= derived_from then
            apply_highlights(overrides)
        end
    end
    -- NvChad specific: its theme switcher (base46's load_all_highlights, used by
    -- the `<leader>th` picker) sets the colours directly, without a ColorScheme
    -- event, and then fires `User NvThemeReload`.
    -- NvChad bug: while the picker is open, `Normal` still holds the previous
    -- theme's colours when that event fires (switching ayu_dark -> ayu_light,
    -- Normal's background was ayu_dark's #14171d during the event). The new
    -- colours arrive after it, and the final ones only once the picker closes.
    -- Deriving on the event alone therefore left the groups one theme behind.
    -- So the groups are derived on the next tick instead, and once more when
    -- the picker closes and another window is entered (see WinEnter below).
    -- Without NvChad nothing fires that event, so this autocmd never runs.
    vim.api.nvim_create_autocmd("User", {
        group = vim.api.nvim_create_augroup("DifftHighlightsNvChad", { clear = true }),
        pattern = "NvThemeReload",
        callback = function()
            vim.schedule(refresh_if_changed)
        end,
    })
    -- Any theme change made without an event (NvChad's picker settling, other
    -- loaders) shows by the next window switch: derive the groups again if the
    -- theme colours differ from the ones they were made from.
    vim.api.nvim_create_autocmd("WinEnter", {
        group = vim.api.nvim_create_augroup("DifftHighlightsCheck", { clear = true }),
        callback = refresh_if_changed,
    })
    -- Once the whole config has run, in case its theme was applied after setup()
    -- without a ColorScheme event.
    if vim.v.vim_did_enter == 0 then
        vim.api.nvim_create_autocmd("VimEnter", {
            group = vim.api.nvim_create_augroup("DifftHighlightsStartup", { clear = true }),
            once = true,
            callback = M.refresh,
        })
    end
end

return M
