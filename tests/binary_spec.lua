--- Where prebuilt libraries are downloaded from.

local binary = require("difftastic-nvim.binary")

describe("github_repo", function()
    it("takes owner and name from GitHub remote URLs", function()
        for _, url in ipairs({
            "https://github.com/jrosiek/difftastic.nvim.git",
            "https://github.com/jrosiek/difftastic.nvim",
            "https://github.com/jrosiek/difftastic.nvim/\n",
            "git@github.com:jrosiek/difftastic.nvim.git",
            "ssh://git@github.com/jrosiek/difftastic.nvim.git",
        }) do
            assert.are.equal("jrosiek/difftastic.nvim", binary.github_repo(url), url)
        end
    end)

    it("gives nothing for other hosts", function()
        assert.is_nil(binary.github_repo("https://gitlab.com/someone/difftastic.nvim.git"))
        assert.is_nil(binary.github_repo("/home/someone/difftastic.nvim"))
    end)
end)

describe("downloaded library from another repository", function()
    local original_stdpath, original_system, data, curl_calls, repo

    local lib_name = jit.os == "OSX" and "libdifftastic_nvim.dylib"
        or (jit.os == "Windows" and "difftastic_nvim.dll" or "libdifftastic_nvim.so")

    before_each(function()
        data = vim.fn.resolve(vim.fn.tempname())
        vim.fn.mkdir(data .. "/difftastic-nvim", "p")
        vim.fn.writefile({ "not a library" }, data .. "/difftastic-nvim/" .. lib_name)
        original_stdpath, original_system = vim.fn.stdpath, vim.system
        vim.fn.stdpath = function(what)
            return what == "data" and data or original_stdpath(what)
        end
        -- No network: requests to GitHub are recorded, not sent.
        curl_calls = {}
        vim.system = function(cmd, opts, on_exit)
            if cmd[1] == "curl" then
                table.insert(curl_calls, cmd)
                return { wait = function() return { code = 1 } end }
            end
            return original_system(cmd, opts, on_exit)
        end
        local plugin_root = vim.fn.fnamemodify(vim.api.nvim_get_runtime_file("lua/difftastic-nvim/binary.lua", false)[1], ":h:h:h")
        local origin = original_system({ "git", "-C", plugin_root, "remote", "get-url", "origin" }, { text = true }):wait()
        repo = origin.code == 0 and binary.github_repo(origin.stdout) or "clabby/difftastic.nvim"
    end)

    after_each(function()
        vim.fn.stdpath, vim.system = original_stdpath, original_system
        binary.state = "ready"
        vim.fn.delete(data, "rf")
    end)

    local function lib_present()
        return vim.uv.fs_stat(data .. "/difftastic-nvim/" .. lib_name) ~= nil
    end

    it("is deleted, so it is downloaded anew", function()
        vim.fn.writefile({ "someone/other.nvim@v0.1.1" }, data .. "/difftastic-nvim/.version")
        binary.ensure_exists(true)
        assert.is_false(lib_present())
    end)

    it("is deleted when its version names no repository", function()
        vim.fn.writefile({ "v0.1.1" }, data .. "/difftastic-nvim/.version")
        binary.ensure_exists(true)
        assert.is_false(lib_present())
    end)

    it("is kept when it comes from the plugin's repository", function()
        vim.fn.writefile({ repo .. "@v0.1.1" }, data .. "/difftastic-nvim/.version")
        binary.ensure_exists(true)
        assert.is_true(lib_present())
    end)

    it("is kept without download", function()
        vim.fn.writefile({ "someone/other.nvim@v0.1.1" }, data .. "/difftastic-nvim/.version")
        binary.ensure_exists(false)
        assert.is_true(lib_present())
        assert.are.same({}, curl_calls)
    end)
end)

