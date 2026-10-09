--- :checkhealth difftastic-nvim reports the library and the difft in use.

local binary = require("difftastic-nvim.binary")

describe(":checkhealth difftastic-nvim", function()
    local original_info

    before_each(function()
        original_info = binary.info
    end)

    after_each(function()
        binary.info = original_info
        vim.cmd("silent! bwipeout!")
    end)

    local function report()
        vim.cmd("checkhealth difftastic-nvim")
        return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    end

    it("names the library and the difft in use, with where they come from", function()
        binary.info = function()
            return {
                platform = "x86_64-unknown-linux-gnu",
                state = "ready",
                loaded = true,
                async = true,
                lib_path = "/data/libdifftastic_nvim.so",
                lib_source = "downloaded",
                lib_version = "jrosiek/difftastic.nvim@v0.2.0",
                lib_repo = "jrosiek/difftastic.nvim",
                difft_path = vim.fn.exepath("nvim"),
                difft_source = "downloaded",
                difft_version = "jrosiek/difftastic@0.71.0+jr.1",
                difft_repo = "jrosiek/difftastic",
                difft_state = "ready",
            }
        end

        local text = report()
        assert.truthy(text:find("downloaded: /data/libdifftastic_nvim.so", 1, true), text)
        assert.truthy(text:find("jrosiek/difftastic.nvim@v0.2.0", 1, true), text)
        -- The program's own version line ("NVIM v…" here) and where it is.
        assert.truthy(text:find("NVIM v", 1, true), text)
        assert.truthy(text:find("jrosiek/difftastic@0.71.0+jr.1", 1, true), text)
    end)

    it("says how to get what is missing", function()
        binary.info = function()
            return {
                platform = "x86_64-unknown-linux-gnu",
                state = "failed",
                loaded = false,
                lib_repo = "jrosiek/difftastic.nvim",
                difft_repo = "jrosiek/difftastic",
                difft_state = "failed",
            }
        end

        local text = report()
        assert.truthy(text:find("cargo build --release", 1, true), text)
        assert.falsy(text:find("Failed to run healthcheck", 1, true), text)
        assert.truthy(text:find("https://difftastic.wilfred.me.uk", 1, true), text)
    end)
end)
