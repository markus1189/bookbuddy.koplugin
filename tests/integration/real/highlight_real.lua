-- luacheck: std +busted
-- Tier 2 (real crengine). The highlight lifecycle against juliet.epub's real
-- annotation store: create_highlight (by occurrence, by a grep search_result, by a
-- grep span locator) actually inserts an annotation via ReaderAnnotation:addItem;
-- get_highlights lists it with its real page/chapter; edit_highlight_note sets then
-- appends a note. Fresh ReaderUI per describe so each starts from zero highlights.
-- Run via `nix run .#test-real`.

local support = require("tests.integration.real.support")

describe("highlight round-trip (real)", function()
    local readerui, Tools

    setup(function()
        readerui, Tools = support.open_book()
        support.reset_annotations(readerui) -- clean slate (sidecar may carry prior highlights)
    end)
    teardown(function()
        support.close_book(readerui)
    end)

    it("creates by occurrence, lists it, then sets and appends a note", function()
        local created, csum = Tools.execute("create_highlight", { text = "Verona", occurrence = 1 }, readerui)
        assert.truthy(created:find("Highlighted on", 1, true))
        assert.truthy(created:find("Verona", 1, true))
        assert.truthy(csum:find("highlight added", 1, true))

        local listed = Tools.execute("get_highlights", {}, readerui)
        assert.truthy(listed:find("1 highlight", 1, true))
        assert.truthy(listed:find("Verona", 1, true))
        assert.truthy(listed:find("page", 1, true)) -- carries a real page/chapter location

        local added = Tools.execute("edit_highlight_note", { highlight_index = 1, note = "a thought" }, readerui)
        assert.truthy(added:find("Added", 1, true))
        assert.truthy(added:find("a thought", 1, true))

        local appended = Tools.execute("edit_highlight_note", { highlight_index = 1, note = "and another" }, readerui)
        assert.truthy(appended:find("Appended", 1, true))
        -- the original note survives the append (non-destructive).
        assert.truthy(appended:find("a thought", 1, true))
        assert.truthy(appended:find("and another", 1, true))

        local final = Tools.execute("get_highlights", {}, readerui)
        assert.truthy(final:find("note:", 1, true))
        assert.truthy(final:find("a thought", 1, true))
    end)
end)

describe("highlight from grep results (real)", function()
    local readerui, Tools

    setup(function()
        readerui, Tools = support.open_book()
        support.reset_annotations(readerui) -- clean slate (sidecar may carry prior highlights)
    end)
    teardown(function()
        support.close_book(readerui)
    end)

    it("creates from a grep search_result and from a span locator", function()
        Tools.execute("grep", { query = "Mantua", spoiler = true }, readerui)
        local byresult = Tools.execute("create_highlight", { search_result = 1 }, readerui)
        assert.truthy(byresult:find("Highlighted on", 1, true))
        assert.truthy(byresult:find("Mantua", 1, true))

        local g = Tools.execute("grep", { query = "poison", spoiler = true }, readerui)
        local loc = g:match("(loc:%d+)")
        assert.truthy(loc)
        local byloc = Tools.execute("create_highlight", { locator = loc }, readerui)
        assert.truthy(byloc:find("Highlighted on", 1, true))

        local listed = Tools.execute("get_highlights", {}, readerui)
        assert.truthy(listed:find("2 highlight", 1, true))
    end)

    it("refuses an ambiguous text and highlights nothing", function()
        -- "Verona" occurs many times; with no occurrence/page the tool must ask
        -- rather than guess, and the highlight count stays unchanged.
        local before = Tools.execute("get_highlights", {}, readerui)
        local before_n = tonumber(before:match("(%d+) highlight")) or 0
        local out, summary = Tools.execute("create_highlight", { text = "Verona" }, readerui)
        assert.truthy(out:find("Specify 'occurrence'", 1, true))
        assert.truthy(summary:find("ambiguous", 1, true))
        local after = Tools.execute("get_highlights", {}, readerui)
        local after_n = tonumber(after:match("(%d+) highlight")) or 0
        assert.are.equal(before_n, after_n)
    end)
end)
