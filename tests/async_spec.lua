--- The native library's asynchronous diff: `run_diff_async`, `poll` and job
--- cancellation, against real scratch repositories. Skipped when the library,
--- difft or git is missing.

local binary = require("difftastic-nvim.binary")

local lib_ok, lib = pcall(binary.get)
local ready = lib_ok
    and type(lib.run_diff_async) == "function"
    and vim.fn.executable("difft") == 1
    and vim.fn.executable("git") == 1

local function run(cmd, cwd)
    local result = vim.system(cmd, { text = true, cwd = cwd }):wait()
    assert(result.code == 0, table.concat(cmd, " ") .. ": " .. (result.stderr or ""))
    return vim.trim(result.stdout)
end

local function write(repo, path, lines)
    local full = repo .. "/" .. path
    vim.fn.mkdir(vim.fn.fnamemodify(full, ":h"), "p")
    vim.fn.writefile(lines, full)
end

--- Starts a job and records what reaches Lua. `on_progress` may decide the
--- progress callback's return value.
local function start(spec, on_progress)
    local seen = { progress = {}, done = false }
    seen.job = lib.run_diff_async(spec, function(count, total, message)
        table.insert(seen.progress, { count = count, total = total, message = message })
        if on_progress then
            return on_progress(count, total, message)
        end
    end, function(result, err)
        seen.done = true
        seen.result, seen.err = result, err
    end)
    return seen
end

--- Polls until nothing is pending (or `timeout` ms pass); returns the last count.
local function drain(timeout)
    local pending
    vim.wait(timeout or 10000, function()
        pending = lib.poll()
        return pending == 0
    end, 5)
    return pending
end

