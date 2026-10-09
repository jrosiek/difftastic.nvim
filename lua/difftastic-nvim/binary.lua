--- Binary management: loading, downloading, and building.
local M = {}

--- Repository releases are downloaded from when the plugin is not a clone of a
--- GitHub repository.
local DEFAULT_REPO = "clabby/difftastic.nvim"

--- The "owner/name" of a GitHub remote URL (https, ssh or scp-like form), or nil
--- for a URL of another host.
--- @param url string
--- @return string|nil
function M.github_repo(url)
    local repo = vim.trim(url):gsub("/$", ""):match("github%.com[:/]([^/]+/[^/]+)$")
    return repo and (repo:gsub("%.git$", ""))
end

--- Repository to download releases from: the one the plugin was cloned from, so a
--- fork gets its own releases, else the default.
--- @param plugin_root string
--- @return string
local function release_repo(plugin_root)
    local result = vim.system({ "git", "-C", plugin_root, "remote", "get-url", "origin" }, { text = true }):wait()
    return result.code == 0 and M.github_repo(result.stdout) or DEFAULT_REPO
end

--- Platform detection
--- @return string|nil platform Triple like "aarch64-apple-darwin"
--- @return string|nil ext Library extension like ".dylib"
local function get_platform()
    local os_name = jit.os:lower()
    local arch = jit.arch:lower()

    if os_name == "osx" then
        local triple = arch == "arm64" and "aarch64-apple-darwin" or "x86_64-apple-darwin"
        return triple, ".dylib"
    elseif os_name == "linux" then
        local triple = arch == "arm64" and "aarch64-unknown-linux-gnu" or "x86_64-unknown-linux-gnu"
        return triple, ".so"
    elseif os_name == "windows" then
        return "x86_64-pc-windows-msvc", ".dll"
    end

    return nil, nil
end

--- Get the library filename for a given extension.
--- @param ext string|nil Library extension
--- @return string
local function get_lib_name(ext)
    if ext == ".dylib" then
        return "libdifftastic_nvim.dylib"
    elseif ext == ".dll" then
        return "difftastic_nvim.dll"
    else
        return "libdifftastic_nvim.so"
    end
end

--- Get paths used for library storage.
--- @return table { plugin_root: string, data_dir: string, release_dir: string }
local function get_paths()
    local source = debug.getinfo(1, "S").source:sub(2)
    local plugin_root = vim.fn.fnamemodify(source, ":h:h:h")
    local data_dir = vim.fn.stdpath("data") .. "/difftastic-nvim"

    return {
        plugin_root = plugin_root,
        data_dir = data_dir,
        release_dir = plugin_root .. "/target/release",
    }
end

--- Check if library exists in any of the expected locations.
--- @param paths table Path configuration
--- @param ext string|nil Library extension
--- @return boolean
local function lib_exists(paths, ext)
    local lib_name = get_lib_name(ext)
    return vim.uv.fs_stat(paths.data_dir .. "/" .. lib_name) ~= nil
        or vim.uv.fs_stat(paths.release_dir .. "/" .. lib_name) ~= nil
end

--- Try to load the library from a directory.
--- @param dir string Directory to load from
--- @param ext string|nil Library extension
--- @return table|nil Loaded library or nil
local function try_load_lib(dir, ext)
    local lib_name = get_lib_name(ext)
    local lib_path = dir .. "/" .. lib_name

    if not vim.uv.fs_stat(lib_path) then
        return nil
    end

    if ext == ".dll" then
        package.cpath = dir .. "/?.dll;" .. package.cpath
    else
        -- macOS/Linux: cargo produces lib*.dylib/lib*.so but Lua wants *.so
        local so_path = dir .. "/difftastic_nvim.so"
        if not vim.uv.fs_stat(so_path) then
            local ok, err = pcall(vim.uv.fs_symlink, lib_path, so_path)
            if not ok then
                vim.notify("difftastic-nvim: Failed to create symlink: " .. tostring(err), vim.log.levels.WARN)
            end
        end
        package.cpath = dir .. "/?.so;" .. package.cpath
    end

    local ok, lib = pcall(require, "difftastic_nvim")
    return ok and lib or nil
end

