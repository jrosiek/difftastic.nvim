-- Opening the diff view needs nui.nvim, which plugin managers install next to plenary.
if not pcall(require, "nui.tree") then
    local plenary_dir = vim.api.nvim_get_runtime_file("lua/plenary", false)[1]
    if plenary_dir then
        vim.opt.rtp:append(vim.fn.fnamemodify(plenary_dir, ":h:h:h") .. "/nui.nvim")
    end
end

local fold = require("difftastic-nvim.fold")

--- Rows from a pattern, one character per row: "." unchanged, "x" changed (both
--- sides highlighted), "L" / "R" changed on the left / right side only, "f" a
--- filler row (added line: filler on the left), "h" unchanged but a hunk start.
--- @return table[] rows, number[] hunk_starts
local function rows_from(pattern)
    local rows, hunk_starts = {}, {}
    for i = 1, #pattern do
        local c = pattern:sub(i, i)
        local hl = { { start = 0, ["end"] = -1 } }
        local row = {
            left = { content = "l" .. i, highlights = {}, is_filler = false },
            right = { content = "r" .. i, highlights = {}, is_filler = false },
        }
        if c == "x" then
            row.left.highlights, row.right.highlights = hl, hl
        elseif c == "L" then
            row.left.highlights = hl
        elseif c == "R" then
            row.right.highlights = hl
        elseif c == "f" then
            row.left.is_filler, row.left.content = true, ""
            row.right.highlights = hl
        elseif c == "h" then
            table.insert(hunk_starts, i - 1)
        end
        rows[i] = row
    end
    return rows, hunk_starts
end

local function ranges(pattern, context, min_size)
    local rows, hunk_starts = rows_from(pattern)
    return fold.ranges(rows, hunk_starts, context, min_size)
end

--- Reference rule: a line is folded when it is unchanged, more than `context`
--- lines from every change, and its run of such lines has `min_size` lines or more.
local function reference(pattern, context, min_size)
    local count = #pattern
    local changes = {}
    for i = 1, count do
        if pattern:sub(i, i) ~= "." then
            table.insert(changes, i)
        end
    end
    local foldable = {}
    for i = 1, count do
        local ok = pattern:sub(i, i) == "."
        for _, c in ipairs(changes) do
            if math.abs(i - c) <= context then
                ok = false
            end
        end
        foldable[i] = ok
    end
    local result, i = {}, 1
    while i <= count do
        if foldable[i] then
            local first = i
            while i <= count and foldable[i] do
                i = i + 1
            end
            if i - first >= min_size then
                table.insert(result, { first, i - 1 })
            end
        else
            i = i + 1
        end
    end
    return result
end

