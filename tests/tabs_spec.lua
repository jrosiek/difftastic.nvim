-- Opening the diff view needs nui.nvim, which plugin managers install next to plenary.
if not pcall(require, "nui.tree") then
    local plenary_dir = vim.api.nvim_get_runtime_file("lua/plenary", false)[1]
    if plenary_dir then
        vim.opt.rtp:append(vim.fn.fnamemodify(plenary_dir, ":h:h:h") .. "/nui.nvim")
    end
end

local difft = require("difftastic-nvim")
local binary = require("difftastic-nvim.binary")

local function record(path)
    return {
        path = path,
        status = "changed",
        language = "Text",
        additions = 1,
        deletions = 1,
        hunk_starts = { 0 },
        aligned_lines = { { 0, 0 } },
        rows = {
            {
                left = { content = "old", highlights = { { start = 0, ["end"] = -1 } }, is_filler = false },
                right = { content = "new", highlights = { { start = 0, ["end"] = -1 } }, is_filler = false },
            },
        },
    }
end

describe("diff state per tab", function()
    local original_get, original_config

    before_each(function()
        original_config = vim.deepcopy(difft.config)
        difft.config.vcs = "git"
        original_get = binary.get
        binary.get = function()
            return {
                run_diff = function(revset)
                    return { files = { record(revset .. ".txt") } }
                end,
            }
        end
    end)

    after_each(function()
        difft.close()
        vim.cmd("silent! tabonly")
        binary.get = original_get
        difft.config = original_config
    end)

    local function autocmds(group)
        local ok, cmds = pcall(vim.api.nvim_get_autocmds, { group = group })
        return ok and cmds or {}
    end

    it("gives each tab its own state, empty in a tab without a diff", function()
        difft.open("HEAD")
        local diff_tab = vim.api.nvim_get_current_tabpage()
        assert.are.equal("HEAD.txt", difft.state.files[1].path)

        vim.cmd("tabnew")
        assert.are.same({}, difft.state.files)
        assert.is_nil(difft.state.tree_win)

        vim.api.nvim_set_current_tabpage(diff_tab)
        assert.are.equal("HEAD.txt", difft.state.files[1].path)
    end)

    it("forgets a diff whose tab is closed with :tabclose", function()
        difft.open("HEAD")
        local diff_tab = vim.api.nvim_get_current_tabpage()
        vim.cmd("tabclose")
        -- Forgotten once Neovim is idle (the closed tab is still valid in TabClosed).
        assert.is_true(vim.wait(1000, function()
            return #autocmds("DifftPaneSync") == 0
        end))
        assert.are.same({}, autocmds("DifftPaneSide"))
        assert.are.same({}, autocmds("DifftTreeResize"))
        assert.is_false(vim.api.nvim_tabpage_is_valid(diff_tab))

        difft.open("HEAD~1")
        assert.are.equal("HEAD~1.txt", difft.state.files[1].path)
    end)

    it("replaces the open diff with a new one, from any tab", function()
        difft.open("HEAD")
        vim.cmd("tabprevious")
        difft.open("HEAD~1")

        assert.are.equal(2, #vim.api.nvim_list_tabpages())
        assert.are.equal("HEAD~1.txt", difft.state.files[1].path)
    end)

    it("closes the open diff when closed from another tab", function()
        difft.open("HEAD")
        vim.cmd("tabprevious")
        difft.close()

        assert.are.equal(1, #vim.api.nvim_list_tabpages())
        assert.are.same({}, autocmds("DifftPaneSync"))
    end)

    for _, splitright in ipairs({ true, false }) do
        it(("lays out panel, base and head left to right (splitright %s)"):format(splitright), function()
            local saved = vim.o.splitright
            vim.o.splitright = splitright
            difft.open("HEAD")
            vim.o.splitright = saved

            local function col(win)
                return vim.api.nvim_win_get_position(win)[2]
            end
            local s = difft.state
            assert.are.equal(0, col(s.tree_win))
            assert.is_true(col(s.tree_win) < col(s.left_win) and col(s.left_win) < col(s.right_win))
            -- The panel is the window the tab opened with (the oldest), so no
            -- window already shown moved.
            local wins = vim.api.nvim_tabpage_list_wins(0)
            table.sort(wins)
            assert.are.equal(wins[1], s.tree_win)
            assert.are.equal(s.right_win, vim.api.nvim_get_current_win())
        end)
    end

    describe("with multiple_diffs", function()
        before_each(function()
            difft.config.multiple_diffs = true
        end)

        after_each(function()
            -- Close every diff left open, from its own tab.
            for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
                if vim.api.nvim_tabpage_is_valid(tab) then
                    vim.api.nvim_set_current_tabpage(tab)
                    difft.close()
                end
            end
        end)

        it("opens each diff in a tab of its own, from a diff tab too", function()
            difft.open("HEAD")
            local first = vim.api.nvim_get_current_tabpage()
            difft.open("HEAD~1")
            local second = vim.api.nvim_get_current_tabpage()

            assert.are_not.equal(first, second)
            assert.are.equal(3, #vim.api.nvim_list_tabpages())
            assert.are.equal("HEAD~1.txt", difft.state.files[1].path)
            vim.api.nvim_set_current_tabpage(first)
            assert.are.equal("HEAD.txt", difft.state.files[1].path)
            assert.is_true(vim.api.nvim_win_is_valid(difft.state.tree_win))
        end)

        it("goes to the tab of a revset already open", function()
            difft.open("HEAD")
            local first = vim.api.nvim_get_current_tabpage()
            difft.open("HEAD~1")
            difft.open("HEAD")

            assert.are.equal(first, vim.api.nvim_get_current_tabpage())
            assert.are.equal(3, #vim.api.nvim_list_tabpages())
        end)

        it("closes only the current tab's diff", function()
            difft.open("HEAD")
            local first = vim.api.nvim_get_current_tabpage()
            difft.open("HEAD~1")
            difft.close()

            assert.are.equal(2, #vim.api.nvim_list_tabpages())
            -- Back in the tab the closed diff was opened from: the first diff.
            assert.are.equal(first, vim.api.nvim_get_current_tabpage())
            assert.are.equal("HEAD.txt", difft.state.files[1].path)
            assert.is_true(#autocmds("DifftPaneSync") > 0)
        end)

        it("closes nothing from a tab without a diff", function()
            difft.open("HEAD")
            vim.cmd("tabprevious")
            difft.close()

            assert.are.equal(2, #vim.api.nvim_list_tabpages())
        end)

        it("keeps each diff's panel and files apart when switching files", function()
            binary.get = function()
                return {
                    run_diff = function(revset)
                        return { files = { record(revset .. "-a.txt"), record(revset .. "-b.txt") } }
                    end,
                }
            end
            difft.open("HEAD")
            local first = vim.api.nvim_get_current_tabpage()
            difft.open("HEAD~1")
            difft.next_file()
            assert.are.equal("HEAD~1-b.txt", difft.state.shown_path)

            vim.api.nvim_set_current_tabpage(first)
            assert.are.equal("HEAD-a.txt", difft.state.shown_path)
            difft.next_file()
            assert.are.equal("HEAD-b.txt", difft.state.shown_path)
        end)
    end)
end)
