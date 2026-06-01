-- luacheck: std +busted
-- Tier 2 (real crengine). book_context + get_toc against the real juliet.epub.
-- These two tools are pure reads of crengine's document props / TOC, so one
-- shared ReaderUI for the whole file. Run via `nix run .#test-real`.

local support = require("tests.integration.real.support")

describe("book_context (real)", function()
    local readerui, Tools

    setup(function()
        readerui, Tools = support.open_book()
    end)
    teardown(function()
        support.close_book(readerui)
    end)

    it("reports the real title, author and page count", function()
        local text, summary = Tools.execute("book_context", {}, readerui)
        assert.is_string(text)
        assert.truthy(text:find("Title: Romeo and Juliet", 1, true))
        assert.truthy(text:find("Author: William Shakespeare", 1, true))
        -- page count is whatever crengine paginates juliet.epub to; assert it's a
        -- real positive integer rather than a hard-coded number (it tracks layout).
        local cur, total = text:match("Current page:%s*(%d+)%s+of%s+(%d+)")
        assert.truthy(total)
        assert.is_true(tonumber(cur) >= 1)
        assert.is_true(tonumber(total) > tonumber(cur))
        assert.truthy(summary:find("of", 1, true))
    end)

    it("names the current chapter from the real TOC", function()
        -- Move into a known scene so getTocTitleOfCurrentPage has something to say.
        Tools.execute("navigate", { chapter_index = 5 }, readerui) -- SCENE I. Verona...
        local text = Tools.execute("book_context", {}, readerui)
        assert.truthy(text:find("Current chapter:", 1, true))
        assert.truthy(text:find("Verona", 1, true))
    end)
end)

describe("get_toc (real)", function()
    local readerui, Tools

    setup(function()
        readerui, Tools = support.open_book()
    end)
    teardown(function()
        support.close_book(readerui)
    end)

    it("lists the real chapters, each with a resolvable loc token", function()
        local text, summary = Tools.execute("get_toc", {}, readerui)
        assert.is_string(text)
        -- juliet.epub's TOC has Acts and named scenes.
        assert.truthy(text:find("Act I", 1, true))
        assert.truthy(text:find("SCENE I. Verona", 1, true))
        -- every CRE/EPUB TOC entry carries an xpointer, so a loc token is minted.
        assert.truthy(text:match("loc:%d+"))
        -- the summary reports the entry count, and there are many.
        local n = tonumber(summary:match("(%d+)"))
        assert.truthy(n and n > 10)
    end)

    it("mints loc tokens that read can resolve to that chapter's start", function()
        local text = Tools.execute("get_toc", {}, readerui)
        local loc = text:match("(loc:%d+)")
        assert.truthy(loc)
        local out = Tools.execute("read", { from = loc, spoiler = true }, readerui)
        assert.truthy(out:find("reading forward", 1, true))
        assert.is_nil(out:find("stale", 1, true))
    end)
end)
