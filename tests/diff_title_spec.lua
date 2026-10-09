--- The diff's title and subtitle at the top of the side panel's header box,
--- which the library derives from the diffed commits.

-- Opening the diff view needs nui.nvim, which plugin managers install next to plenary.
if not pcall(require, "nui.tree") then
    local plenary_dir = vim.api.nvim_get_runtime_file("lua/plenary", false)[1]
    if plenary_dir then
        vim.opt.rtp:append(vim.fn.fnamemodify(plenary_dir, ":h:h:h") .. "/nui.nvim")
    end
end

local difft = require("difftastic-nvim")
local binary = require("difftastic-nvim.binary")

local function file_record(path)
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
                left = { content = "old", highlights = {}, is_filler = false },
                right = { content = "new", highlights = {}, is_filler = false },
            },
        },
    }
end

describe("diff title", function()
    local original_get, result

    before_each(function()
        vim.o.columns = 200
        difft.config.vcs = "git"
        result = { files = { file_record("a.txt") } }
        original_get = binary.get
        binary.get = function()
            return {
                run_diff = function()
                    return result
                end,
                run_diff_staged = function()
                    return result
                end,
            }
        end
    end)

    after_each(function()
        difft.close()
        binary.get = original_get
    end)

    local function header()
        return vim.api.nvim_buf_get_lines(difft.state.tree_buf, 0, difft.state.header_lines, false)
    end

    local function is_rule(line)
        return line:match("^%s*$") ~= nil
    end

    -- Title and subtitle rows above the first rule.
    local function title_rows()
        local rows = {}
        for _, line in ipairs(header()) do
            if is_rule(line) then
                return rows
            end
            table.insert(rows, vim.trim(line))
        end
        return {}
    end

    --- Highlight groups of the header's row (0-based), by start and end column.
    local function groups(row)
        local list = {}
        for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(difft.state.tree_buf, -1, { row, 0 }, { row, -1 }, { details = true })) do
            list[mark[4].hl_group] = { mark[3], mark[4].end_col }
        end
        return list
    end

    it("shows the title on top, ruled off from the stats", function()
        result.title = "Review of PR 42"
        difft.open("HEAD")

        local lines = header()
        assert.are.equal(5, #lines)
        assert.are.equal(" Review of PR 42", lines[1]:gsub("%s+$", ""))
        assert.is_true(is_rule(lines[2]))
        assert.truthy(lines[3]:find("^ 1 file"))
        assert.truthy(lines[4]:find("HEAD^ → HEAD ", 1, true))
        assert.is_true(is_rule(lines[5]))
        -- The rules are underlines, one cell short of the panel's edges.
        local width = vim.fn.strdisplaywidth(lines[1])
        assert.are.same({ 1, width - 1 }, groups(1).DifftTreeRule)
        assert.are.same({ 1, width - 1 }, groups(4).DifftTreeRule)
        -- The file tree starts right below the header.
        local below = vim.api.nvim_buf_get_lines(difft.state.tree_buf, difft.state.header_lines, -1, false)
        assert.truthy(table.concat(below, "\n"):find("a.txt", 1, true))
    end)

    it("has the stats, the range and one rule without a title", function()
        difft.open("HEAD")

        assert.are.equal(3, #header())
        assert.truthy(header()[1]:find("^ 1 file"))
        assert.is_true(is_rule(header()[3]))
    end)

    it("wraps a long subtitle above the rule", function()
        result.title, result.subtitle = "Fix it", "a subtitle long enough to wrap onto more than one row"
        difft.open("HEAD")

        local rows = title_rows()
        assert.are.equal("Fix it", rows[1])
        assert.is_true(#rows > 2)
        assert.are.equal(result.subtitle, table.concat(vim.list_slice(rows, 2), " "))
    end)

    it("shows the subtitle below the title, each in its own colour", function()
        result.title, result.subtitle = "Fix the parser", "+2 more"
        difft.open("HEAD")

        assert.are.same({ "Fix the parser", "+2 more" }, title_rows())
        assert.is_not_nil(groups(0).DifftDiffTitle)
        assert.is_not_nil(groups(1).DifftDiffSubtitle)
    end)

    it("shows the time of a staged or working-tree snapshot as the subtitle", function()
        local time = os.time({ year = 2026, month = 10, day = 9, hour = 16, min = 30, sec = 4 })
        result.title, result.snapshot_time = "Staged changes", time
        difft.open("--staged")

        assert.are.same({ "Staged changes", "as of 9 " .. os.date("%b", time) .. " 16:30:04" }, title_rows())
    end)

    it("wraps a title wider than the panel at word boundaries", function()
        local words = "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu"
        result.title = words
        difft.open("HEAD")

        local rows = title_rows()
        assert.is_true(#rows > 1)
        assert.are.equal(words, table.concat(rows, " "))
        local width = vim.fn.strdisplaywidth(header()[1])
        for _, line in ipairs(header()) do
            assert.are.equal(width, vim.fn.strdisplaywidth(line))
        end
    end)

    it("splits a word longer than the panel", function()
        result.title = string.rep("x", 80)
        difft.open("HEAD")

        local rows = title_rows()
        assert.is_true(#rows > 1)
        assert.are.equal(string.rep("x", 80), table.concat(rows))
    end)

    it("rebuilds the tree below the box when a resize changes the title's height", function()
        result = {
            files = { file_record("dir/a.txt"), file_record("dir/b.txt"), file_record("c.txt") },
            title = "a title long enough to wrap onto several rows when narrow",
        }
        difft.open("HEAD")
        local state = difft.state
        vim.api.nvim_win_set_width(state.tree_win, 80)
        vim.api.nvim_exec_autocmds("WinResized", {})
        local wide_height = state.header_lines

        -- Collapse the directory and put the cursor on c.txt.
        state.tree:get_node("-dir"):collapse()
        state.tree:render()
        local _, c_line = state.tree:get_node("-c.txt")
        vim.api.nvim_win_set_cursor(state.tree_win, { c_line, 0 })

        vim.api.nvim_win_set_width(state.tree_win, 30)
        vim.api.nvim_exec_autocmds("WinResized", {})

        assert.is_true(state.header_lines > wide_height)
        local lines = vim.api.nvim_buf_get_lines(state.tree_buf, 0, -1, false)
        assert.is_true(is_rule(lines[state.header_lines]))
        -- The tree starts right below the new box, with dir still collapsed.
        local tree_text = table.concat(vim.list_slice(lines, state.header_lines + 1), "\n")
        assert.truthy(tree_text:find("dir", 1, true))
        assert.falsy(tree_text:find("a.txt", 1, true))
        assert.is_false(state.tree:get_node("-dir"):is_expanded())
        -- The cursor stays on its row.
        local node = state.tree:get_node(vim.api.nvim_win_get_cursor(state.tree_win)[1])
        assert.are.equal("-c.txt", node:get_id())
    end)
end)

describe("diff title from the library", function()
    local lib_ok, lib = pcall(binary.get)
    if not (lib_ok and vim.fn.executable("difft") == 1 and lib.run_diff_async) then
        it("is skipped without the native library or difft", function() end)
        return
    end

    local function run(cmd, cwd)
        local out = vim.system(cmd, { text = true, cwd = cwd }):wait()
        assert(out.code == 0, table.concat(cmd, " ") .. ": " .. (out.stderr or ""))
    end

    local repo, saved_env

    --- The title and subtitle of a library result: { title, subtitle }, or {}.
    local function title(result)
        return { result.title, result.subtitle }
    end

    before_each(function()
        saved_env = { JJ_USER = vim.env.JJ_USER, JJ_EMAIL = vim.env.JJ_EMAIL }
        vim.env.JJ_USER, vim.env.JJ_EMAIL = "t", "t@t"
        repo = vim.fn.resolve(vim.fn.tempname())
        vim.fn.mkdir(repo, "p")
    end)

    after_each(function()
        vim.env.JJ_USER, vim.env.JJ_EMAIL = saved_env.JJ_USER, saved_env.JJ_EMAIL
        vim.fn.delete(repo, "rf")
    end)

    if vim.fn.executable("git") == 1 then
        --- A git repository with an initial commit and one commit per title, each
        --- changing a.txt; the working tree and index are left changed too.
        local function git_commits(titles)
            run({ "git", "init", "-q" }, repo)
            run({ "git", "config", "user.email", "t@t" }, repo)
            run({ "git", "config", "user.name", "t" }, repo)
            vim.fn.writefile({ "0" }, repo .. "/a.txt")
            run({ "git", "add", "-A" }, repo)
            run({ "git", "commit", "-q", "-m", "initial" }, repo)
            for i, title in ipairs(titles) do
                vim.fn.writefile({ tostring(i) }, repo .. "/a.txt")
                run({ "git", "commit", "-q", "-am", title .. "\n\nbody" }, repo)
            end
            vim.fn.writefile({ "staged" }, repo .. "/a.txt")
            run({ "git", "add", "-A" }, repo)
            vim.fn.writefile({ "unstaged" }, repo .. "/a.txt")
        end

        it("is the title of a single git commit", function()
            git_commits({ "First", "Second" })
            assert.are.same({ "Second" }, title(lib.run_diff("HEAD", "git", 0, repo)))
            assert.are.same({ "First" }, title(lib.run_diff("HEAD~2..HEAD~1", "git", 0, repo)))
        end)

        it("is the oldest title and the count of the others for a git range", function()
            git_commits({ "First", "Second", "Third" })
            assert.are.same({ "First", "+2 more" }, title(lib.run_diff("HEAD~3..HEAD", "git", 0, repo)))
            assert.are.same({ "Second", "+1 more" }, title(lib.run_diff("HEAD~2...HEAD", "git", 0, repo)))
        end)

        it("names staged and unstaged git diffs, with the time of the snapshot", function()
            git_commits({ "First" })
            local before = os.time()
            local staged = lib.run_diff_staged("git", 0, repo)
            local unstaged = lib.run_diff_unstaged("git", 0, repo)
            assert.are.same({ "Staged changes" }, title(staged))
            assert.are.same({ "Unstaged changes" }, title(unstaged))
            for _, result in ipairs({ staged, unstaged }) do
                assert.is_true(result.snapshot_time >= before and result.snapshot_time <= os.time())
            end
            assert.is_nil(lib.run_diff("HEAD", "git", 0, repo).snapshot_time)
        end)
    end

    if vim.fn.executable("jj") == 1 then
        it("comes from jj descriptions, or names the working copy", function()
            run({ "jj", "git", "init" }, repo)
            vim.fn.writefile({ "1" }, repo .. "/a.txt")
            run({ "jj", "commit", "-m", "First\n\nbody" }, repo)
            vim.fn.writefile({ "2" }, repo .. "/a.txt")
            run({ "jj", "commit", "-m", "Second" }, repo)
            vim.fn.writefile({ "3" }, repo .. "/a.txt")

            assert.are.same({ "Second" }, title(lib.run_diff("@-", "jj", 0, repo)))
            assert.are.same({ "First", "+1 more" }, title(lib.run_diff("@--::@-", "jj", 0, repo)))
            local working_copy = lib.run_diff_unstaged("jj", 0, repo)
            assert.are.same({ "Working-copy changes" }, title(working_copy))
            assert.is_number(working_copy.snapshot_time)
        end)
    end
end)