describe("asynchronous diff", function()
    if not ready then
        it("is skipped without the native library, difft or git", function() end)
        return
    end

    local repo, original_cwd, original_path

    local function git(args)
        local cmd = { "git", "-c", "user.name=t", "-c", "user.email=t@t" }
        vim.list_extend(cmd, args)
        return run(cmd, repo)
    end

    local function commit(message)
        git({ "add", "-A" })
        git({ "commit", "-q", "-m", message })
    end

    before_each(function()
        original_cwd = vim.fn.getcwd()
        original_path = vim.env.PATH
        repo = vim.fn.resolve(vim.fn.tempname())
        vim.fn.mkdir(repo, "p")
        git({ "init", "-q" })
        write(repo, "a.txt", { "one", "two", "three" })
        write(repo, "src/b.lua", { "local x = 1", "return x" })
        write(repo, "old.txt", { "moved", "content", "here" })
        commit("initial")
        write(repo, "a.txt", { "one", "TWO", "three" })
        write(repo, "src/b.lua", { "local x = 2", "return x" })
        write(repo, "c.txt", { "new" })
        git({ "mv", "old.txt", "new.txt" })
        commit("change")
        vim.fn.chdir(repo)
    end)

    after_each(function()
        drain(2000)
        vim.env.PATH = original_path
        vim.fn.chdir(original_cwd)
        vim.fn.delete(repo, "rf")
    end)

    it("delivers the same result as the blocking call", function()
        local seen = start({ mode = "range", revset = "HEAD", vcs = "git" })
        assert.are.equal(0, drain())
        assert.is_true(seen.done)
        assert.is_nil(seen.err)
        assert.are.same(lib.run_diff("HEAD", "git"), seen.result)
    end)

    it("delivers the same result for staged and unstaged changes", function()
        write(repo, "a.txt", { "staged" })
        git({ "add", "a.txt" })
        write(repo, "src/b.lua", { "unstaged" })

        local staged = start({ mode = "staged", vcs = "git" })
        local unstaged = start({ mode = "unstaged", vcs = "git", max_parallel = 1 })
        assert.are.equal(0, drain())

        assert.are.same(lib.run_diff_staged("git"), staged.result)
        assert.are.same(lib.run_diff_unstaged("git"), unstaged.result)
        assert.are.equal(1, #staged.result.files)
        assert.are.equal(1, #unstaged.result.files)
    end)

    it("reports progress up to one step per file", function()
        local seen = start({ mode = "range", revset = "HEAD", vcs = "git" })
        drain()

        local files = #seen.result.files
        assert.is_true(#seen.progress > 0)
        -- The total is unknown (-1) until the files are listed. Reports between
        -- two polls collapse into the newest, so the -1 is not always seen.
        for _, p in ipairs(seen.progress) do
            assert.is_true(p.total == -1 or p.total == files, "unexpected total " .. p.total)
        end
        local last = seen.progress[#seen.progress]
        assert.are.equal(files, last.count)
        assert.are.equal(files, last.total)
        local previous = 0
        for _, p in ipairs(seen.progress) do
            assert.is_true(p.count >= previous, "count went down")
            previous = p.count
        end
        -- Messages name the step: listing, or the file just done.
        local names = { [""] = true, ["Listing changes"] = true }
        for _, file in ipairs(seen.result.files) do
            names[vim.fn.fnamemodify(file.path, ":t")] = true
        end
        for _, p in ipairs(seen.progress) do
            assert.is_true(names[p.message] ~= nil, "unexpected message " .. p.message)
        end
    end)

    it("counts a job as pending until its result is delivered", function()
        local seen = start({ mode = "range", revset = "HEAD", vcs = "git" })
        assert.are.equal(1, lib.poll())
        assert.are.equal(0, drain())
        assert.is_true(seen.done)
    end)

    it("reports failures through the completion callback", function()
        local outside = vim.fn.tempname()
        vim.fn.mkdir(outside, "p")
        vim.fn.chdir(outside)

        local seen = start({ mode = "range", revset = "HEAD", vcs = "git" })
        assert.are.equal(0, drain())

        assert.is_true(seen.done)
        assert.is_nil(seen.result)
        assert.matches("Not inside a git repository", seen.err)
        vim.fn.delete(outside, "rf")
    end)

    it("rejects an unknown mode", function()
        assert.has_error(function()
            lib.run_diff_async({ mode = "sideways", vcs = "git" }, function() end, function() end)
        end)
    end)

    it("stops calling back once the progress callback returns false", function()
        local calls = 0
        local seen = start({ mode = "range", revset = "HEAD", vcs = "git", max_parallel = 1 }, function()
            calls = calls + 1
            return false
        end)
        assert.are.equal(0, drain())

        assert.are.equal(1, calls)
        assert.is_false(seen.done)
        assert.is_true(seen.job:is_cancelled())
    end)

    describe("with a difft that hangs", function()
        local marker

        before_each(function()
            -- A difft that never finishes, recognisable in the process list by its
            -- unique duration. It must not fork: killing it has to end it.
            marker = ("sleep 60.%d%06d"):format(vim.fn.getpid(), math.random(1e6))
            local bin = vim.fn.tempname()
            vim.fn.mkdir(bin, "p")
            vim.fn.writefile({ "#!/bin/sh", "exec " .. marker }, bin .. "/difft")
            vim.fn.setfperm(bin .. "/difft", "rwxr-xr-x")
            vim.env.PATH = bin .. ":" .. vim.env.PATH
        end)

        local function hanging()
            local result = vim.system({ "pgrep", "-f", marker }, { text = true }):wait()
            return result.code == 0
        end

        it("kills the running difft processes on cancel", function()
            local seen = start({ mode = "range", revset = "HEAD", vcs = "git", max_parallel = 2 })
            assert.is_true(vim.wait(5000, hanging, 10), "difft did not start")

            local before = vim.uv.hrtime()
            seen.job:cancel()
            assert.is_true((vim.uv.hrtime() - before) / 1e6 < 1000, "cancel did not return promptly")
            assert.is_true(vim.wait(2000, function()
                return not hanging()
            end, 10), "difft still running after cancel")

            assert.are.equal(0, drain(5000))
            assert.is_false(seen.done)
        end)

        it("is not counted as pending after a cancel", function()
            local seen = start({ mode = "range", revset = "HEAD", vcs = "git" })
            assert.is_true(vim.wait(5000, hanging, 10), "difft did not start")
            assert.are.equal(1, lib.poll())
            seen.job:cancel()
            assert.are.equal(0, drain(5000))
        end)
    end)
end)
