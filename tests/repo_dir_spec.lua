--- The repository a diff is computed for: an explicit directory (`open`'s
--- `opts.cwd`, the library's `dir` / `spec.cwd`), else the current window's.

-- Opening the diff view needs nui.nvim, which plugin managers install next to plenary.
if not pcall(require, "nui.tree") then
    local plenary_dir = vim.api.nvim_get_runtime_file("lua/plenary", false)[1]
    if plenary_dir then
        vim.opt.rtp:append(vim.fn.fnamemodify(plenary_dir, ":h:h:h") .. "/nui.nvim")
    end
end

local difft = require("difftastic-nvim")
local binary = require("difftastic-nvim.binary")

local lib_ok, lib = pcall(binary.get)
local has_difft = vim.fn.executable("difft") == 1

local function run(cmd, cwd)
    local result = vim.system(cmd, { text = true, cwd = cwd }):wait()
    assert(result.code == 0, table.concat(cmd, " ") .. ": " .. (result.stderr or ""))
end

local function write(repo, path, lines)
    local full = repo .. "/" .. path
    vim.fn.mkdir(vim.fn.fnamemodify(full, ":h"), "p")
    vim.fn.writefile(lines, full)
end

local function paths(result)
    local list = {}
    for _, file in ipairs(result.files) do
        table.insert(list, file.path)
    end
    table.sort(list)
    return list
end

--- A git repository with one commit, and an uncommitted edit of `name`.
local function git_repo(name)
    local repo = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(repo, "p")
    run({ "git", "init", "-q" }, repo)
    run({ "git", "config", "user.email", "t@t" }, repo)
    run({ "git", "config", "user.name", "t" }, repo)
    write(repo, "sub/" .. name, { "one" })
    run({ "git", "add", "-A" }, repo)
    run({ "git", "commit", "-q", "-m", "initial" }, repo)
    write(repo, "sub/" .. name, { "two" })
    return repo
end

describe("library diff directory", function()
    if not (lib_ok and has_difft and vim.fn.executable("git") == 1 and lib.run_diff_async) then
        it("is skipped without the native library, difft or git", function() end)
        return
    end

    local here, there, original_cwd

    before_each(function()
        original_cwd = vim.fn.getcwd()
        here, there = git_repo("here.txt"), git_repo("there.txt")
        -- The process works in one repository while the other is diffed.
        vim.fn.chdir(here)
    end)

    after_each(function()
        vim.fn.chdir(original_cwd)
        vim.fn.delete(here, "rf")
        vim.fn.delete(there, "rf")
    end)

    it("diffs the repository of the given directory, not the current one", function()
        assert.are.same({ "sub/there.txt" }, paths(lib.run_diff_unstaged("git", 0, there)))
        assert.are.same({ "sub/there.txt" }, paths(lib.run_diff_unstaged("git", 0, there .. "/sub")))
        assert.are.same({ "sub/here.txt" }, paths(lib.run_diff_unstaged("git", 0)))
    end)

    it("keeps the directory of an asynchronous diff when the current one changes", function()
        local done, result, err = false, nil, nil
        lib.run_diff_async({ mode = "unstaged", vcs = "git", cwd = there }, function() end, function(r, e)
            done, result, err = true, r, e
        end)
        -- Moved before the job has even started.
        vim.fn.chdir(original_cwd)
        vim.wait(10000, function()
            lib.poll()
            return done
        end, 5)

        assert.is_nil(err)
        assert.are.same({ "sub/there.txt" }, paths(result))
    end)

    it("reports a directory outside any repository", function()
        local outside = vim.fn.resolve(vim.fn.tempname())
        vim.fn.mkdir(outside, "p")
        local ok, message = pcall(lib.run_diff_unstaged, "git", 0, outside)
        vim.fn.delete(outside, "rf")
        assert.is_false(ok)
        assert.truthy(tostring(message):find("Not inside a git repository", 1, true))
    end)
end)

describe("jj diff directory", function()
    if not (lib_ok and has_difft and vim.fn.executable("jj") == 1) then
        it("is skipped without the native library, difft or jj", function() end)
        return
    end

    local repo, saved_env

    before_each(function()
        saved_env = { JJ_USER = vim.env.JJ_USER, JJ_EMAIL = vim.env.JJ_EMAIL }
        vim.env.JJ_USER, vim.env.JJ_EMAIL = "t", "t@t"
        repo = vim.fn.resolve(vim.fn.tempname())
        vim.fn.mkdir(repo, "p")
        run({ "jj", "git", "init", "--colocate" }, repo)
        write(repo, "sub/a.txt", { "one" })
        run({ "jj", "commit", "-m", "initial" }, repo)
        write(repo, "sub/a.txt", { "two" })
    end)

    after_each(function()
        vim.env.JJ_USER, vim.env.JJ_EMAIL = saved_env.JJ_USER, saved_env.JJ_EMAIL
        vim.fn.delete(repo, "rf")
    end)

    it("reports repo-relative paths with both sides, from a subdirectory", function()
        local result = lib.run_diff_unstaged("jj", 0, repo .. "/sub")
        assert.are.same({ "sub/a.txt" }, paths(result))
        -- Both sides were read: from the parent revision and the working copy.
        local file = result.files[1]
        assert.are.equal("one", file.base.lines[1].content)
        assert.are.equal("two", file.head.lines[1].content)
    end)
end)

describe("open() directory", function()
    local original_get, original_config, calls, dir, start_dir

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

    before_each(function()
        original_config = vim.deepcopy(difft.config)
        difft.config.vcs = "git"
        start_dir = vim.fn.getcwd()
        calls = {}
        dir = vim.fn.resolve(vim.fn.tempname())
        vim.fn.mkdir(dir .. "/sub", "p")
        original_get = binary.get
        binary.get = function()
            return {
                run_diff = function(revset, _, _, cwd)
                    table.insert(calls, { revset = revset, cwd = cwd })
                    return { files = { record("a.txt") } }
                end,
            }
        end
    end)

    after_each(function()
        for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
            if vim.api.nvim_tabpage_is_valid(tab) then
                vim.api.nvim_set_current_tabpage(tab)
                difft.close()
            end
        end
        vim.cmd("silent! tabonly")
        vim.cmd("cd " .. vim.fn.fnameescape(start_dir))
        vim.cmd("lcd " .. vim.fn.fnameescape(start_dir))
        binary.get = original_get
        difft.config = original_config
        vim.fn.delete(dir, "rf")
    end)

    it("diffs the given directory and works in it in the diff tab", function()
        local start_cwd = vim.fn.getcwd()
        difft.open("HEAD", { cwd = dir .. "/sub" })

        assert.are.same({ { revset = "HEAD", cwd = dir .. "/sub" } }, calls)
        assert.are.equal(dir .. "/sub", vim.fn.getcwd())
        vim.cmd("tabprevious")
        assert.are.equal(start_cwd, vim.fn.getcwd())
    end)

    it("takes the current window's directory when none is given", function()
        vim.cmd("lcd " .. vim.fn.fnameescape(dir))
        difft.open("HEAD")
        assert.are.equal(dir, calls[1].cwd)
    end)

    it("takes the directory when :Difft is run, not when the view opens", function()
        vim.cmd("lcd " .. vim.fn.fnameescape(dir))
        difft.open_when_ready("HEAD")
        vim.cmd("lcd " .. vim.fn.fnameescape(dir .. "/sub"))
        if vim.v.vim_did_enter == 0 then
            -- Under the test runner startup never finished: let it finish now.
            vim.api.nvim_exec_autocmds("VimEnter", {})
        end
        vim.wait(3000, function()
            return #calls > 0
        end)
        assert.are.equal(dir, calls[1].cwd)
    end)

    it("refuses a directory that does not exist", function()
        local ok, message = pcall(difft.open, "HEAD", { cwd = dir .. "/missing" })
        assert.is_false(ok)
        assert.truthy(tostring(message):find("not a directory", 1, true))
        assert.are.same({}, calls)
    end)

    it("opens a second tab for the same revset in another directory with multiple_diffs", function()
        difft.config.multiple_diffs = true
        difft.open("HEAD", { cwd = dir })
        local first = vim.api.nvim_get_current_tabpage()
        difft.open("HEAD", { cwd = dir .. "/sub" })
        assert.are_not.equal(first, vim.api.nvim_get_current_tabpage())
        difft.open("HEAD", { cwd = dir })
        assert.are.equal(first, vim.api.nvim_get_current_tabpage())
        assert.are.equal(2, #calls)
    end)
end)
