-- luacheck: std +busted
-- Tier 2 (real crengine). The forward reader against juliet.epub: real word-by-word
-- xpointer stepping (getNextVisibleWordEnd/compareXPointers/getTextFromXPointers),
-- continuation locators, the page-level spoiler refuse/clamp gates, page-string and
-- locator starts, and real end-of-book. Run via `nix run .#test-real`.

local support = require("tests.integration.real.support")

describe("read (real)", function()
    local readerui, Tools

    setup(function()
        readerui, Tools = support.open_book()
    end)
    teardown(function()
        support.close_book(readerui)
    end)

    it("reads the current page forward, clamped at the next page (no spoiler)", function()
        Tools.execute("navigate", { page = 20 }, readerui)
        local out, summary = Tools.execute("read", {}, readerui)
        assert.truthy(out:find("reading forward", 1, true))
        assert.truthy(out:find("page 20", 1, true)) -- header names where it started
        -- without spoiler the chunk cannot cross into page 21: it either fits and
        -- clamps, or there's nothing past the boundary — never a forward locator
        -- that would let the model read ahead.
        assert.is_nil(out:match("More follows"))
        assert.truthy(summary:find("word", 1, true))
    end)

    it("reads forward with spoiler=true and the continuation locator resolves", function()
        local out1 = Tools.execute("read", { from = "1", spoiler = true, limit = 300 }, readerui)
        assert.truthy(out1:find("reading forward", 1, true))
        local nexttok = out1:match("from: (loc:%d+)")
        assert.truthy(nexttok) -- a long enough book section yields a continuation
        local out2 = Tools.execute("read", { from = nexttok, spoiler = true, limit = 300 }, readerui)
        assert.truthy(out2:find("reading forward", 1, true))
        assert.is_nil(out2:find("stale", 1, true))
        -- the two chunks are genuinely different stretches of prose.
        assert.are_not.equal(out1, out2)
    end)

    it("starts from a bare page-number string", function()
        local out = Tools.execute("read", { from = "20", spoiler = true }, readerui)
        assert.truthy(out:find("page 20", 1, true))
        assert.truthy(out:find("reading forward", 1, true))
    end)

    it("starts from a grep hit's span locator", function()
        local g = Tools.execute("grep", { query = "Verona", spoiler = true }, readerui)
        local loc = g:match("(loc:%d+)")
        assert.truthy(loc)
        local out = Tools.execute("read", { from = loc, spoiler = true }, readerui)
        assert.truthy(out:find("reading forward", 1, true))
        assert.is_nil(out:find("stale", 1, true))
    end)

    it("refuses a start past the reader's current page without spoiler", function()
        Tools.execute("navigate", { page = 10 }, readerui)
        local out = Tools.execute("read", { from = "100" }, readerui)
        assert.truthy(out:find("past where you are", 1, true))
        assert.is_nil(out:match("reading forward"))
        assert.is_nil(out:match("loc:%d"))
    end)

    it("reaches real end-of-book when reading from the last page", function()
        local ctx = Tools.execute("book_context", {}, readerui)
        local total = tonumber(ctx:match("of%s+(%d+)"))
        assert.truthy(total)
        -- Start at the very last page and keep reading forward; a finite book must
        -- terminate at the end rather than looping or erroring.
        local out
        local guard = 0
        local from = tostring(total)
        repeat
            out = Tools.execute("read", { from = from, spoiler = true, limit = 1000 }, readerui)
            from = out:match("from: (loc:%d+)")
            guard = guard + 1
        until from == nil or guard > 30
        assert.is_nil(from, "reading from the last page should terminate, not keep yielding locators")
        assert.is_true(
            out:find("End of book", 1, true) ~= nil or out:find("Nothing further", 1, true) ~= nil,
            "expected an end-of-book trailer, got:\n" .. out
        )
    end)
end)
