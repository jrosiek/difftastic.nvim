--- The bars at the top of the side panel (how the shown file changed) and of
--- each diff pane (the file on that side).

-- Opening the diff view needs nui.nvim, which plugin managers install next to plenary.
if not pcall(require, "nui.tree") then
    local plenary_dir = vim.api.nvim_get_runtime_file("lua/plenary", false)[1]
    if plenary_dir then
        vim.opt.rtp:append(vim.fn.fnamemodify(plenary_dir, ":h:h:h") .. "/nui.nvim")
    end
end

local difft = require("difftastic-nvim")
local binary = require("difftastic-nvim.binary")

local function file_record(path, status, extra)
    return vim.tbl_extend("force", {
        path = path,
        status = status,
        language = "Text",
        additions = 1,
        deletions = 1,
        hunk_starts = { 0 },
        aligned_lines = { { 0, 0 } },
        rows = {
            {
                left = { content = "old", highlights = {}, is_filler = false },
                right = { content = "new", highlights = {}, is_filler = false },
            },
        },
    }, extra or {})
end

describe("view bars", function()
    local original_get

    before_each(function()
        vim.o.columns = 200
        difft.config.vcs = "git"
        original_get = binary.get
        binary.get = function()
            return {
                run_diff = function()
                    return {
                        files = {
                            file_record("a.txt", "changed"),
                            file_record("new.txt", "created", { deletions = 0 }),
                            file_record("gone.txt", "deleted", { additions = 0 }),
                            file_record("renamed%.txt", "created", { moved_from = "old%.txt" }),
                        },
                    }
                end,
            }
        end
        difft.open("HEAD")
    end)

    after_each(function()
        difft.close()
        binary.get = original_get
    end)

    --- The bars of the side panel and both panes for the file at `path`, as
    --- shown (statusline items evaluated, highlights dropped).
    local function bars(path)
        for i, file in ipairs(difft.state.files) do
            if file.path == path then
                difft.show_file(i)
            end
        end
        local function text(win)
            if not (win and vim.api.nvim_win_is_valid(win)) then
                return "(no pane)"
            end
            local opts = { winid = win, use_winbar = true, maxwidth = vim.api.nvim_win_get_width(win) }
            return vim.trim((vim.api.nvim_eval_statusline(vim.wo[win].winbar, opts).str:gsub("%s+", " ")))
        end
        return { text(difft.state.tree_win), text(difft.state.left_win), text(difft.state.right_win) }
    end

    it("shows the status in the panel, right-aligned, and the file in both panes", function()
        assert.are.same({ "● modified", "a.txt -1", "a.txt +1" }, bars("a.txt"))
        local win = difft.state.tree_win
        local shown = vim.api.nvim_eval_statusline(vim.wo[win].winbar, { winid = win, use_winbar = true, maxwidth = 30 }).str
        assert.are.equal(string.rep(" ", 30 - vim.fn.strdisplaywidth("● modified ")) .. "● modified ", shown)
    end)

    it("shows the old path in the base pane of a renamed file", function()
        assert.are.same({ "➜ renamed", "old%.txt -1", "renamed%.txt +1" }, bars("renamed%.txt"))
    end)

    it("shows the one pane of a file with one side", function()
        assert.are.same({ "+ added", "(no pane)", "new.txt +1" }, bars("new.txt"))
        assert.are.same({ "- deleted", "gone.txt -1", "(no pane)" }, bars("gone.txt"))
    end)

    it("colours the status and the counts like the tree", function()
        bars("a.txt")
        local pane_bar = require("difftastic-nvim.diff").pane_bar
        assert.truthy(vim.api.nvim_win_call(difft.state.tree_win, require("difftastic-nvim.diff").panel_bar):find("%#DifftTreeModified#", 1, true))
        assert.truthy(vim.api.nvim_win_call(difft.state.left_win, pane_bar):find("%#DifftFileDeleted#-1", 1, true))
        assert.truthy(vim.api.nvim_win_call(difft.state.right_win, pane_bar):find("%#DifftFileAdded#+1", 1, true))
    end)

    it("gives up the directory, then the count, then the file name as the pane narrows", function()
        local file = file_record("lua/difftastic-nvim/tree.lua", "changed", { additions = 12 })
        difft.state.files[1] = file
        difft.show_file(1)
        local win = difft.state.right_win
        local function at(width)
            vim.api.nvim_win_set_width(win, width)
            return vim.api.nvim_eval_statusline(vim.wo[win].winbar, { winid = win, use_winbar = true, maxwidth = width }).str
        end
        local function row(text, width)
            -- Left part, filler, right part, each with the one-cell margins.
            return text .. string.rep(" ", width - vim.fn.strdisplaywidth(text) - 5) .. " +12 "
        end
        assert.are.equal(row(" tree.lua  lua/difftastic-nvim", 40), at(40))
        -- The directory is cut from its left; the count stays.
        assert.are.equal(row(" tree.lua  …-nvim", 22), at(22))
        assert.are.equal(row(" tree.lua  …m", 18), at(18))
        -- No room for a cut directory: left out, the count stays.
        assert.are.equal(" tree.lua  +12 ", at(15))
        assert.are.equal(" tree.lua +12 ", at(14))
        -- Then the count goes, and only then is the name cut.
        assert.are.equal(" tree.lua ", at(10))
        assert.are.equal(" tree.l… ", at(9))
        -- Never wider than the pane, so Neovim never cuts it with "<".
        assert.are.equal(" t… ", at(4))
        assert.are.equal(" … ", at(3))
        assert.are.equal("  ", at(2))
        assert.are.equal(" ", at(1))
    end)

    it("cuts the panel's status with an ellipsis in a narrow panel", function()
        bars("a.txt")
        local win = difft.state.tree_win
        vim.api.nvim_win_set_width(win, 7)
        local shown = vim.api.nvim_eval_statusline(vim.wo[win].winbar, { winid = win, use_winbar = true, maxwidth = 7 }).str
        assert.are.equal("● mod… ", shown)
        for width, expected in pairs({ [3] = "●… ", [2] = "… ", [1] = " " }) do
            vim.api.nvim_win_set_width(win, width)
            local r = vim.api.nvim_eval_statusline(vim.wo[win].winbar, { winid = win, use_winbar = true, maxwidth = width })
            assert.are.equal(expected, r.str)
        end
    end)

    it("says in the panel when a file was compared line by line", function()
        local file = file_record("a.txt", "changed", { text_fallback = true })
        difft.state.files[1] = file
        difft.show_file(1)
        local win = difft.state.tree_win
        local function at(width)
            vim.api.nvim_win_set_width(win, width)
            return vim.api.nvim_eval_statusline(vim.wo[win].winbar, { winid = win, use_winbar = true, maxwidth = width }).str
        end
        -- On the left, the status on the right.
        local wide = at(40)
        assert.truthy(wide:match("^ ≡ line by line +● modified $"), wide)
        assert.are.equal(40, vim.fn.strdisplaywidth(wide))
        -- Left out first when the panel is narrow.
        assert.are.equal(27, vim.fn.strdisplaywidth(at(27)))
        assert.truthy(at(27):match("^ +● modified $"), at(27))
        local pane_bar = require("difftastic-nvim.diff").panel_bar
        vim.api.nvim_win_set_width(win, 40)
        assert.truthy(vim.api.nvim_win_call(win, pane_bar):find("%#DifftBarMuted#≡ line by line", 1, true))
    end)

    it("has the side panel's background and an underline, also with folds", function()
        -- Folds are on by default.
        bars("a.txt")
        for _, win in ipairs({ difft.state.tree_win, difft.state.left_win, difft.state.right_win }) do
            local winhl = vim.wo[win].winhighlight
            assert.truthy(winhl:find("WinBar:DifftBar", 1, true), winhl)
            assert.truthy(winhl:find("WinBarNC:DifftBarNC", 1, true), winhl)
        end
        require("difftastic-nvim.highlight").setup()
        local panel = vim.api.nvim_get_hl(0, { name = "DifftTreeNormal" }).bg
        assert.is_number(panel)
        -- The frame colour: the theme's comment colour, as the tree's muted text.
        local frame = vim.api.nvim_get_hl(0, { name = "DifftTreeMuted" }).fg
        for _, name in ipairs({ "DifftBar", "DifftBarNC" }) do
            local hl = vim.api.nvim_get_hl(0, { name = name })
            assert.are.equal(panel, hl.bg)
            -- Underlined in the panel's frame colour.
            assert.is_true(hl.underline)
            assert.are.equal(frame, hl.sp)
        end
    end)
end)

