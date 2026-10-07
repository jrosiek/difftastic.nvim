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

--- Floating windows of a tab page: their text, title, border and highlights.
local function floats(tabpage)
    local result = {}
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
        local config = vim.api.nvim_win_get_config(win)
        if config.relative ~= "" then
            local buf = vim.api.nvim_win_get_buf(win)
            local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
            local groups = {}
            for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
                local text = lines[mark[2] + 1]:sub(mark[3] + 1, mark[4].end_col)
                groups[text] = mark[4].hl_group
            end
            table.insert(result, {
                text = vim.trim(table.concat(lines, "\n")),
                title = config.title,
                title_pos = config.title_pos,
                border = config.border,
                winhl = vim.wo[win].winhl,
                groups = groups,
            })
        end
    end
    return result
end

describe("loading screen", function()
    local original_get, original_redraw, seen

    --- A library whose diff calls record what the screen looks like meanwhile.
    local function library(result_or_error)
        local function call()
            local tab = vim.api.nvim_get_current_tabpage()
            seen = {
                tab = tab,
                tabs = #vim.api.nvim_list_tabpages(),
                floats = floats(tab),
                redrawn = seen and seen.redrawn,
            }
            if type(result_or_error) == "string" then
                error(result_or_error)
            end
            return result_or_error
        end
        return { run_diff = call, run_diff_staged = call, run_diff_unstaged = call }
    end

    before_each(function()
        difft.config.vcs = "git"
        original_get = binary.get
        seen = nil
    end)

    after_each(function()
        difft.close()
        binary.get = original_get
    end)

    it("shows the new tab with a loading message while the diff is computed", function()
        local start_tab, start_count = vim.api.nvim_get_current_tabpage(), #vim.api.nvim_list_tabpages()
        binary.get = function()
            return library({ files = { record("a.txt") } })
        end

        difft.open("HEAD~3..HEAD")

        assert.are_not.equal(start_tab, seen.tab)
        assert.are.equal(start_count + 1, seen.tabs)
        assert.are.equal(1, #seen.floats)
        assert.truthy(seen.floats[1].text:find("HEAD~3 → HEAD", 1, true), seen.floats[1].text)
    end)

    it("lets pending input such as a resize through before placing the message", function()
        binary.get = function()
            return library({ files = { record("a.txt") } })
        end
        local events, original_wait, original_open_win = {}, vim.wait, vim.api.nvim_open_win
        vim.wait = function(...)
            table.insert(events, "wait")
            return original_wait(...)
        end
        vim.api.nvim_open_win = function(buf, enter, config)
            if config.relative == "editor" then
                table.insert(events, "open message")
            end
            return original_open_win(buf, enter, config)
        end

        local ok, err = pcall(difft.open, "HEAD")
        vim.wait, vim.api.nvim_open_win = original_wait, original_open_win

        assert.is_true(ok, err)
        assert.are.same({ "wait", "open message" }, vim.list_slice(events, 1, 2))
    end)

    it("builds the view in that tab and closes the message", function()
        binary.get = function()
            return library({ files = { record("a.txt") } })
        end

        difft.open("HEAD")

        assert.are.equal(seen.tab, difft.state.diff_tabpage)
        assert.are.same({}, floats(difft.state.diff_tabpage))
        assert.is_true(vim.api.nvim_win_is_valid(difft.state.left_win))
    end)

    it("draws the message before the diff starts", function()
        local redraws = 0
        local original_cmd = vim.cmd
        binary.get = function()
            local lib = library({ files = { record("a.txt") } })
            local run = lib.run_diff
            lib.run_diff = function(...)
                seen = { redrawn = redraws > 0 }
                return run(...)
            end
            return lib
        end
        vim.cmd = setmetatable({}, {
            __call = function(_, c)
                if c == "redraw" then
                    redraws = redraws + 1
                end
                return original_cmd(c)
            end,
            __index = original_cmd,
        })

        local ok, err = pcall(difft.open, "HEAD")
        vim.cmd = original_cmd

        assert.is_true(ok, err)
        assert.is_true(seen.redrawn)
    end)

    it("leaves the loading tab when there are no changes", function()
        local start_tab, start_count = vim.api.nvim_get_current_tabpage(), #vim.api.nvim_list_tabpages()
        binary.get = function()
            return library({ files = {} })
        end
        local original_notify, messages = vim.notify, {}
        vim.notify = function(msg)
            table.insert(messages, msg)
        end

        difft.open("HEAD")
        vim.notify = original_notify

        assert.are.equal(start_tab, vim.api.nvim_get_current_tabpage())
        assert.are.equal(start_count, #vim.api.nvim_list_tabpages())
        assert.are.same({ "No changes found" }, messages)
        assert.is_nil(difft.state.diff_tabpage)
    end)

    it("leaves the loading tab and raises the error when the diff fails", function()
        local start_tab, start_count = vim.api.nvim_get_current_tabpage(), #vim.api.nvim_list_tabpages()
        binary.get = function()
            return library("git command failed: bad revision")
        end

        local ok, err = pcall(difft.open, "nope")

        assert.is_false(ok)
        assert.truthy(tostring(err):find("bad revision", 1, true))
        assert.are.equal(start_tab, vim.api.nvim_get_current_tabpage())
        assert.are.equal(start_count, #vim.api.nvim_list_tabpages())
    end)

    it("names unstaged and staged diffs in the message", function()
        binary.get = function()
            return library({ files = { record("a.txt") } })
        end

        difft.open()
        assert.truthy(seen.floats[1].text:find("index → worktree", 1, true), seen.floats[1].text)
        difft.close()
        difft.open("--staged")
        assert.truthy(seen.floats[1].text:find("HEAD → index", 1, true), seen.floats[1].text)
    end)

    it("looks like the side panel's header box", function()
        binary.get = function()
            return library({ files = { record("a.txt") } })
        end

        difft.open("HEAD~3..HEAD")

        local float = seen.floats[1]
        -- "Loading…" centred in the rounded top border, in the title style.
        assert.are.same({ { " Loading… ", "DifftTreeTitle" } }, float.title)
        assert.are.equal("center", float.title_pos)
        assert.are.same({ "╭", "─", "╮", "│", "╯", "─", "╰", "│" }, float.border)
        -- The range row: muted kind, range in the box's range colour.
        assert.are.equal("Base/Head  HEAD~3 → HEAD", float.text)
        assert.are.equal("DifftTreeMuted", float.groups["Base/Head"])
        assert.are.equal("DifftTreeRange", float.groups["HEAD~3 → HEAD"])
        -- Panel background, divider-coloured frame.
        assert.truthy(float.winhl:find("NormalFloat:DifftTreeNormal", 1, true))
        assert.truthy(float.winhl:find("FloatBorder:DifftTreeDivider", 1, true))
    end)
end)

describe("opening during startup", function()
    --- Starts a child Neovim running `-c 'Difft HEAD'` at 80x24 and returns it. Its
    --- library records where the loading window sits while the diff is computed.
    local function start_child()
        local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
        local nui = vim.api.nvim_get_runtime_file("lua/nui/tree/init.lua", false)[1]
        local setup = ([[
            vim.opt.rtp:prepend(%q)
            vim.opt.rtp:append(%q)
            vim.o.columns, vim.o.lines = 80, 24
            _G.seen = nil
            require("difftastic-nvim.binary").get = function()
                local function run()
                    for _, win in ipairs(vim.api.nvim_list_wins()) do
                        local c = vim.api.nvim_win_get_config(win)
                        if c.relative == "editor" then
                            _G.seen = { columns = vim.o.columns, lines = vim.o.lines, col = c.col, row = c.row, width = c.width, height = c.height }
                        end
                    end
                    return { files = {} }
                end
                return { run_diff = run, run_diff_staged = run, run_diff_unstaged = run }
            end
            require("difftastic-nvim").config.vcs = "git"
        ]]):format(root, vim.fn.fnamemodify(nui, ":h:h:h:h"))
        return vim.fn.jobstart({
            "nvim",
            "--clean",
            "--headless",
            "--embed",
            "--cmd",
            "lua " .. setup:gsub("\n", " "),
            "--cmd",
            "runtime plugin/difftastic-nvim.lua",
            "-c",
            "Difft HEAD",
        }, { rpc = true })
    end

    local function wait_for_seen(child)
        local seen
        vim.wait(3000, function()
            seen = vim.rpcrequest(child, "nvim_exec_lua", "return _G.seen", {})
            return seen ~= nil and seen ~= vim.NIL
        end, 20)
        return seen
    end

    local function centred(seen)
        -- Border included: the window takes width + 2 columns.
        return seen.col == math.floor((seen.columns - seen.width - 2) / 2)
    end

    it("waits for a resize right after startup before opening", function()
        local child = start_child()
        vim.wait(60)
        -- A GUI applying its font scale after startup (as Neovide does).
        vim.rpcrequest(child, "nvim_exec_lua", "vim.o.columns, vim.o.lines = 100, 30", {})
        local seen = wait_for_seen(child)
        vim.fn.jobstop(child)

        assert.is_table(seen)
        assert.are.same({ 100, 30 }, { seen.columns, seen.lines })
        assert.is_true(centred(seen), vim.inspect(seen))
    end)

    it("opens soon after startup when nothing resizes", function()
        local start = vim.uv.now()
        local child = start_child()
        local seen = wait_for_seen(child)
        local elapsed = vim.uv.now() - start
        vim.fn.jobstop(child)

        assert.is_table(seen)
        assert.is_true(centred(seen), vim.inspect(seen))
        assert.is_true(elapsed < 900, "took " .. elapsed .. " ms")
    end)
end)