--- Version file management
local function get_version_file(paths)
    return paths.data_dir .. "/.version"
end

local function read_version(paths)
    local f = io.open(get_version_file(paths), "r")
    if not f then
        return nil
    end
    local version = f:read("*l")
    f:close()
    return version
end

local function write_version(paths, version)
    local f = io.open(get_version_file(paths), "w")
    if f then
        f:write(version)
        f:close()
    end
end

--- Delete the downloaded library, so the next load cannot pick it up.
--- @param paths table Path configuration
--- @param ext string|nil Library extension
local function remove_downloaded(paths, ext)
    vim.uv.fs_unlink(paths.data_dir .. "/" .. get_lib_name(ext))
    vim.uv.fs_unlink(paths.data_dir .. "/difftastic_nvim.so")
end

--- State machine for build/download status
--- @type "ready"|"building"|"downloading"|"failed"
M.state = "ready"

--- Cached library reference
local cached_lib = nil

--- The release whose library matches the installed plugin: the newest release
--- at or before the clone's HEAD, or the latest release when the plugin is not
--- a git clone. Calls `on_done(release, repo)` on the main thread, `release` nil
--- (and an error message) when none is found.
--- @param paths table Path configuration
--- @param on_done fun(release: table|nil, repo: string, err: string|nil)
local function find_matching_release(paths, on_done)
    local repo = release_repo(paths.plugin_root)
    -- ponytail: first 100 releases only (newest first); page if a repo ever has more.
    local url = "https://api.github.com/repos/" .. repo .. "/releases?per_page=100"
    vim.system({ "curl", "-sL", url }, { text = true }, function(result)
        vim.schedule(function()
            local ok, releases = pcall(vim.json.decode, result.stdout or "")
            if result.code ~= 0 or not ok or type(releases) ~= "table" or not vim.islist(releases) then
                on_done(nil, repo, "Failed to fetch releases of " .. repo)
                return
            end
            local function git(...)
                return vim.system({ "git", "-C", paths.plugin_root, ... }):wait().code == 0
            end
            if not git("rev-parse", "--git-dir") then
                return on_done(releases[1], repo, releases[1] == nil and ("No release found in " .. repo) or nil)
            end
            for _, release in ipairs(releases) do
                if git("merge-base", "--is-ancestor", release.tag_name, "HEAD") then
                    return on_done(release, repo)
                end
            end
            on_done(nil, repo, "No release of " .. repo .. " at or before the installed plugin version")
        end)
    end)
end

--- Download the library of the release matching the installed plugin (async).
--- @param paths table Path configuration
--- @param platform string Platform triple
--- @param ext string|nil Library extension
--- @param on_complete function|nil Callback with success boolean
local function download_binary(paths, platform, ext, on_complete)
    M.state = "downloading"
    vim.notify("difftastic-nvim: Downloading binary...", vim.log.levels.INFO)
    vim.fn.mkdir(paths.data_dir, "p")

    local function fail(message)
        M.state = "failed"
        vim.notify("difftastic-nvim: " .. message, vim.log.levels.ERROR)
        if on_complete then
            on_complete(false)
        end
    end

    find_matching_release(paths, function(release, repo, err)
        if not release then
            return fail(err)
        end

        -- Find matching asset
        local asset_name = platform .. ext
        local download_url = nil
        for _, asset in ipairs(release.assets or {}) do
            if asset.name == asset_name then
                download_url = asset.browser_download_url
                break
            end
        end
        if not download_url then
            return fail("No binary for " .. platform .. " in " .. repo .. "@" .. release.tag_name)
        end

        local dest = paths.data_dir .. "/" .. get_lib_name(ext)
        vim.system({ "curl", "-sL", "-o", dest, download_url }, {}, function(dl_result)
            vim.schedule(function()
                if dl_result.code ~= 0 then
                    return fail("Download failed")
                end
                write_version(paths, repo .. "@" .. release.tag_name)
                M.state = "ready"
                local message = "difftastic-nvim: Downloaded " .. repo .. "@" .. release.tag_name
                if cached_lib then
                    message = message .. "; restart Neovim to use it"
                end
                vim.notify(message, vim.log.levels.INFO)
                if on_complete then
                    on_complete(true)
                end
            end)
        end)
    end)