describe("release matching the installed plugin", function()
    local plugin_root = vim.fn.fnamemodify(vim.api.nvim_get_runtime_file("lua/difftastic-nvim/binary.lua", false)[1], ":h:h:h")
    local tag = "v0.1.1"
    -- A shallow clone (as in CI) has no tags to compare with.
    if vim.system({ "git", "-C", plugin_root, "merge-base", "--is-ancestor", tag, "HEAD" }):wait().code ~= 0 then
        it("is skipped without the tag " .. tag .. " in the plugin clone", function() end)
        return
    end

    local original_stdpath, original_system, data, downloads

    --- Assets of a release for every platform, each URL naming the release.
    local function assets(release)
        local list = {}
        for _, name in ipairs({
            "x86_64-unknown-linux-gnu.so",
            "aarch64-unknown-linux-gnu.so",
            "x86_64-apple-darwin.dylib",
            "aarch64-apple-darwin.dylib",
            "x86_64-pc-windows-msvc.dll",
        }) do
            table.insert(list, { name = name, browser_download_url = release .. "/" .. name })
        end
        return list
    end

    before_each(function()
        data = vim.fn.resolve(vim.fn.tempname())
        original_stdpath, original_system = vim.fn.stdpath, vim.system
        vim.fn.stdpath = function(what)
            return what == "data" and data or original_stdpath(what)
        end
        -- GitHub lists, newest first, a release after HEAD, the newest one at or
        -- before it, and an older one. Downloads are recorded, not made.
        downloads = {}
        vim.system = function(cmd, opts, on_exit)
            if cmd[1] ~= "curl" then
                return original_system(cmd, opts, on_exit)
            end
            if cmd[3] == "-o" then
                table.insert(downloads, cmd[5])
                on_exit({ code = 0 })
            else
                on_exit({
                    code = 0,
                    stdout = vim.json.encode({
                        { tag_name = "v99.0.0", assets = assets("v99.0.0") },
                        { tag_name = tag, assets = assets(tag) },
                        { tag_name = "v0.0.1", assets = assets("v0.0.1") },
                    }),
                })
            end
            return {}
        end
    end)

    after_each(function()
        vim.fn.stdpath, vim.system = original_stdpath, original_system
        binary.state = "ready"
        vim.fn.delete(data, "rf")
    end)

    it("is the newest release at or before HEAD", function()
        binary.update()
        vim.wait(2000, function()
            return binary.state ~= "downloading"
        end)

        assert.are.equal("ready", binary.state)
        assert.are.equal(1, #downloads)
        assert.truthy(vim.startswith(downloads[1], tag .. "/"))
        local version = vim.fn.readfile(data .. "/difftastic-nvim/.version")[1]
        assert.truthy(vim.endswith(version, "@" .. tag))
    end)
end)

describe("difft", function()
    local original_stdpath, original_system, original_path, data

    local exe = jit.os == "Windows" and "difft.exe" or "difft"
    --- PATH without any directory holding a difft.
    local function path_without_difft()
        local dirs = {}
        for _, dir in ipairs(vim.split(vim.env.PATH or "", ":", { plain = true })) do
            if vim.fn.executable(dir .. "/difft") ~= 1 then
                table.insert(dirs, dir)
            end
        end
        return table.concat(dirs, ":")
    end

    before_each(function()
        data = vim.fn.resolve(vim.fn.tempname())
        vim.fn.mkdir(data .. "/difftastic-nvim", "p")
        original_stdpath, original_system, original_path = vim.fn.stdpath, vim.system, vim.env.PATH
        vim.fn.stdpath = function(what)
            return what == "data" and data or original_stdpath(what)
        end
    end)

    after_each(function()
        vim.fn.stdpath, vim.system, vim.env.PATH = original_stdpath, original_system, original_path
        binary.difft_state = "none"
        -- update() downloads the library too, which fails here.
        binary.state = "ready"
        vim.fn.delete(data, "rf")
    end)

    it("prefers the downloaded difft, next to the library", function()
        assert.is_nil(binary.difft_path())
        local file = data .. "/difftastic-nvim/" .. exe
        vim.fn.writefile({ "#!/bin/sh" }, file)
        vim.uv.fs_chmod(file, tonumber("755", 8))
        assert.are.equal(file, binary.difft_path())
    end)

    it("says what to do when no difft can run", function()
        vim.env.PATH = path_without_difft()
        assert.truthy(binary.missing_difft():find("difft (difftastic) not found", 1, true))
        assert.is_nil(binary.waiting_for())
        vim.env.PATH = original_path
        if vim.fn.executable("difft") == 1 then
            assert.is_nil(binary.missing_difft())
        end
    end)

    it("is not waited for when the library downloads or builds, while one is loaded", function()
        local loaded = pcall(binary.get)
        for _, state in ipairs({ "downloading", "building" }) do
            binary.state = state
            if loaded then
                assert.is_nil(binary.waiting_for())
            else
                assert.truthy(binary.waiting_for():find("the library", 1, true))
            end
        end
    end)

    it("is waited for while it downloads, only when none is on PATH", function()
        binary.difft_state = "downloading"
        vim.env.PATH = path_without_difft()
        assert.are.equal("Downloading difft…", binary.waiting_for())
        vim.env.PATH = original_path
        if vim.fn.executable("difft") == 1 then
            assert.is_nil(binary.waiting_for())
        end
    end)

    it("is downloaded from the fork's latest release, executable, with its version", function()
        local calls = {}
        vim.system = function(cmd, opts, on_exit)
            table.insert(calls, cmd)
            if cmd[1] == "curl" and cmd[3] == "-o" then
                vim.fn.writefile({ "archive" }, cmd[4])
                on_exit({ code = 0 })
            elseif cmd[1] == "curl" then
                local url = cmd[#cmd]
                if url:find("jrosiek/difftastic/releases/latest", 1, true) then
                    local assets = {}
                    for _, triple in ipairs({ "x86_64-unknown-linux-gnu", "aarch64-unknown-linux-gnu", "x86_64-apple-darwin", "aarch64-apple-darwin" }) do
                        table.insert(assets, { name = "difft-0.71.0+jr.1-" .. triple .. ".tar.gz", browser_download_url = "https://example.invalid/" .. triple })
                    end
                    table.insert(assets, { name = "difft-0.71.0+jr.1-x86_64-pc-windows-msvc.zip", browser_download_url = "https://example.invalid/windows" })
                    on_exit({ code = 0, stdout = vim.json.encode({ tag_name = "0.71.0+jr.1", assets = assets }) })
                else
                    on_exit({ code = 1, stdout = "" })
                end
            elseif cmd[1] == "tar" then
                -- Unpacks the binary without its executable flag.
                vim.fn.writefile({ "#!/bin/sh" }, cmd[5] .. "/" .. exe)
                on_exit({ code = 0 })
            else
                return original_system(cmd, opts, on_exit)
            end
            return {}
        end

        binary.update()
        vim.wait(2000, function()
            return binary.difft_state == "ready" or binary.difft_state == "failed"
        end)

        assert.are.equal("ready", binary.difft_state)
        local file = data .. "/difftastic-nvim/" .. exe
        assert.are.equal(file, binary.difft_path())
        assert.are.equal("jrosiek/difftastic@0.71.0+jr.1", vim.fn.readfile(data .. "/difftastic-nvim/.difft-version")[1])
        assert.is_nil(vim.uv.fs_stat(data .. "/difftastic-nvim/difft-download"))
    end)
end)

describe("difft the library runs", function()
    local lib_ok, lib = pcall(binary.get)
    local difft = vim.fn.exepath("difft")
    if not (lib_ok and lib.set_difft and difft ~= "" and vim.fn.executable("git") == 1) then
        it("is skipped without the native library, difft or git", function() end)
        return
    end

    local repo, original_path

    local function run(cmd, cwd)
        local out = vim.system(cmd, { text = true, cwd = cwd }):wait()
        assert(out.code == 0, table.concat(cmd, " ") .. ": " .. (out.stderr or ""))
    end

    before_each(function()
        original_path = vim.env.PATH
        repo = vim.fn.resolve(vim.fn.tempname())
        vim.fn.mkdir(repo, "p")
    end)

    after_each(function()
        vim.env.PATH = original_path
        lib.set_difft(nil)
        vim.fn.delete(repo, "rf")
    end)

    --- PATH without the directory of difft (and any other holding one).
    local function hide_difft()
        local dirs = {}
        for _, dir in ipairs(vim.split(original_path, ":", { plain = true })) do
            if vim.fn.executable(dir .. "/difft") ~= 1 then
                table.insert(dirs, dir)
            end
        end
        vim.env.PATH = table.concat(dirs, ":")
    end

    it("is the one set, not difft from PATH, for git", function()
        run({ "git", "init", "-q" }, repo)
        run({ "git", "config", "user.email", "t@t" }, repo)
        run({ "git", "config", "user.name", "t" }, repo)
        vim.fn.writefile({ "one" }, repo .. "/a.txt")
        run({ "git", "add", "-A" }, repo)
        run({ "git", "commit", "-q", "-m", "one" }, repo)
        vim.fn.writefile({ "two" }, repo .. "/a.txt")
        hide_difft()
        if vim.fn.executable("git") ~= 1 then
            return -- git lives next to difft here
        end

        assert.has_error(function()
            lib.run_diff_unstaged("git", 0, repo)
        end)
        lib.set_difft(difft)
        assert.are.equal("a.txt", lib.run_diff_unstaged("git", 0, repo).files[1].path)
    end)

    it("is the one set, not difft from PATH, for jj", function()
        if vim.fn.executable("jj") ~= 1 then
            return
        end
        local env = { JJ_USER = vim.env.JJ_USER, JJ_EMAIL = vim.env.JJ_EMAIL }
        vim.env.JJ_USER, vim.env.JJ_EMAIL = "t", "t@t"
        run({ "jj", "git", "init" }, repo)
        vim.fn.writefile({ "one" }, repo .. "/a.txt")
        run({ "jj", "commit", "-m", "one" }, repo)
        vim.fn.writefile({ "two" }, repo .. "/a.txt")
        hide_difft()
        local ok = vim.fn.executable("jj") == 1
        if ok then
            lib.set_difft(difft)
            assert.are.equal("a.txt", lib.run_diff_unstaged("jj", 0, repo).files[1].path)
        end
        vim.env.JJ_USER, vim.env.JJ_EMAIL = env.JJ_USER, env.JJ_EMAIL
    end)
end)
