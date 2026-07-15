-- luacheck: std +busted
-- Tier 2 (real crengine). read_chapter against juliet.epub: whole-chapter reads over
-- real TOC xpointers, the fast-path span extract, the page-level spoiler refuse and
-- truncation, and continuation locators across chunks of a real chapter. The specs
-- self-discover the TOC (like navigate_real) rather than hardcoding juliet's shape.
-- Run via `nix run .#test-real`.

local support = require("tests.integration.real.support")

describe("read_chapter (real)", function()
    local readerui, Tools

    -- get_toc's numbered lines parsed into an ordered list of { idx, page }.
    -- Entries whose page prints as "?" are skipped (they can't anchor page math).
    local function tocEntries()
        local out = Tools.execute("get_toc", {}, readerui)
        local list = {}
        for n, page in out:gmatch("\n(%d+)%.%s[^\n]-%(page%s+(%d+)%)") do
            list[#list + 1] = { idx = tonumber(n), page = tonumber(page) }
        end
        return list
    end

    -- The first TOC entry followed (in list order) by an entry at least min_pages
    -- later. Its chapter therefore spans at least that many pages -- the chapter's
    -- end boundary is the next same-or-shallower entry, which starts at or after
    -- the immediately following entry's page.
    local function pickSpanningEntry(list, min_pages)
        for i = 1, #list - 1 do
            if list[i + 1].page - list[i].page >= min_pages then
                return list[i]
            end
        end
    end

    setup(function()
        readerui, Tools = support.open_book()
    end)
    teardown(function()
        support.close_book(readerui)
    end)

    it("reads a whole chapter to its end with spoiler=true", function()
        local list = tocEntries()
        assert.is_true(#list >= 2, "juliet.epub should have a multi-entry TOC")
        local e = pickSpanningEntry(list, 3)
        assert.truthy(e, "expected some TOC entry spanning >= 3 pages")
        -- max limit so a scene-sized chapter completes in one call when it fits;
        -- follow continuations otherwise. Either way the loop must terminate in an
        -- end trailer, never a stale locator.
        local out
        local from, guard = nil, 0
        repeat
            out = Tools.execute(
                "read_chapter",
                { chapter_index = e.idx, from = from, spoiler = true, limit = 48000 },
                readerui
            )
            assert.is_nil(out:find("stale", 1, true))
            from = out:match("from: (loc:%d+)")
            guard = guard + 1
        until from == nil or guard > 20
        assert.is_nil(from, "a finite chapter must stop yielding continuation locators")
        assert.truthy(out:find("[Chapter " .. e.idx .. ":", 1, true)) -- header names the chapter
        assert.is_true(
            out:find("End of chapter", 1, true) ~= nil or out:find("End of book", 1, true) ~= nil,
            "expected an end-of-chapter trailer, got:\n" .. out
        )
    end)

    it("hands out a continuation locator on a small limit and resumes without overlap", function()
        local e = pickSpanningEntry(tocEntries(), 3)
        assert.truthy(e)
        local first = Tools.execute("read_chapter", { chapter_index = e.idx, spoiler = true, limit = 300 }, readerui)
        assert.truthy(first:find("Chapter not finished", 1, true), "a >=3-page chapter must overflow 300 chars")
        local tok = first:match("from: (loc:%d+)")
        assert.truthy(tok)
        local rest =
            Tools.execute("read_chapter", { chapter_index = e.idx, from = tok, spoiler = true, limit = 300 }, readerui)
        assert.is_nil(rest:find("stale", 1, true))
        -- the two chunks are genuinely different stretches of prose.
        assert.are_not.equal(first, rest)
    end)

    it("refuses a chapter starting past the reader's page, naming read_chapter", function()
        local list = tocEntries()
        local last = list[#list]
        assert.truthy(last and last.page >= 3, "expected a late TOC entry to refuse")
        Tools.execute("navigate", { page = 1 }, readerui)
        local out = Tools.execute("read_chapter", { chapter_index = last.idx }, readerui)
        assert.truthy(out:find("past where you are", 1, true))
        assert.truthy(out:find("read_chapter again with spoiler=true", 1, true))
        assert.is_nil(out:match("loc:%d")) -- no continuation into hidden text
    end)

    it("truncates a chapter spanning the reader's position at their current page", function()
        local e = pickSpanningEntry(tocEntries(), 3)
        assert.truthy(e)
        -- Stand mid-chapter: one page past its start, with its end >= 2 pages ahead,
        -- so the spoiler clamp (start of the next page) fires strictly before the
        -- chapter end even at the max budget.
        Tools.execute("navigate", { page = e.page + 1 }, readerui)
        local out = Tools.execute("read_chapter", { chapter_index = e.idx, limit = 48000 }, readerui)
        assert.truthy(out:find("Chapter truncated at your current page", 1, true))
        assert.is_nil(out:find("End of chapter", 1, true))
        assert.is_nil(out:match("from: loc:%d")) -- no read-ahead continuation
    end)

    it("reads the last chapter through to real end-of-book", function()
        local list = tocEntries()
        local last = list[#list]
        assert.truthy(last)
        local out
        local from, guard = nil, 0
        repeat
            out = Tools.execute(
                "read_chapter",
                { chapter_index = last.idx, from = from, spoiler = true, limit = 48000 },
                readerui
            )
            from = out:match("from: (loc:%d+)")
            guard = guard + 1
        until from == nil or guard > 20
        assert.is_nil(from, "the last chapter must terminate at the end of the book")
        assert.is_true(
            out:find("End of book", 1, true) ~= nil or out:find("Nothing further", 1, true) ~= nil,
            "expected an end-of-book trailer, got:\n" .. out
        )
    end)

    it("rejects an out-of-range chapter_index against the real TOC", function()
        local out = Tools.execute("read_chapter", { chapter_index = 100000 }, readerui)
        assert.truthy(out:find("'chapter_index' must be a whole number between 1 and", 1, true))
    end)
end)
