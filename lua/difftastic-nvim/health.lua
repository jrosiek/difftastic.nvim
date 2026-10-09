--- :checkhealth difftastic-nvim: the library and the difft the plugin uses.
local M = {}

--- The first line `cmd` prints, or nil when it cannot run.
local function first_output_line(cmd)
    local ok, result = pcall(function()
        return vim.system(cmd, { text = true }):wait(5000)
    end)
    if not ok or result.code ~= 0 then
        return nil
    end
    return vim.split(result.stdout or "", "\n", { plain = true })[1]
end

function M.check()
    local binary = require("difftastic-nvim.binary")
    -- The settings of setup(), if the plugin is loaded; loading it here would
    -- fail without nui.nvim, which this check reports instead.
    local plugin = package.loaded["difftastic-nvim"]
    local download = plugin and plugin.config.download
    local info = binary.info()

    vim.health.start("difftastic-nvim: dependencies")
    if pcall(require, "nui.tree") then
        vim.health.ok("nui.nvim")
    else
        vim.health.error("nui.nvim not found", { "Install MunifTanjim/nui.nvim, which the side panel needs" })
    end

    vim.health.start("difftastic-nvim: library")
    if not info.platform then
        vim.health.warn("No prebuilt library for this platform (" .. jit.os .. " " .. jit.arch .. "): build it with `cargo build --release`")
    end
    if info.lib_path then
        vim.health.ok(("%s: %s"):format(info.lib_source, info.lib_path))
        if info.lib_version then
            vim.health.info("Downloaded release: " .. info.lib_version)
        end
    elseif info.state == "downloading" then
        vim.health.warn("Still downloading from " .. info.lib_repo)
    elseif info.state == "building" then
        vim.health.warn("Still building from source")
    else
        vim.health.error("Not found", {
            "Set `download = true` in setup() to download it from " .. info.lib_repo,
            "or build it with `cargo build --release` in the plugin's directory",
        })
    end
    if info.loaded and not info.async then
        vim.health.warn("This library cannot compute diffs in the background: Neovim waits while a diff loads")
    end
    if plugin then
        vim.health.info("Download: " .. (download and ("on, from " .. info.lib_repo) or "off"))
    end

    vim.health.start("difftastic-nvim: difft")
    if info.difft_path then
        local version = first_output_line({ info.difft_path, "--version" }) or "version unknown"
        vim.health.ok(("%s (%s): %s"):format(version, info.difft_source, info.difft_path))
        if info.difft_version then
            vim.health.info("Downloaded release: " .. info.difft_version)
        end
    elseif info.difft_state == "downloading" then
        vim.health.warn("Still downloading from " .. info.difft_repo)
    else
        vim.health.error("Not found", {
            "Install difftastic (https://difftastic.wilfred.me.uk)",
            "or set `download = true` in setup() to download it from " .. info.difft_repo,
        })
    end
    if download and info.difft_source == "PATH" then
        vim.health.info(("Not downloaded (yet) from %s: using difft from PATH"):format(info.difft_repo))
    end
end

return M
