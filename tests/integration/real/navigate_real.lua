-- luacheck: std +busted
-- Tier 2 (real crengine). navigate against juliet.epub: page/percent/chapter jumps
-- and back actually move crengine's current page (the fakes could only check the
-- dispatched event; here we confirm the reader really lands there, including the
-- rolling GotoXPointer chapter path). Run via `nix run .#test-real`.

local support = require("tests.integration.real.support")

describe("navigate (real)", function()
    local readerui, Tools

    setup(function()
        readerui, Tools = support.open_book()
    end)
    teardown(function()
        support.close_book(readerui)
    end)

    it("jumps to an absolute page and the reader lands there", function()
        local out, summary = Tools.execute("navigate", { page = 50 }, readerui)
        assert.are.equal(50, support.current_page(Tools, readerui))
        assert.truthy(out:find("page 50", 1, true))
        assert.truthy(summary:find("50", 1, true))
    end)

    it("moves percent jumps directionally through the book", function()
        Tools.execute("navigate", { percent = 10 }, readerui)
        local early = support.current_page(Tools, readerui)
        Tools.execute("navigate", { percent = 90 }, readerui)
        local late = support.current_page(Tools, readerui)
        assert.is_true(late > early, ("percent=90 (page %d) should be past percent=10 (page %d)"):format(late, early))
    end)

    it("jumps to a chapter via its real xpointer (GotoXPointer)", function()
        -- Read the TOC's own page number for entry 6, then confirm navigating by
        -- that chapter_index lands the reader on it.
        local toc = Tools.execute("get_toc", {}, readerui)
        local target = tonumber(toc:match("\n6%.%s.-%(page%s+(%d+)%)"))
        assert.truthy(target, "could not parse page for TOC entry 6")
        Tools.execute("navigate", { chapter_index = 6 }, readerui)
        assert.are.equal(target, support.current_page(Tools, readerui))
    end)

    it("goes back to the previous location", function()
        Tools.execute("navigate", { page = 50 }, readerui)
        Tools.execute("navigate", { page = 120 }, readerui)
        assert.are.equal(120, support.current_page(Tools, readerui))
        local out, summary = Tools.execute("navigate", { back = true }, readerui)
        assert.are.equal(50, support.current_page(Tools, readerui))
        assert.truthy(out:find("Went back", 1, true))
        assert.truthy(summary:find("went back", 1, true))
    end)
end)

describe("navigate back on a fresh book (real)", function()
    local readerui, Tools

    setup(function()
        readerui, Tools = support.open_book()
    end)
    teardown(function()
        support.close_book(readerui)
    end)

    it("reports nothing to go back to when the history stack is empty", function()
        local out, summary = Tools.execute("navigate", { back = true }, readerui)
        assert.truthy(out:find("no previous location", 1, true))
        assert.truthy(summary:find("nothing to go back", 1, true))
    end)
end)