describe("fold.ranges", function()
    -- { name, pattern, context, min_size, expected }
    local cases = {
        { "no rows", "", 3, 2, {} },
        { "no changes: one fold over the whole file", "..........", 3, 2, { { 1, 10 } } },
        { "no changes, file shorter than min_fold_size", ".", 3, 2, {} },
        { "no changes, file exactly min_fold_size", "..", 3, 2, { { 1, 2 } } },
        { "one change covering the whole file", "xxxxxxxx", 3, 2, {} },
        { "single changed line, nothing else", "x", 3, 1, {} },
        { "change on the first line", "x.........", 3, 2, { { 5, 10 } } },
        { "change on the last line", ".........x", 3, 2, { { 1, 6 } } },
        { "changes on the first and last lines", "x..........x", 3, 2, { { 5, 8 } } },
        { "change in the middle", "..........x..........", 3, 2, { { 1, 7 }, { 15, 21 } } },
        { "two changes exactly 2*context apart: nothing to fold", "x......x", 3, 1, {} },
        { "two changes 2*context+1 apart: one line folds", "x.......x", 3, 1, { { 5, 5 } } },
        { "same, but min_fold_size 2 keeps it unfolded", "x.......x", 3, 2, {} },
        { "two changes 2*context+2 apart: two lines fold", "x........x", 3, 2, { { 5, 6 } } },
        { "context larger than the file", "...x...", 10, 1, {} },
        { "context 1", "...x...", 1, 1, { { 1, 2 }, { 6, 7 } } },
        { "filler rows are changes", "....f....", 2, 1, { { 1, 2 }, { 8, 9 } } },
        { "a change on one side only counts", "....L....R....", 1, 1, { { 1, 3 }, { 7, 8 }, { 12, 14 } } },
        { "a hunk start counts as a change", "....h....", 2, 1, { { 1, 2 }, { 8, 9 } } },
        { "run just under min_fold_size", "x....x", 1, 3, {} },
        { "run at min_fold_size", "x.....x", 1, 3, { { 3, 5 } } },
        { "run just over min_fold_size", "x......x", 1, 3, { { 3, 6 } } },
        { "several hunks", "..x.....xx.......x..", 2, 2, { { 13, 15 } } },
        { "several hunks, min_fold_size 1", "..x.....xx.......x..", 2, 1, { { 6, 6 }, { 13, 15 } } },
    }
    for _, case in ipairs(cases) do
        local name, pattern, context, min_size, expected = unpack(case)
        it(("%s (%q, context %d, min %d)"):format(name, pattern, context, min_size), function()
            assert.are.same(expected, ranges(pattern, context, min_size))
        end)
    end

    it("never folds a changed line or a line within context of one", function()
        for _, case in ipairs(cases) do
            local _, pattern, context, min_size = unpack(case)
            for _, range in ipairs(ranges(pattern, context, min_size)) do
                for line = range[1], range[2] do
                    for d = -context, context do
                        local at = line + d
                        local c = at >= 1 and pattern:sub(at, at) or ""
                        assert.is_true(c == "" or c == ".", ("%q line %d"):format(pattern, line))
                    end
                end
            end
        end
    end)

    it("matches the reference rule on random files", function()
        math.randomseed(42)
        local alphabet = { ".", ".", ".", ".", ".", "x", "f", "L", "R", "h" }
        for _ = 1, 2000 do
            local length = math.random(0, 40)
            local chars = {}
            local density = math.random()
            for i = 1, length do
                chars[i] = math.random() < density and alphabet[math.random(6, #alphabet)] or "."
            end
            local pattern = table.concat(chars)
            local context, min_size = math.random(1, 6), math.random(1, 5)
            assert.are.same(reference(pattern, context, min_size), ranges(pattern, context, min_size), ("%q context %d min %d"):format(pattern, context, min_size))
        end
    end)
end)

describe("folds in the diff view", function()
    local difft = require("difftastic-nvim")
    local binary = require("difftastic-nvim.binary")
    local original_get, original_config, files

    --- A file record built from a pattern (see rows_from).
    local function record(path, pattern)
        local rows, hunk_starts = rows_from(pattern)
        local starts = vim.deepcopy(hunk_starts)
        for i = 1, #pattern do
            local c, prev = pattern:sub(i, i), pattern:sub(i - 1, i - 1)
            if c ~= "." and c ~= "h" and (prev == "" or prev == ".") then
                table.insert(starts, i - 1)
            end
        end
        table.sort(starts)
        return {
            path = path,
            status = "changed",
            language = "Text",
            additions = 1,
            deletions = 1,
            hunk_starts = starts,
            aligned_lines = {},
            rows = rows,
        }
    end

    before_each(function()
        original_config = vim.deepcopy(difft.config)
        difft.config.vcs = "git"
        files = {
            record("a.txt", string.rep(".", 20) .. "x" .. string.rep(".", 20) .. "xx" .. string.rep(".", 10)),
            record("b.txt", string.rep(".", 15)),
        }
        original_get = binary.get
        binary.get = function()
            return {
                run_diff = function()
                    return { files = files }
                end,
            }
        end
    end)

    after_each(function()
        difft.close()
        binary.get = original_get
        difft.config = original_config
    end)

    --- Folds of a window as { first, last, closed } for each top-level fold.
    local function folds(win)
        return vim.api.nvim_win_call(win, function()
            local result, line, count = {}, 1, vim.api.nvim_buf_line_count(0)
            while line <= count do
                if vim.fn.foldlevel(line) > 0 then
                    local closed = vim.fn.foldclosed(line) ~= -1
                    vim.cmd(("silent! %dfoldclose"):format(line))
                    local first, last = vim.fn.foldclosed(line), vim.fn.foldclosedend(line)
                    if not closed then
                        vim.cmd(("silent! %dfoldopen"):format(line))
                    end
                    table.insert(result, { first, last, closed })
                    line = last + 1
                else
                    line = line + 1
                end
            end
            return result
        end)
    end

    local function show(path)
        for idx, file in ipairs(difft.state.files) do
            if file.path == path then
                difft.show_file(idx)
                return
            end
        end
    end

    it("folds unchanged lines in both panes, closed by default", function()
        difft.open("HEAD")
        show("a.txt")

        local expected = { { 1, 17, true }, { 25, 38, true }, { 47, 53, true } }
        assert.are.same(expected, folds(difft.state.left_win))
        assert.are.same(expected, folds(difft.state.right_win))
    end)

    it("leaves the folds open with fold_by_default = false", function()
        difft.config.fold_by_default = false
        difft.open("HEAD")
        show("a.txt")

        local expected = { { 1, 17, false }, { 25, 38, false }, { 47, 53, false } }
        assert.are.same(expected, folds(difft.state.left_win))
        assert.are.same(expected, folds(difft.state.right_win))
    end)

    for _, case in ipairs({
        { context = 1, min = 1, expected = { { 1, 19 }, { 23, 40 }, { 45, 53 } } },
        { context = 5, min = 2, expected = { { 1, 15 }, { 27, 36 }, { 49, 53 } } },
        { context = 5, min = 6, expected = { { 1, 15 }, { 27, 36 } } },
        { context = 5, min = 11, expected = { { 1, 15 } } },
        { context = 9, min = 6, expected = { { 1, 11 } } },
        { context = 25, min = 1, expected = {} },
    }) do
        it(("follows context_size %d and min_fold_size %d"):format(case.context, case.min), function()
            difft.config.context_size, difft.config.min_fold_size = case.context, case.min
            difft.open("HEAD")
            show("a.txt")

            local expected = {}
            for _, r in ipairs(case.expected) do
                table.insert(expected, { r[1], r[2], true })
            end
            assert.are.same(expected, folds(difft.state.left_win))
            assert.are.same(expected, folds(difft.state.right_win))
        end)
    end

    it("folds a file without changes as a whole", function()
        difft.open("HEAD")
        show("b.txt")

        assert.are.same({ { 1, 15, true } }, folds(difft.state.left_win))
        assert.are.same({ { 1, 15, true } }, folds(difft.state.right_win))
    end)

    it("rebuilds the folds for each file shown", function()
        difft.open("HEAD")
        show("b.txt")
        show("a.txt")

        assert.are.same({ { 1, 17, true }, { 25, 38, true }, { 47, 53, true } }, folds(difft.state.left_win))
        show("b.txt")
        assert.are.same({ { 1, 15, true } }, folds(difft.state.right_win))
    end)

    it("puts the cursor on the first hunk, outside any fold", function()
        difft.open("HEAD")
        show("a.txt")

        local line = vim.api.nvim_win_get_cursor(difft.state.right_win)[1]
        assert.are.equal(21, line)
        assert.are.equal(-1, vim.fn.foldclosed(line))
    end)

    it("shows the number of folded lines as the fold text", function()
        difft.open("HEAD")
        show("a.txt")

        local result = vim.api.nvim_win_call(difft.state.left_win, function()
            vim.v.foldstart, vim.v.foldend = 25, 38
            local info = vim.fn.getwininfo(vim.api.nvim_get_current_win())[1]
            return { fold.text(), info.width - info.textoff }
        end)
        local text, width = result[1], result[2]
        assert.are.equal(1, #text)
        assert.are.equal("DifftFold", text[1][2])
        -- The label centred in a rule of the fill character.
        local label = " ▸ 14 unchanged lines "
        local left = math.max(2, math.floor((width - vim.fn.strdisplaywidth(label)) / 2))
        assert.are.equal(("━"):rep(left) .. label, text[1][1])
    end)

    it("centres the label in a wide pane", function()
        vim.o.columns = 200
        difft.open("HEAD")
        show("a.txt")

        local result = vim.api.nvim_win_call(difft.state.right_win, function()
            vim.v.foldstart, vim.v.foldend = 1, 17
            local info = vim.fn.getwininfo(vim.api.nvim_get_current_win())[1]
            return { fold.text()[1][1], info.width - info.textoff }
        end)
        local text, width = result[1], result[2]
        local label = " ▸ 17 unchanged lines "
        local left = vim.fn.strdisplaywidth(text) - vim.fn.strdisplaywidth(label)
        assert.is_true(left > 2)
        assert.is_true(math.abs(left - (width - left - vim.fn.strdisplaywidth(label))) <= 1, text)
    end)

    it("draws closed folds with DifftFold in the panes only", function()
        difft.open("HEAD")
        show("a.txt")

        for _, win in ipairs({ difft.state.left_win, difft.state.right_win }) do
            assert.truthy(vim.wo[win].winhighlight:find("Folded:DifftFold", 1, true))
        end
        assert.is_nil(vim.wo[difft.state.tree_win].winhighlight:find("Folded:DifftFold", 1, true))
    end)

    it("keeps a pane's own winhighlight and restores it when folding is turned off", function()
        difft.open("HEAD")
        vim.wo[difft.state.left_win].winhighlight = "Normal:Comment"
        difft.state.saved_fold_options[difft.state.left_win] = nil
        show("a.txt")
        assert.are.equal("Normal:Comment,Folded:DifftFold", vim.wo[difft.state.left_win].winhighlight)
        -- Rendering again does not add it twice.
        show("b.txt")
        assert.are.equal("Normal:Comment,Folded:DifftFold", vim.wo[difft.state.left_win].winhighlight)

        difft.config.context_size = 0
        show("a.txt")
        assert.are.equal("Normal:Comment", vim.wo[difft.state.left_win].winhighlight)
    end)

    describe("fill character", function()
        local function fold_fill(win)
            return vim.api.nvim_win_call(win, function()
                return vim.opt_local.fillchars:get().fold
            end)
        end

        local saved_ambiwidth, saved_fillchars

        before_each(function()
            saved_ambiwidth, saved_fillchars = vim.o.ambiwidth, vim.go.fillchars
        end)

        after_each(function()
            difft.close()
            vim.o.ambiwidth, vim.go.fillchars = saved_ambiwidth, saved_fillchars
        end)

        it("fills closed fold lines with ━ in both panes", function()
            difft.open("HEAD")
            show("a.txt")

            assert.are.equal("━", fold_fill(difft.state.left_win))
            assert.are.equal("━", fold_fill(difft.state.right_win))
        end)

        it("uses fold_fill for the fill and the fold text", function()
            difft.config.fold_fill = "░"
            difft.open("HEAD")
            show("a.txt")

            assert.are.equal("░", fold_fill(difft.state.right_win))
            local text = vim.api.nvim_win_call(difft.state.right_win, function()
                vim.v.foldstart, vim.v.foldend = 1, 1
                return fold.text()
            end)
            local label = " ▸ 1 unchanged line "
            local rule = text[1][1]:sub(1, #text[1][1] - #label)
            assert.are.equal(label, text[1][1]:sub(-#label))
            assert.are.equal("", (rule:gsub("░", "")), text[1][1])
        end)

        it("keeps the window's other fill characters", function()
            vim.go.fillchars = "eob:~,vert:|"
            difft.open("HEAD")
            show("a.txt")

            local chars = vim.api.nvim_win_call(difft.state.left_win, function()
                return vim.opt_local.fillchars:get()
            end)
            assert.are.equal("~", chars.eob)
            assert.are.equal("|", chars.vert)
            assert.are.equal("━", chars.fold)
        end)

        it("falls back to = when Neovim rejects the character", function()
            -- Box drawing characters take two cells with ambiwidth=double.
            vim.go.fillchars = ""
            vim.o.ambiwidth = "double"
            difft.open("HEAD")
            show("a.txt")

            assert.are.equal("=", fold_fill(difft.state.left_win))
            assert.are.equal("=", fold_fill(difft.state.right_win))
        end)

        it("gives the panes their own fill characters back when folding is turned off", function()
            vim.go.fillchars = "fold:-"
            difft.open("HEAD")
            show("a.txt")
            assert.are.equal("━", fold_fill(difft.state.left_win))

            difft.config.context_size = 0
            show("b.txt")

            assert.are.equal("-", fold_fill(difft.state.left_win))
            assert.are.equal("-", fold_fill(difft.state.right_win))
        end)
    end)

    describe("with context_size = 0", function()
        local saved

        before_each(function()
            saved = { foldmethod = vim.go.foldmethod, foldtext = vim.go.foldtext, foldminlines = vim.go.foldminlines }
            vim.go.foldmethod = "indent"
            vim.go.foldminlines = 3
            difft.config.context_size = 0
        end)

        after_each(function()
            for name, value in pairs(saved) do
                vim.go[name] = value
            end
        end)

        it("adds no folds and leaves the fold options alone", function()
            difft.open("HEAD")
            show("a.txt")

            for _, win in ipairs({ difft.state.left_win, difft.state.right_win }) do
                assert.are.same({}, folds(win))
                assert.are.equal("indent", vim.wo[win].foldmethod)
                assert.are.equal(3, vim.wo[win].foldminlines)
            end
        end)

        it("gives the panes their own fold options back after folding was on", function()
            difft.config.context_size = 3
            difft.open("HEAD")
            show("a.txt")
            assert.are.equal("manual", vim.wo[difft.state.left_win].foldmethod)

            difft.config.context_size = 0
            show("b.txt")

            for _, win in ipairs({ difft.state.left_win, difft.state.right_win }) do
                assert.are.same({}, folds(win))
                assert.are.equal("indent", vim.wo[win].foldmethod)
                assert.are.equal(3, vim.wo[win].foldminlines)
            end
        end)
    end)

    describe("when returning to a file", function()
        local function set_fold(win, line, open)
            vim.api.nvim_win_call(win, function()
                vim.cmd(("%dfold%s"):format(line, open and "open" or "close"))
            end)
        end

        it("restores the folds opened and closed in it", function()
            difft.open("HEAD")
            show("a.txt")
            set_fold(difft.state.left_win, 30, true)
            set_fold(difft.state.right_win, 30, true)
            set_fold(difft.state.left_win, 50, true)
            set_fold(difft.state.right_win, 50, true)
            set_fold(difft.state.left_win, 50, false)
            set_fold(difft.state.right_win, 50, false)

            show("b.txt")
            assert.are.same({ { 1, 15, true } }, folds(difft.state.left_win))
            show("a.txt")

            local expected = { { 1, 17, true }, { 25, 38, false }, { 47, 53, true } }
            assert.are.same(expected, folds(difft.state.left_win))
            assert.are.same(expected, folds(difft.state.right_win))
        end)

        it("includes a change made in one pane just before leaving", function()
            difft.open("HEAD")
            show("a.txt")
            -- Not synced yet: only the head pane has the fold open.
            set_fold(difft.state.right_win, 1, true)

            show("b.txt")
            show("a.txt")

            local expected = { { 1, 17, false }, { 25, 38, true }, { 47, 53, true } }
            assert.are.same(expected, folds(difft.state.left_win))
            assert.are.same(expected, folds(difft.state.right_win))
        end)

        it("remembers closed folds with fold_by_default = false", function()
            difft.config.fold_by_default = false
            difft.open("HEAD")
            show("a.txt")
            set_fold(difft.state.left_win, 50, false)
            set_fold(difft.state.right_win, 50, false)

            show("b.txt")
            assert.are.same({ { 1, 15, false } }, folds(difft.state.left_win))
            show("a.txt")

            local expected = { { 1, 17, false }, { 25, 38, false }, { 47, 53, true } }
            assert.are.same(expected, folds(difft.state.left_win))
            assert.are.same(expected, folds(difft.state.right_win))
        end)

        it("keeps each file's fold states apart", function()
            difft.open("HEAD")
            show("a.txt")
            set_fold(difft.state.left_win, 1, true)
            set_fold(difft.state.right_win, 1, true)
            show("b.txt")
            set_fold(difft.state.left_win, 1, true)
            set_fold(difft.state.right_win, 1, true)

            show("a.txt")
            assert.are.same({ { 1, 17, false }, { 25, 38, true }, { 47, 53, true } }, folds(difft.state.right_win))
            show("b.txt")
            assert.are.same({ { 1, 15, false } }, folds(difft.state.right_win))
        end)

        it("restores the cursor inside an opened fold", function()
            difft.open("HEAD")
            show("a.txt")
            vim.api.nvim_set_current_win(difft.state.right_win)
            set_fold(difft.state.left_win, 30, true)
            set_fold(difft.state.right_win, 30, true)
            vim.api.nvim_win_set_cursor(difft.state.right_win, { 32, 0 })

            show("b.txt")
            show("a.txt")

            assert.are.same({ 32, 0 }, vim.api.nvim_win_get_cursor(difft.state.right_win))
            assert.are.equal(-1, vim.fn.foldclosed(32))
        end)

        it("uses fold_by_default when the folds changed meanwhile", function()
            difft.open("HEAD")
            show("a.txt")
            set_fold(difft.state.left_win, 30, true)
            set_fold(difft.state.right_win, 30, true)
            show("b.txt")

            difft.config.context_size = 5
            show("a.txt")

            local expected = { { 1, 15, true }, { 27, 36, true }, { 49, 53, true } }
            assert.are.same(expected, folds(difft.state.left_win))
            assert.are.same(expected, folds(difft.state.right_win))
        end)

        it("records a file's fold states as soon as it is shown", function()
            -- a.txt is shown when the view opens; no file is left before checking.
            difft.open("HEAD")
            assert.are.equal("a.txt", difft.state.shown_path)

            local saved = difft.state.fold_states["a.txt"]
            assert.are.same({ { 1, 17 }, { 25, 38 }, { 47, 53 } }, saved.ranges)
            assert.are.same({ true, true, true }, saved.closed)
        end)

        it("records every fold change without leaving the file", function()
            difft.open("HEAD")
            show("a.txt")

            set_fold(difft.state.right_win, 30, true)
            fold.sync(difft.state)
            assert.are.same({ true, false, true }, difft.state.fold_states["a.txt"].closed)

            set_fold(difft.state.left_win, 1, true)
            fold.sync(difft.state)
            assert.are.same({ false, false, true }, difft.state.fold_states["a.txt"].closed)
        end)

        it("settles a pending fold change when the view closes", function()
            difft.open("HEAD")
            show("a.txt")
            set_fold(difft.state.right_win, 30, true)
            local original_sync, seen = fold.sync, nil
            fold.sync = function(state)
                original_sync(state)
                seen = seen or vim.deepcopy(state.fold_states["a.txt"])
            end

            local ok, err = pcall(difft.close)
            fold.sync = original_sync

            assert.is_true(ok, err)
            assert.are.same({ true, false, true }, seen.closed)
        end)

        it("records nothing for a file shown without folds", function()
            difft.config.context_size = 0
            difft.open("HEAD")
            show("a.txt")

            assert.is_nil(difft.state.fold_states["a.txt"])
        end)

        describe("whose folds changed meanwhile", function()
            local function visit_at(line, side)
                local win = side == "base" and difft.state.left_win or difft.state.right_win
                vim.api.nvim_set_current_win(win)
                vim.api.nvim_win_set_cursor(win, { line, 0 })
                vim.api.nvim_exec_autocmds("CursorMoved", {})
            end

            it("opens the fold that now hides the remembered line", function()
                difft.open("HEAD")
                show("a.txt")
                set_fold(difft.state.left_win, 30, true)
                set_fold(difft.state.right_win, 30, true)
                visit_at(30, "head")
                show("b.txt")

                difft.config.context_size = 1
                show("a.txt")

                local expected = { { 1, 19, true }, { 23, 40, false }, { 45, 53, true } }
                assert.are.same(expected, folds(difft.state.left_win))
                assert.are.same(expected, folds(difft.state.right_win))
                assert.are.same({ true, false, true }, difft.state.fold_states["a.txt"].closed)
                assert.are.same({ 30, 0 }, vim.api.nvim_win_get_cursor(difft.state.right_win))
                assert.are.equal(-1, vim.fn.foldclosed(30))
            end)

            it("leaves the folds closed when the remembered line stays visible", function()
                difft.open("HEAD")
                show("a.txt")
                visit_at(20, "base")
                show("b.txt")

                difft.config.context_size = 1
                show("a.txt")

                local expected = { { 1, 19, true }, { 23, 40, true }, { 45, 53, true } }
                assert.are.same(expected, folds(difft.state.left_win))
                assert.are.same(expected, folds(difft.state.right_win))
            end)

            it("opens the fold when folding was off on the last visit", function()
                difft.config.context_size = 0
                difft.open("HEAD")
                show("a.txt")
                visit_at(5, "head")
                show("b.txt")

                difft.config.context_size = 3
                show("a.txt")

                local expected = { { 1, 17, false }, { 25, 38, true }, { 47, 53, true } }
                assert.are.same(expected, folds(difft.state.left_win))
                assert.are.same(expected, folds(difft.state.right_win))
            end)

            it("needs no fold to open when folding is now off", function()
                difft.open("HEAD")
                show("a.txt")
                visit_at(30, "head")
                show("b.txt")

                difft.config.context_size = 0
                show("a.txt")

                assert.are.same({}, folds(difft.state.left_win))
                assert.are.same({ 30, 0 }, vim.api.nvim_win_get_cursor(difft.state.right_win))
            end)
        end)

        it("keeps a fold the user closed over the remembered line closed", function()
            difft.open("HEAD")
            show("a.txt")
            set_fold(difft.state.left_win, 30, true)
            set_fold(difft.state.right_win, 30, true)
            vim.api.nvim_set_current_win(difft.state.right_win)
            vim.api.nvim_win_set_cursor(difft.state.right_win, { 30, 0 })
            vim.api.nvim_exec_autocmds("CursorMoved", {})
            set_fold(difft.state.left_win, 30, false)
            set_fold(difft.state.right_win, 30, false)
            show("b.txt")

            show("a.txt")

            assert.are.same({ { 1, 17, true }, { 25, 38, true }, { 47, 53, true } }, folds(difft.state.right_win))
        end)

        it("keeps the first fold closed for a new file without scroll_to_first_hunk", function()
            difft.config.scroll_to_first_hunk = false
            difft.open("HEAD")
            show("a.txt")

            assert.are.same({ 1, 0 }, vim.api.nvim_win_get_cursor(difft.state.right_win))
            assert.are.same({ { 1, 17, true }, { 25, 38, true }, { 47, 53, true } }, folds(difft.state.right_win))
        end)

        it("forgets fold states when a new view opens", function()
            difft.open("HEAD")
            show("a.txt")
            set_fold(difft.state.left_win, 30, true)
            set_fold(difft.state.right_win, 30, true)
            show("b.txt")
            difft.close()

            difft.open("HEAD")
            show("b.txt")
            show("a.txt")

            assert.are.same({ { 1, 17, true }, { 25, 38, true }, { 47, 53, true } }, folds(difft.state.left_win))
        end)
    end)

    it("lands on unfolded lines when navigating hunks", function()
        difft.config.hunk_wrap_file = false
        difft.open("HEAD")
        show("a.txt")
        vim.api.nvim_set_current_win(difft.state.right_win)

        for _ = 1, 3 do
            difft.next_hunk()
            local line = vim.api.nvim_win_get_cursor(0)[1]
            assert.are.equal(-1, vim.fn.foldclosed(line), "hunk at " .. line .. " is folded")
        end
    end)
end)

describe("fold settings in setup()", function()
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

    it("defaults to context 3, min_fold_size 2, folded, filled with ━", function()
        assert.are.equal(3, original_config.context_size)
        assert.are.equal(2, original_config.min_fold_size)
        assert.is_true(original_config.fold_by_default)
        assert.are.equal("━", original_config.fold_fill)
    end)

    it("takes a fold_accent group name", function()
        difft.setup({ fold_accent = "Special" })
        assert.are.equal("Special", difft.config.fold_accent)
        assert.are.same({}, messages)
    end)

    it("takes a one-cell fold_fill", function()
        difft.setup({ fold_fill = "╍" })
        assert.are.equal("╍", difft.config.fold_fill)
        assert.are.same({}, messages)
    end)

    it("takes valid values", function()
        difft.setup({ context_size = 0, min_fold_size = 1, fold_by_default = false })
        assert.are.equal(0, difft.config.context_size)
        assert.are.equal(1, difft.config.min_fold_size)
        assert.is_false(difft.config.fold_by_default)
        assert.are.same({}, messages)
    end)

    for _, case in ipairs({
        { "context_size", -1 },
        { "context_size", "3" },
        { "min_fold_size", 0 },
        { "min_fold_size", -2 },
        { "fold_fill", "" },
        { "fold_fill", "==" },
        { "fold_fill", "全" },
        { "fold_fill", 1 },
        { "fold_accent", "" },
        { "fold_accent", 3 },
    }) do
        local name, value = unpack(case)
        it(("reports and ignores %s = %s"):format(name, vim.inspect(value)), function()
            local before = difft.config[name]
            difft.setup({ [name] = value })

            assert.are.equal(before, difft.config[name])
            assert.are.equal(1, #messages)
            assert.are.equal(vim.log.levels.ERROR, messages[1][2])
            assert.truthy(messages[1][1]:find(name, 1, true))
        end)
    end
end)