end

--- Replace the downloaded library when it is not the one of the release matching
--- the installed plugin, e.g. after the plugin was updated (async).
--- @param paths table Path configuration
--- @param platform string Platform triple
--- @param ext string|nil Library extension
local function replace_if_outdated(paths, platform, ext)
    find_matching_release(paths, function(release, repo)
        -- Nothing to compare with (offline, no release): keep what there is.
        if release and read_version(paths) ~= repo .. "@" .. release.tag_name then
            remove_downloaded(paths, ext)
            download_binary(paths, platform, ext)
        end
    end)
end

--- Build library from source (async).
--- @param paths table Path configuration
local function build_from_source(paths)
    M.state = "building"
    vim.notify("difftastic-nvim: Building from source...", vim.log.levels.INFO)

    vim.system({ "cargo", "build", "--release" }, { cwd = paths.plugin_root, text = true }, function(result)
        vim.schedule(function()
            if result.code == 0 then
                M.state = "ready"
                vim.notify("difftastic-nvim: Build complete", vim.log.levels.INFO)
            else
                M.state = "failed"
                vim.notify(
                    "difftastic-nvim: Build failed: " .. (result.stderr or "unknown error"),
                    vim.log.levels.ERROR
                )
            end
        end)
    end)
end

--- Ensure library exists, triggering download or build if needed.
--- Called at setup time.
--- @param download_enabled boolean Whether auto-download is enabled
function M.ensure_exists(download_enabled)
    local platform, ext = get_platform()
    local paths = get_paths()

    -- A library downloaded from another repository (e.g. upstream's, before
    -- switching to a fork) does not belong to this plugin: removed now, so it is
    -- never loaded, and downloaded anew. The version is `<repo>@<tag>`; upstream's
    -- format, the tag alone, counts as another repository.
    local version = read_version(paths)
    if download_enabled and platform and version and not vim.startswith(version, release_repo(paths.plugin_root) .. "@") then
        remove_downloaded(paths, ext)
    end

    if lib_exists(paths, ext) then
        M.state = "ready"
        -- A local build is loaded first, so the downloaded library only matters
        -- without one.
        local local_build = vim.uv.fs_stat(paths.release_dir .. "/" .. get_lib_name(ext))
        if download_enabled and platform and not local_build then
            replace_if_outdated(paths, platform, ext)
        end
        return
    end

    -- Try auto-download
    if download_enabled and platform then
        download_binary(paths, platform, ext)
        return
    end

    -- Try building from source
    local cargo_toml = paths.plugin_root .. "/Cargo.toml"
    if vim.uv.fs_stat(cargo_toml) then
        build_from_source(paths)
        return
    end

    -- No way to get the library
    M.state = "failed"
    vim.notify(
        string.format(
            "difftastic-nvim: Could not find %s.\nSet download = true, or install Rust toolchain.",
            get_lib_name(ext or ".so")
        ),
        vim.log.levels.ERROR
    )
end

--- Get the loaded library, erroring if not available.
--- @return table The loaded Rust library
function M.get()
    if cached_lib then
        return cached_lib
    end

    if M.state == "building" then
        error("difftastic-nvim: Still building, please wait...")
    elseif M.state == "downloading" then
        error("difftastic-nvim: Still downloading, please wait...")
    elseif M.state == "failed" then
        error("difftastic-nvim: Library not available. Check :messages for details.")
    end

    local _, ext = get_platform()
    local paths = get_paths()

    -- Prefer local development build in target/release over downloaded binary.
    cached_lib = try_load_lib(paths.release_dir, ext) or try_load_lib(paths.data_dir, ext)

    if cached_lib then
        return cached_lib
    end

    error("difftastic-nvim: Library not found.")
end

--- Download the library of the release matching the installed plugin again.
function M.update()
    local platform, ext = get_platform()
    if not platform then
        vim.notify("difftastic-nvim: Unsupported platform", vim.log.levels.ERROR)
        return
    end

    local paths = get_paths()

    remove_downloaded(paths, ext)

    -- Clear cache
    package.loaded["difftastic_nvim"] = nil
    cached_lib = nil

    download_binary(paths, platform, ext)
end


return M
