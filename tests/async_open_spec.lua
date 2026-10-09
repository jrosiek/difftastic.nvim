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

--- A library with asynchronous diffs whose jobs the test drives: it queues what
--- a job reports, and `poll()` delivers it, as the native library does.
local function fake_library()
    local lib = { jobs = {}, queue = {}, polls = 0 }

    function lib.run_diff_async(spec, on_progress, on_complete)
        local job = { spec = spec, on_progress = on_progress, on_complete = on_complete, cancelled = false }
        function job:cancel()
            self.cancelled = true
        end
        function job:progress(count, total, message)
            table.insert(lib.queue, function()
                if not self.cancelled and self.on_progress(count, total, message) == false then
                    self.cancelled = true
                end
            end)
        end
        function job:complete(result, err)
            table.insert(lib.queue, function()
                self.done = true
                if not self.cancelled then
                    self.on_complete(result, err)
                end
            end)
        end
        table.insert(lib.jobs, job)
        return job
    end

    function lib.poll()
        lib.polls = lib.polls + 1
        local queue = lib.queue
        lib.queue = {}
        for _, deliver in ipairs(queue) do
            deliver()
        end
        local pending = 0
        for _, job in ipairs(lib.jobs) do
            if not job.done and not job.cancelled then
                pending = pending + 1
            end
        end
        return pending
    end

    return lib
end

--- The loading window of a tab: its lines, or nil without one.
local function loading_lines(tabpage)
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
        if vim.api.nvim_win_get_config(win).relative ~= "" then
            return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false), win
        end
    end
end

--- Waits until the poll timer has delivered everything queued.
local function delivered(lib)
    return vim.wait(2000, function()
        return #lib.queue == 0
    end, 5)
end

