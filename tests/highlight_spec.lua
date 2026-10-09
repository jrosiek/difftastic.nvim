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
        highlight.setup({ DifftFold = { fg = "#123456" }, DifftTreeCurrent = { fg = "#abcdef", bold = false } })
        apply_theme("#f8f8f2", "#272822", "#555650")

        difft.open("HEAD")

        assert.are.equal("#123456", hex(vim.api.nvim_get_hl(0, { name = "DifftFold" }).fg))
        local current = vim.api.nvim_get_hl(0, { name = "DifftTreeCurrent" })
        assert.are.equal("#abcdef", hex(current.fg))
        assert.is_nil(current.bold)
        -- Groups without an override still follow the new theme.
        assert.are.equal("#555650", hex(vim.api.nvim_get_hl(0, { name = "DifftTreeMuted" }).fg))
    end)

    --- `color` half blended into the Normal background, as the fold text is.
    local function half_to_background(color)
        local bg = vim.api.nvim_get_hl(0, { name = "Normal" }).bg or 0x1a1b26
        local result = 0
        for shift = 16, 0, -8 do
            local c, b = math.floor(color / 2 ^ shift) % 256, math.floor(bg / 2 ^ shift) % 256
            result = result * 256 + math.floor(c * 0.5 + b * 0.5)
        end
        return result
    end

    it("colour closed folds from the fold_accent group", function()
        vim.api.nvim_set_hl(0, "DifftTestAccent", { fg = "#ff8800" })
        local original = difft.config.fold_accent
        difft.config.fold_accent = "DifftTestAccent"

        difft.open("HEAD")
        local fold = vim.api.nvim_get_hl(0, { name = "DifftFold" })
        difft.config.fold_accent = original

        assert.are.equal(hex(half_to_background(0xff8800)), hex(fold.fg))
        -- The band blends that colour into the background.
        assert.are_not.equal(hex(fold.bg), hex(vim.api.nvim_get_hl(0, { name = "Normal" }).bg))
    end)

    it("fall back to Directory when the fold_accent group has no colour", function()
        local original = difft.config.fold_accent
        difft.config.fold_accent = "DifftNoSuchGroup"

        difft.open("HEAD")
        local fold = vim.api.nvim_get_hl(0, { name = "DifftFold" })
        difft.config.fold_accent = original

        assert.are.equal(half_to_background(vim.api.nvim_get_hl(0, { name = "Directory", link = false }).fg), fold.fg)
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

describe("derived highlight groups with NvChad", function()
    it("follow a theme NvChad switches to (User NvThemeReload, no ColorScheme)", function()
        local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
        local child = vim.fn.jobstart({
            "nvim",
            "--clean",
            "--headless",
            "--embed",
            "--cmd",
            "set rtp^=" .. root,
        }, { rpc = true })
        local function remote(code)
            return vim.rpcrequest(child, "nvim_exec_lua", code, {})
        end
        remote("require('difftastic-nvim.highlight').setup({})")
        -- base46 sets the groups directly, then fires its own event.
        remote("vim.api.nvim_set_hl(0, 'Normal', { fg = '#f8f8f2', bg = '#272822' }); vim.api.nvim_set_hl(0, 'Comment', { fg = '#555650' })")
        local before = remote("return vim.api.nvim_get_hl(0, { name = 'DifftTreeMuted' }).fg")
        remote("vim.api.nvim_exec_autocmds('User', { pattern = 'NvThemeReload' })")
        -- Derived on the next tick.
        remote("vim.wait(50)")
        local after = remote("return vim.api.nvim_get_hl(0, { name = 'DifftTreeMuted' }).fg")
        vim.fn.jobstop(child)

        assert.are_not.equal("#555650", hex(before))
        assert.are.equal("#555650", hex(after))
    end)

    it("catch up on the next window switch with colours set after the event", function()
        local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
        local child = vim.fn.jobstart({ "nvim", "--clean", "--headless", "--embed", "--cmd", "set rtp^=" .. root }, { rpc = true })
        local function remote(code)
            return vim.rpcrequest(child, "nvim_exec_lua", code, {})
        end
        remote("require('difftastic-nvim.highlight').setup({}); vim.cmd('vsplit')")
        -- The event fires while the old colours are still in place (NvChad's
        -- picker), the new ones arrive afterwards.
        remote("vim.api.nvim_exec_autocmds('User', { pattern = 'NvThemeReload' }); vim.wait(50)")
        remote("vim.api.nvim_set_hl(0, 'Normal', { fg = '#f8f8f2', bg = '#272822' }); vim.api.nvim_set_hl(0, 'Comment', { fg = '#555650' })")
        local stale = remote("return vim.api.nvim_get_hl(0, { name = 'DifftTreeMuted' }).fg")
        remote("vim.cmd('wincmd w')")
        local fresh = remote("return vim.api.nvim_get_hl(0, { name = 'DifftTreeMuted' }).fg")
        vim.fn.jobstop(child)

        assert.are_not.equal("#555650", hex(stale))
        assert.are.equal("#555650", hex(fresh))
    end)
end)

describe("derived highlight groups and window highlights", function()
    it("ignore the current window's winhighlight when reading the theme", function()
        local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
        local child = vim.fn.jobstart({ "nvim", "--clean", "--headless", "--embed", "--cmd", "set rtp^=" .. root }, { rpc = true })
        local function remote(code)
            return vim.rpcrequest(child, "nvim_exec_lua", code, {})
        end
        remote("vim.api.nvim_set_hl(0, 'Normal', { fg = '#f8f8f2', bg = '#272822' }); require('difftastic-nvim.highlight').setup({})")
        local before = remote("return { vim.api.nvim_get_hl(0, { name = 'DifftTreeFile' }), vim.api.nvim_get_hl(0, { name = 'DifftAdded' }) }")
        -- A window like the side panel, whose Normal is a background-only group.
        remote("vim.cmd('vsplit'); vim.wo.winhighlight = 'Normal:DifftTreeNormal,NormalNC:DifftTreeNormal'; vim.cmd('wincmd w'); vim.cmd('wincmd w')")
        remote("require('difftastic-nvim.highlight').refresh()")
        local after = remote("return { vim.api.nvim_get_hl(0, { name = 'DifftTreeFile' }), vim.api.nvim_get_hl(0, { name = 'DifftAdded' }) }")
        vim.fn.jobstop(child)

        assert.are.equal("#f8f8f2", hex(before[1].fg))
        assert.are.same(before, after)
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
