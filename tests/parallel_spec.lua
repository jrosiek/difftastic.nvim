--- The native library runs difft per changed file, in parallel. These specs check
--- its results against `git -c diff.external=difft diff` (git calling difft one
--- file at a time) on a scratch repository with the cases that differ easily:
--- added, deleted, renamed, binary, empty, mode-only, symlink, encodings, odd
--- paths, language from a shebang or file name, and .gitattributes.

-- Opening the diff view needs nui.nvim, which plugin managers install next to plenary.
if not pcall(require, "nui.tree") then
    local plenary_dir = vim.api.nvim_get_runtime_file("lua/plenary", false)[1]
    if plenary_dir then
        vim.opt.rtp:append(vim.fn.fnamemodify(plenary_dir, ":h:h:h") .. "/nui.nvim")
    end
end

local binary = require("difftastic-nvim.binary")
local layout = require("difftastic-nvim.layout")

local lib_ok, lib = pcall(binary.get)
local has_tools = vim.fn.executable("difft") == 1 and vim.fn.executable("git") == 1

describe("parallel difft", function()
    if not (lib_ok and has_tools) then
        it("is skipped without the native library, difft or git", function() end)
        return
    end

    local repo, original_cwd

    local function run(cmd, opts)
        local result = vim.system(cmd, vim.tbl_extend("force", { text = true, cwd = repo }, opts or {})):wait()
        assert(result.code == 0, table.concat(cmd, " ") .. ": " .. (result.stderr or ""))
        return result.stdout
    end

    local function git(args)
        local cmd = { "git", "-c", "user.name=t", "-c", "user.email=t@t" }
        vim.list_extend(cmd, args)
        return run(cmd)
    end

    --- Writes bytes to a repo-relative path, creating parent directories.
    local function write(path, bytes)
        local full = repo .. "/" .. path
        vim.fn.mkdir(vim.fn.fnamemodify(full, ":h"), "p")
        local f = assert(io.open(full, "wb"))
        f:write(bytes)
        f:close()
    end

    local function lines(n, prefix)
        local t = {}
        for i = 1, n do
            t[i] = (prefix or "line ") .. i
        end
        return table.concat(t, "\n") .. "\n"
    end

    -- A tiny valid PNG (1x1 pixel), different between versions by one byte.
    local PNG = "\137PNG\r\n\26\n\0\0\0\rIHDR\0\0\0\1\0\0\0\1\8\6\0\0\0\31\21\196\137\0\0\0\rIDATx\218c\248\15\0\1\1\1\0\24\221\141\176\0\0\0\0IEND\174B`\130"

    --- The first commit; `change()` then edits every case, committed or not.
    local function base()
        write("mod.py", "def a():\n    return 1\n" .. lines(20))
        write("del.rs", "fn main() {}\n")
        write("ren.rs", "fn renamed() {}\n" .. lines(15))
        write("renedit.lua", "local x = 1\n" .. lines(15))
        write("img.png", PNG)
        write("bin.dat", "\0\1\2\3binary\255\254" .. lines(3))
        write("mode.sh", "echo hi\n")
        write("nonl.py", "x = 1\ny = 2")
        write("crlf.py", "a = 1\r\nb = 2\r\n")
        write("latin1.py", "s = '\233t\233'\nt = 1\n")
        write("dir with space/żółw é.yaml", "a: 1\nb: 2\n")
        write("script", "#!/bin/bash\necho one\n")
        write("Makefile", "all:\n\techo one\n")
        write("attr.txt", "plain text\nmarked -diff\n")
        write(".gitattributes", "attr.txt -diff\n")
        vim.uv.fs_symlink("mod.py", repo .. "/link")
    end

    local function change()
        write("mod.py", "def a():\n    return 2\n" .. lines(20))
        vim.fn.delete(repo .. "/del.rs")
        vim.uv.fs_rename(repo .. "/ren.rs", repo .. "/ren2.rs")
        vim.uv.fs_rename(repo .. "/renedit.lua", repo .. "/renedit2.lua")
        write("renedit2.lua", "local x = 2\n" .. lines(15))
        write("img.png", PNG:sub(1, -2) .. "\131")
        write("bin.dat", "\0\1\2\4binary\255\254" .. lines(3))
        vim.uv.fs_chmod(repo .. "/mode.sh", tonumber("755", 8))
        write("nonl.py", "x = 1\ny = 3")
        write("crlf.py", "a = 1\r\nb = 3\r\n")
        write("latin1.py", "s = '\233t\233 \233'\nt = 1\n")
        write("dir with space/żółw é.yaml", "a: 1\nb: 3\n")
        write("script", "#!/bin/bash\necho two\n")
        write("Makefile", "all:\n\techo two\n")
        write("attr.txt", "plain text\nmarked -diff, changed\n")
        write("added.js", "const a = 1;\n")
        write("empty.txt", "")
        vim.fn.delete(repo .. "/link")
        vim.uv.fs_symlink("nonl.py", repo .. "/link")
    end

    before_each(function()
        original_cwd = vim.fn.getcwd()
        repo = vim.fn.resolve(vim.fn.tempname())
        vim.fn.mkdir(repo, "p")
        git({ "init", "-q" })
        base()
        git({ "add", "-A" })
        git({ "commit", "-q", "-m", "base" })
        change()
        vim.fn.chdir(repo)
    end)

    after_each(function()
        vim.fn.chdir(original_cwd)
        vim.fn.delete(repo, "rf")
    end)

    --- difft's entries as git produces them, keyed by path.
    local function reference(args)
        local cmd = { "git", "-c", "diff.external=difft", "diff" }
        vim.list_extend(cmd, args)
        local out = run(cmd, { env = { DFT_DISPLAY = "json", DFT_UNSTABLE = "yes" } })
        local entries = {}
        for line in out:gmatch("[^\n]+") do
            local entry = vim.json.decode(line)
            entries[entry.path] = entry
        end
        return entries
    end

    --- The library's files keyed by path; a renamed file under its new path.
    local function library(call)
        local result = call()
        local files = {}
        for _, file in ipairs(result.files) do
            -- The rows both panes show, rebuilt from each side's lines and fillers.
            layout.ensure_rows(file)
            files[file.path] = file
        end
        return files, result.files
    end

    local function aligned(list)
        local result = {}
        for i, pair in ipairs(list or {}) do
            result[i] = { pair[1] == vim.NIL and -1 or pair[1] or -1, pair[2] == vim.NIL and -1 or pair[2] or -1 }
        end
        return result
    end

    --- Every reference entry has a library file with the same language and line
    --- alignment, and the same status except for renames (shown as moved files).
    local function assert_same(ref, files)
        local count = 0
        for path, entry in pairs(ref) do
            count = count + 1
            local file = files[path]
            assert.is_not_nil(file, "missing " .. path)
            assert.are.equal(entry.language, file.language, path)
            if not file.moved_from then
                assert.are.equal(entry.status, file.status, path)
            end
            if entry.aligned_lines and #entry.aligned_lines > 0 then
                assert.are.same(aligned(entry.aligned_lines), aligned(file.aligned_lines), path)
            end
        end
        assert.is_true(count > 0)
        -- No extra files beyond git's list (a rename's old path is folded in).
        local extra = {}
        for path in pairs(files) do
            if not ref[path] then
                table.insert(extra, path)
            end
        end
        assert.are.same({}, extra)
    end

    it("matches git for a commit range", function()
        git({ "add", "-A" })
        git({ "commit", "-q", "-m", "change" })

        assert_same(reference({ "HEAD^..HEAD" }), (library(function()
            return lib.run_diff("HEAD", "git", 0)
        end)))
    end)

    it("matches git for staged changes", function()
        git({ "add", "-A" })

        assert_same(reference({ "--cached" }), (library(function()
            return lib.run_diff_staged("git", 0)
        end)))
    end)

    it("matches git for unstaged changes", function()
        -- Renames and added files need the index to be seen; stage the rest only.
        git({ "add", "-A" })
        git({ "commit", "-q", "-m", "change" })
        write("mod.py", "def a():\n    return 3\n" .. lines(20))
        write("img.png", PNG)
        write("latin1.py", "s = '\233'\n")
        vim.fn.delete(repo .. "/link")
        vim.uv.fs_symlink("crlf.py", repo .. "/link")

        assert_same(reference({}), (library(function()
            return lib.run_diff_unstaged("git", 0)
        end)))
    end)

    it("gives the same result with one call at a time and with many", function()
        git({ "add", "-A" })
        git({ "commit", "-q", "-m", "change" })

        local _, serial = library(function()
            return lib.run_diff("HEAD", "git", 1)
        end)
        local _, parallel = library(function()
            return lib.run_diff("HEAD", "git", 8)
        end)
        assert.are.same(serial, parallel)
    end)

    it("keeps git's file order", function()
        git({ "add", "-A" })
        git({ "commit", "-q", "-m", "change" })

        local order = {}
        -- -z: paths unquoted, as the library reports them.
        for path in run({ "git", "diff", "--name-only", "-M", "-z", "HEAD^..HEAD" }):gmatch("[^%z]+") do
            table.insert(order, path)
        end
        local _, files = library(function()
            return lib.run_diff("HEAD", "git", 0)
        end)
        local paths = vim.tbl_map(function(f)
            return f.path
        end, files)
        assert.are.same(order, paths)
    end)

    it("shows a renamed file with its old content", function()
        git({ "add", "-A" })
        git({ "commit", "-q", "-m", "change" })

        local files = library(function()
            return lib.run_diff("HEAD", "git", 0)
        end)
        local file = files["renedit2.lua"]
        assert.are.equal("renedit.lua", file.moved_from)
        assert.are.equal("local x = 1", file.rows[1].left.content)
        assert.are.equal("local x = 2", file.rows[1].right.content)
    end)

    it("leaves no temporary files behind", function()
        git({ "add", "-A" })
        git({ "commit", "-q", "-m", "change" })
        local function leftovers()
            local pattern = "difftastic%-nvim%-git%-" .. vim.fn.getpid() .. "%-"
            local n = 0
            for name in vim.fs.dir(vim.uv.os_tmpdir()) do
                if name:find(pattern) then
                    n = n + 1
                end
            end
            return n
        end

        lib.run_diff("HEAD", "git", 0)

        assert.are.equal(0, leftovers())
    end)

    it("reports an error outside a git repository", function()
        local outside = vim.fn.tempname()
        vim.fn.mkdir(outside, "p")
        vim.fn.chdir(outside)

        local ok, err = pcall(lib.run_diff, "HEAD", "git", 0)

        vim.fn.chdir(repo)
        vim.fn.delete(outside, "rf")
        assert.is_false(ok)
        assert.truthy(tostring(err):find("git", 1, true))
    end)