describe("opening a diff asynchronously", function()
    local original_get, original_interval, original_notify, lib, notes, start_tab

    before_each(function()
        difft.config.vcs = "git"
        original_get = binary.get
        original_interval = difft.poll_interval_ms
        difft.poll_interval_ms = 5
        lib = fake_library()
        binary.get = function()
            return lib
        end
        notes = {}
        original_notify = vim.notify
        vim.notify = function(message, level)
            table.insert(notes, { message = message, level = level })
        end
        start_tab = vim.api.nvim_get_current_tabpage()
    end)

    after_each(function()
        difft.close()
        vim.notify = original_notify
        binary.get = original_get
        difft.poll_interval_ms = original_interval
        for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
            if tab ~= start_tab and #vim.api.nvim_list_tabpages() > 1 then
                vim.cmd("tabclose " .. vim.api.nvim_tabpage_get_number(tab))
            end
        end
    end)

    it("returns at once with a loading tab and passes the diff to the library", function()
        difft.open("HEAD~2..HEAD")

        local tab = vim.api.nvim_get_current_tabpage()
        assert.are_not.equal(start_tab, tab)
        assert.is_nil(difft.state.left_win)
        local lines, win = loading_lines(tab)
        -- A bar with a spinner while the total is unknown, the range kind left
        -- and the range right, the last message, and the rule.
        assert.are.equal(4, #lines)
        assert.truthy(lines[1]:match("^ Loading… +%S+ $"), lines[1])
        assert.truthy(lines[2]:match("^ Base/Head +HEAD~2 → HEAD $"), lines[2])
        assert.truthy(lines[3]:match("^ +Starting… $"), lines[3])
        assert.truthy(lines[4]:match("^ +$"), lines[4])
        local width = vim.api.nvim_win_get_width(win)
        for _, line in ipairs(lines) do
            assert.are.equal(width, vim.fn.strdisplaywidth(line))
        end
        assert.are.same(
            {
                mode = "range",
                revset = "HEAD~2..HEAD",
                vcs = "git",
                max_parallel = difft.config.max_parallel_difft_calls,
                cwd = vim.fn.getcwd(-1, start_tab),
            },
            lib.jobs[1].spec
        )
    end)

    it("asks for staged and unstaged changes by mode", function()
        difft.open("--staged")
        assert.are.equal("staged", lib.jobs[1].spec.mode)
        difft.open(nil)
        assert.are.equal("unstaged", lib.jobs[2].spec.mode)
    end)

    it("shows the progress in the loading window", function()
        difft.open("HEAD")
        local tab = vim.api.nvim_get_current_tabpage()

        lib.jobs[1]:progress(0, -1, "Listing changes")
        assert.is_true(delivered(lib))
        assert.truthy(loading_lines(tab)[3]:match("^ +Listing changes $"), loading_lines(tab)[3])

        lib.jobs[1]:progress(2, 5, "a.txt")
        assert.is_true(delivered(lib))
        local lines, win = loading_lines(tab)
        assert.truthy(lines[1]:match("^ Loading… +40%% $"), lines[1])
        assert.truthy(lines[3]:match("^ +a%.txt $"), lines[3])
        -- The rule below keeps the rule colour; the percentage is in the
        -- progress colour, drawn over the bar.
        local buf = vim.api.nvim_win_get_buf(win)
        local function marks(row)
            local found = {}
            for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, { row, 0 }, { row, -1 }, { details = true })) do
                found[mark[4].hl_group] = { mark[3], mark[4].end_col, mark[4].priority }
            end
            return found
        end
        local width = vim.api.nvim_win_get_width(win)
        local rule = marks(3)
        assert.are.same({ 1, width - 1 }, { rule.DifftTreeRule[1], rule.DifftTreeRule[2] })
        assert.is_nil(rule.DifftLoadingDone)
        local bar = marks(0)
        assert.is_true(bar.DifftLoadingDone[3] > bar.DifftBar[3])
        assert.are.equal("40%", lines[1]:sub(bar.DifftLoadingDone[1] + 1, bar.DifftLoadingDone[2]))

        -- A report without a message keeps the last one.
        lib.jobs[1]:progress(2, 5, "")
        assert.is_true(delivered(lib))
        assert.truthy(loading_lines(tab)[3]:match("^ +a%.txt $"), loading_lines(tab)[3])

        -- A message too long for the row is cut at its start.
        lib.jobs[1]:progress(3, 5, string.rep("x", 100) .. "end.lua")
        assert.is_true(delivered(lib))
        local row = loading_lines(tab)[3]
        assert.truthy(row:match("^ …x*end%.lua $"), row)
        assert.are.equal(vim.api.nvim_win_get_width(select(2, loading_lines(tab))), vim.fn.strdisplaywidth(row))
    end)

    it("builds the view in the diff tab when the result arrives, and stops polling", function()
        difft.open("HEAD")
        local tab = vim.api.nvim_get_current_tabpage()

        lib.jobs[1]:complete({ files = { record("a.txt") } })
        assert.is_true(delivered(lib))

        assert.are.equal(tab, difft.state.diff_tabpage)
        assert.are.equal(start_tab, difft.state.original_tabpage)
        assert.is_true(vim.api.nvim_win_is_valid(difft.state.left_win))
        assert.is_nil(loading_lines(tab))

        local polls = lib.polls
        vim.wait(60)
        assert.are.equal(polls, lib.polls, "still polling with no diff running")
    end)

    it("waits for the diff tab to be entered before building the view", function()
        difft.open("HEAD")
        local tab = vim.api.nvim_get_current_tabpage()
        vim.api.nvim_set_current_tabpage(start_tab)

        lib.jobs[1]:complete({ files = { record("a.txt") } })
        assert.is_true(delivered(lib))
        assert.is_nil(difft.state.left_win)
        assert.are.equal(start_tab, vim.api.nvim_get_current_tabpage())

        vim.api.nvim_set_current_tabpage(tab)
        assert.is_true(vim.api.nvim_win_is_valid(difft.state.left_win))
        assert.are.equal(tab, vim.api.nvim_win_get_tabpage(difft.state.left_win))
    end)

    it("reports a failure and leaves the loading tab", function()
        difft.open("HEAD")
        local tab = vim.api.nvim_get_current_tabpage()

        lib.jobs[1]:complete(nil, "Not inside a git repository")
        assert.is_true(delivered(lib))

        assert.is_false(vim.api.nvim_tabpage_is_valid(tab))
        assert.are.equal(start_tab, vim.api.nvim_get_current_tabpage())
        assert.are.equal("difftastic-nvim: Not inside a git repository", notes[#notes].message)
        assert.are.equal(vim.log.levels.ERROR, notes[#notes].level)
    end)

    it("says so when there are no changes", function()
        difft.open("HEAD")
        local tab = vim.api.nvim_get_current_tabpage()

        lib.jobs[1]:complete({ files = {} })
        assert.is_true(delivered(lib))

        assert.is_false(vim.api.nvim_tabpage_is_valid(tab))
        assert.are.equal("No changes found", notes[#notes].message)
    end)

    it("cancels the computation when the view is closed while loading", function()
        difft.open("HEAD")
        local tab = vim.api.nvim_get_current_tabpage()

        difft.close()

        assert.is_true(lib.jobs[1].cancelled)
        assert.is_false(vim.api.nvim_tabpage_is_valid(tab))
        assert.are.equal(start_tab, vim.api.nvim_get_current_tabpage())
    end)

    it("cancels the computation with the close key in the loading tab", function()
        difft.open("HEAD")
        local tab = vim.api.nvim_get_current_tabpage()

        vim.api.nvim_feedkeys("q", "mx", false)

        assert.is_true(lib.jobs[1].cancelled)
        assert.is_false(vim.api.nvim_tabpage_is_valid(tab))
        assert.are.equal(start_tab, vim.api.nvim_get_current_tabpage())
    end)

    it("cancels the computation when the loading tab is closed", function()
        difft.open("HEAD")

        vim.cmd("tabclose")

        assert.is_true(vim.wait(1000, function()
            return lib.jobs[1].cancelled
        end, 5))
        -- A late progress report is refused rather than drawn.
        assert.is_false(lib.jobs[1].on_progress(1, 2, "a.txt"))
    end)

    it("cancels the computation when Neovim exits", function()
        difft.open("HEAD")

        vim.api.nvim_exec_autocmds("VimLeavePre", {})

        assert.is_true(lib.jobs[1].cancelled)
    end)

    it("replaces a diff still loading with a new one", function()
        difft.open("HEAD~1")
        local first_tab = vim.api.nvim_get_current_tabpage()

        difft.open("HEAD~2")
        local second_tab = vim.api.nvim_get_current_tabpage()

        assert.is_true(lib.jobs[1].cancelled)
        assert.is_false(vim.api.nvim_tabpage_is_valid(first_tab))
        assert.are_not.equal(first_tab, second_tab)
        assert.is_false(lib.jobs[2].cancelled)

        -- A result of the first diff that was already on its way is dropped.
        lib.jobs[1].cancelled = false
        lib.jobs[1].on_complete({ files = { record("old.txt") } })
        assert.is_nil(difft.state.left_win)
    end)

    it("keeps the loading window centred when Neovim is resized", function()
        local columns = vim.o.columns
        difft.open("HEAD")
        local tab = vim.api.nvim_get_current_tabpage()
        local _, win = loading_lines(tab)

        vim.o.columns = columns + 40
        vim.api.nvim_exec_autocmds("VimResized", {})
        local config = vim.api.nvim_win_get_config(win)
        vim.o.columns = columns

        -- Borderless: centred on its own size, all four rows kept.
        assert.are.equal(math.floor((columns + 40 - config.width) / 2), config.col)
        assert.are.equal(4, config.height)
        assert.are.equal(math.floor((vim.o.lines - 4) / 2), config.row)
    end)
end)

describe("opening a diff asynchronously with the native library", function()
    local lib_ok, lib = pcall(binary.get)
    if not (lib_ok and lib.run_diff_async and vim.fn.executable("difft") == 1 and vim.fn.executable("git") == 1) then
        it("is skipped without the native library, difft or git", function() end)
        return
    end

    local repo, original_cwd

    local function git(args)
        local cmd = { "git", "-c", "user.name=t", "-c", "user.email=t@t" }
        vim.list_extend(cmd, args)
        local result = vim.system(cmd, { text = true, cwd = repo }):wait()
        assert(result.code == 0, result.stderr)
    end

    before_each(function()
        difft.config.vcs = "git"
        original_cwd = vim.fn.getcwd()
        repo = vim.fn.resolve(vim.fn.tempname())
        vim.fn.mkdir(repo, "p")
        git({ "init", "-q" })
        vim.fn.writefile({ "one" }, repo .. "/a.txt")
        git({ "add", "-A" })
        git({ "commit", "-q", "-m", "initial" })
        vim.fn.writefile({ "two" }, repo .. "/a.txt")
        vim.fn.writefile({ "new" }, repo .. "/b.txt")
        git({ "add", "-A" })
        git({ "commit", "-q", "-m", "change" })
        vim.fn.chdir(repo)
    end)

    after_each(function()
        difft.close()
        vim.fn.chdir(original_cwd)
        vim.fn.delete(repo, "rf")
    end)

    it("shows the diff once it is computed", function()
        difft.open("HEAD")
        assert.is_nil(difft.state.left_win)

        assert.is_true(vim.wait(10000, function()
            return difft.state.left_win ~= nil
        end, 10))
        local paths = vim.tbl_map(function(file)
            return file.path
        end, difft.state.files)
        table.sort(paths)
        assert.are.same({ "a.txt", "b.txt" }, paths)
    end)
end)
