-- Pure-luajit checks for the bbtools `get_highlights` executor: the empty-book
-- report, the 1-based numbering that skips bare bookmarks, highlight-vs-note
-- labelling, the location line, whitespace collapse, and the max_results clamp /
-- "(showing first N)" header. Real annotation extraction is proven in
-- tests/integration/real/highlight_real.lua (`.#test-real`); this spec keeps only
-- what trivial fakes can decide.

local stubs = require("support.stubs")

describe("get_highlights (pure)", function()
    local Tools
    setup(function()
        Tools = stubs.load_tools()
    end)

    local function makeHlUI(anns)
        return { annotation = { annotations = anns } }
    end

    it("reports an empty book", function()
        local out, summary = Tools.execute("get_highlights", {}, makeHlUI({}))
        assert.truthy(out:find("no highlights or notes yet", 1, true))
        assert.are.equal("none yet", summary)
    end)

    it("lists highlights and notes in reading order, skipping bare bookmarks", function()
        local anns = {
            { pageno = 1 }, -- bare bookmark: no text, no note => skipped
            { text = "the  quick\nbrown", pageno = 10, chapter = "Chapter 1" }, -- highlight #1
            { note = "my thought", pageno = 20 }, -- note #2 (no text)
            { text = "passage", note = "annotated", pageno = 30, chapter = "Chapter 3" }, -- both => note #3
        }
        local out, summary = Tools.execute("get_highlights", {}, makeHlUI(anns))
        -- 3 of 4 items are addressable; the bare bookmark contributes nothing.
        assert.truthy(out:find("3 highlight(s)/note(s) in this book:", 1, true))
        assert.are.equal("3 found", summary)
        -- 1-based numbering over the filtered list, labelled by note-presence.
        assert.truthy(out:find("1. [highlight | page 10, Chapter 1]", 1, true))
        assert.truthy(out:find("2. [note | page 20]", 1, true))
        assert.truthy(out:find("3. [note | page 30, Chapter 3]", 1, true))
        -- Interior whitespace in the highlighted text is collapsed to single spaces.
        assert.truthy(out:find('"the quick brown"', 1, true))
        assert.truthy(out:find("note: my thought", 1, true))
        -- No "(showing first N)" caveat when everything fits.
        assert.is_nil(out:match("showing first"))
    end)

    it("rejects a present-but-invalid max_results instead of reporting an empty list", function()
        local anns = {
            { text = "first", pageno = 10 },
            { text = "second", pageno = 20 },
        }
        local ui = makeHlUI(anns)
        -- 0 would clamp the loop to show nothing while the header still claims 2 total.
        assert.truthy(Tools.execute("get_highlights", { max_results = 0 }, ui):find("whole number >= 1", 1, true))
        -- negative and fractional are rejected the same way.
        assert.truthy(Tools.execute("get_highlights", { max_results = -3 }, ui):find("whole number >= 1", 1, true))
        assert.truthy(Tools.execute("get_highlights", { max_results = 1.5 }, ui):find("whole number >= 1", 1, true))
        -- over-asking is not an error: it still clamps and lists everything, like grep.
        local big = Tools.execute("get_highlights", { max_results = 999 }, ui)
        assert.truthy(big:find('"first"', 1, true))
        assert.truthy(big:find('"second"', 1, true))
    end)

    it("clamps to max_results and reports the shown-vs-total split", function()
        local anns = {
            { text = "first", pageno = 10 },
            { text = "second", pageno = 20 },
            { text = "third", pageno = 30 },
        }
        local out, summary = Tools.execute("get_highlights", { max_results = 1 }, makeHlUI(anns))
        assert.truthy(out:find("3 highlight(s)/note(s) in this book (showing first 1):", 1, true))
        assert.truthy(out:find('"first"', 1, true))
        assert.is_nil(out:match('"second"'))
        -- The summary still reports the true total, not the shown count.
        assert.are.equal("3 found", summary)
    end)
end)