end)

describe("max_parallel_difft_calls in setup()", function()
    local difft = require("difftastic-nvim")
    local original_config, original_notify, messages

    before_each(function()
        original_config = vim.deepcopy(difft.config)
        original_notify = vim.notify
        messages = {}
        vim.notify = function(msg, level)
            table.insert(messages, { msg, level })
        end
    end)

    after_each(function()
        vim.notify = original_notify
        difft.config = original_config
    end)

    it("defaults to 0 (one per CPU)", function()
        assert.are.equal(0, original_config.max_parallel_difft_calls)
    end)

    it("takes a whole number", function()
        difft.setup({ max_parallel_difft_calls = 4 })
        assert.are.equal(4, difft.config.max_parallel_difft_calls)
        assert.are.same({}, messages)
    end)

    for _, value in ipairs({ -1, 2.5, "4" }) do
        it("reports and ignores " .. vim.inspect(value), function()
            difft.setup({ max_parallel_difft_calls = value })

            assert.are.equal(0, difft.config.max_parallel_difft_calls)
            assert.are.equal(1, #messages)
            assert.are.equal(vim.log.levels.ERROR, messages[1][2])
        end)
    end

    it("is passed to the library", function()
        local binary_mod = require("difftastic-nvim.binary")
        local original_get, seen = binary_mod.get, {}
        binary_mod.get = function()
            return {
                run_diff = function(_, _, max)
                    seen.range = max
                    return { files = {} }
                end,
                run_diff_staged = function(_, max)
                    seen.staged = max
                    return { files = {} }
                end,
                run_diff_unstaged = function(_, max)
                    seen.unstaged = max
                    return { files = {} }
                end,
            }
        end
        difft.config.max_parallel_difft_calls = 3

        difft.open("HEAD")
        difft.open("--staged")
        difft.open()

        binary_mod.get = original_get
        assert.are.same({ range = 3, staged = 3, unstaged = 3 }, seen)
    end)
end)
