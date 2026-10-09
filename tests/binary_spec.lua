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