describe("view buffer names", function()
    local original_get

    before_each(function()
        vim.o.columns = 200
        difft.config.vcs = "git"
        original_get = binary.get
        binary.get = function()
            return {
                run_diff = function()
                    return {
                        files = {
                            file_record("lua/a.txt", "changed"),
                            file_record("lua/renamed.txt", "created", { moved_from = "lua/old.txt" }),
                            file_record("new.txt", "created", { deletions = 0 }),
                        },
                    }
                end,
            }
        end
        difft.open("HEAD")
    end)

    after_each(function()
        difft.close()
        binary.get = original_get
    end)

    local function names()
        local s = difft.state
        return {
            vim.api.nvim_buf_get_name(s.tree_buf),
            vim.api.nvim_buf_get_name(s.left_buf),
            vim.api.nvim_buf_get_name(s.right_buf),
        }
    end

    it("names the panel and the panes after the tab and the file on each side", function()
        local s = difft.state
        local prefix = "difftastic://" .. s.diff_tabpage .. "/"
        local buffers = #vim.api.nvim_list_bufs()

        difft.show_file(1)
        assert.are.same({ prefix .. "panel", prefix .. "base/lua/a.txt", prefix .. "head/lua/a.txt" }, names())
        difft.show_file(2)
        assert.are.same({ prefix .. "panel", prefix .. "base/lua/old.txt", prefix .. "head/lua/renamed.txt" }, names())
        -- An added file has no base side; its pane is closed meanwhile.
        difft.show_file(3)
        assert.are.same({ prefix .. "panel", prefix .. "base", prefix .. "head/new.txt" }, names())
        -- Renaming leaves no buffers behind, and the buffers stay unsaved scratch.
        assert.are.equal(buffers, #vim.api.nvim_list_bufs())
        assert.are.equal("nofile", vim.bo[s.right_buf].buftype)
    end)

    it("keeps two tabs showing the same file apart", function()
        difft.config.multiple_diffs = true
        local first = names()
        difft.open("HEAD~1")
        local second = names()
        difft.config.multiple_diffs = false
        assert.are_not.equal(first[3], second[3])
        assert.are.equal(first[3]:gsub("^difftastic://%d+/", ""), second[3]:gsub("^difftastic://%d+/", ""))
        difft.close()
    end)
end)
