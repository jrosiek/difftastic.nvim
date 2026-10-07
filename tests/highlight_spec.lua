-- Opening the diff view needs nui.nvim, which plugin managers install next to plenary.
if not pcall(require, "nui.tree") then
    local plenary_dir = vim.api.nvim_get_runtime_file("lua/plenary", false)[1]
    if plenary_dir then
        vim.opt.rtp:append(vim.fn.fnamemodify(plenary_dir, ":h:h:h") .. "/nui.nvim")
    end
end

local difft = require("difftastic-nvim")
local binary = require("difftastic-nvim.binary")
local highlight = require("difftastic-nvim.highlight")

--- Groups the plugin derives from the theme's colours (not plain links).
local function derived_groups()
    local groups = {}
    for _, name in ipairs(vim.fn.getcompletion("Difft", "highlight")) do
        local hl = vim.api.nvim_get_hl(0, { name = name })
        if not hl.link and not highlight.linked[name] then
            groups[name] = hl
        end
    end
    return groups
end

local function hex(n)
    return n and ("#%06x"):format(n) or nil
end

--- Applies a theme the way NvChad does: plain nvim_set_hl calls, no ColorScheme.
local function apply_theme(normal_fg, normal_bg, comment_fg)
    vim.api.nvim_set_hl(0, "Normal", { fg = normal_fg, bg = normal_bg })
    vim.api.nvim_set_hl(0, "Comment", { fg = comment_fg })
end

describe("derived highlight groups", function()
    local original_get, saved

    before_each(function()
        saved = {
            Normal = vim.api.nvim_get_hl(0, { name = "Normal" }),
            Comment = vim.api.nvim_get_hl(0, { name = "Comment" }),
        }
        difft.config.vcs = "git"
        original_get = binary.get
        binary.get = function()
            return {
                run_diff = function()
                    return {
                        files = {
                            {
                                path = "a.txt",
                                status = "changed",
                                language = "Text",
                                additions = 1,
                                deletions = 1,
                                hunk_starts = { 0 },
                                aligned_lines = {},
                                rows = {
                                    {
                                        left = { content = "a", highlights = { { start = 0, ["end"] = -1 } }, is_filler = false },
                                        right = { content = "b", highlights = { { start = 0, ["end"] = -1 } }, is_filler = false },
                                    },
                                },
                            },
                        },
                    }
                end,
            }
        end
        -- Start from Neovim-default-like colours, as at plugin setup time.
        apply_theme("#e0e2ea", "#14161b", "#9b9ea4")
        highlight.setup({})
    end)

    after_each(function()
        difft.close()
        binary.get = original_get
        vim.api.nvim_set_hl(0, "Normal", saved.Normal)
        vim.api.nvim_set_hl(0, "Comment", saved.Comment)
        highlight.setup({})
    end)

    it("are blended from the theme seen at setup", function()
        assert.are.equal("#9b9ea4", hex(vim.api.nvim_get_hl(0, { name = "DifftTreeMuted" }).fg))
    end)

    it("follow a theme applied without a ColorScheme event once a diff view opens", function()
        local before = derived_groups()
        apply_theme("#f8f8f2", "#272822", "#555650")
        assert.are.same(before, derived_groups(), "changed before the view opened")

        difft.open("HEAD")

        local after_open = derived_groups()
        assert.are.equal("#555650", hex(after_open.DifftTreeMuted.fg))
        -- Every derived group matches a full re-derivation (as on ColorScheme).
        vim.api.nvim_exec_autocmds("ColorScheme", {})
        assert.are.same(derived_groups(), after_open)
        assert.are_not.same(before.DifftTreeNormal, after_open.DifftTreeNormal)
        assert.are_not.same(before.DifftAdded, after_open.DifftAdded)
    end)

    it("keep the overrides given to setup()", function()
        highlight.setup({ DifftFold = { fg = "#123456" }, DifftTreeTitle = { fg = "#abcdef", bold = false } })
        apply_theme("#f8f8f2", "#272822", "#555650")

        difft.open("HEAD")

        assert.are.equal("#123456", hex(vim.api.nvim_get_hl(0, { name = "DifftFold" }).fg))
        local title = vim.api.nvim_get_hl(0, { name = "DifftTreeTitle" })
        assert.are.equal("#abcdef", hex(title.fg))
        assert.is_nil(title.bold)
        -- Groups without an override still follow the new theme.
        assert.are.equal("#555650", hex(vim.api.nvim_get_hl(0, { name = "DifftTreeMuted" }).fg))
    end)

    it("colour closed folds from the fold_accent group", function()
        vim.api.nvim_set_hl(0, "DifftTestAccent", { fg = "#ff8800" })
        local original = difft.config.fold_accent
        difft.config.fold_accent = "DifftTestAccent"

        difft.open("HEAD")
        local fold = vim.api.nvim_get_hl(0, { name = "DifftFold" })
        difft.config.fold_accent = original

        assert.are.equal("#ff8800", hex(fold.fg))
        -- The band blends that colour into the background.
        assert.are_not.equal(hex(fold.bg), hex(vim.api.nvim_get_hl(0, { name = "Normal" }).bg))
    end)

    it("fall back to Directory when the fold_accent group has no colour", function()
        local original = difft.config.fold_accent
        difft.config.fold_accent = "DifftNoSuchGroup"

        difft.open("HEAD")
        local fold = vim.api.nvim_get_hl(0, { name = "DifftFold" })
        difft.config.fold_accent = original

        assert.are.equal(vim.api.nvim_get_hl(0, { name = "Directory", link = false }).fg, fold.fg)
    end)

    it("keep linked groups as links", function()
        local links = {}
        for name in pairs(highlight.linked) do
            links[name] = vim.api.nvim_get_hl(0, { name = name }).link
        end
        apply_theme("#f8f8f2", "#272822", "#555650")

        difft.open("HEAD")

        for name, link in pairs(links) do
            assert.are.equal(link, vim.api.nvim_get_hl(0, { name = name }).link, name)
        end
    end)
end)

describe("derived highlight groups at startup", function()
    it("follow a theme the config applies after setup(), without a ColorScheme event", function()
        local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
        -- --cmd runs before the -c commands, which run before VimEnter: setup() sees
        -- the default theme, then the "config" applies its theme silently.
        local child = vim.fn.jobstart({
            "nvim",
            "--clean",
            "--headless",
            "--embed",
            "--cmd",
            "set rtp^=" .. root,
            "--cmd",
            "lua require('difftastic-nvim.highlight').setup({})",
            "-c",
            "lua vim.api.nvim_set_hl(0, 'Normal', { fg = '#f8f8f2', bg = '#272822' }); vim.api.nvim_set_hl(0, 'Comment', { fg = '#555650' })",
        }, { rpc = true })
        local fold = vim.rpcrequest(child, "nvim_exec_lua", "return vim.api.nvim_get_hl(0, { name = 'DifftTreeMuted' }).fg", {})
        vim.fn.jobstop(child)

        assert.are.equal("#555650", hex(fold))
    end)
end)
