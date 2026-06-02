-- luacheck: std +busted
-- Tier 2 (real crengine). grep against juliet.epub: real findAllText hits, the
-- regex flag flowing through to crengine, sentence-segment context, and the
-- page-level spoiler cap computed from real hit pages vs the reader's real page.
-- Each test sets the reader's page absolutely (navigate), so order is irrelevant
-- and one ReaderUI is shared. Run via `nix run .#test-real`.

local support = require("tests.integration.real.support")

-- Pages that "Verona" really lands on in juliet.epub (from real findAllText), used
-- to assert the spoiler cap hides the later ones. Kept loose: we assert relative
-- behaviour (early shown / late hidden), not an exact transcript.
describe("grep (real)", function()
    local readerui, Tools

    setup(function()
        readerui, Tools = support.open_book()
    end)
    teardown(function()
        support.close_book(readerui)
    end)

    it("returns real page-tagged, loc-tagged hits and records last_search", function()
        local text, summary = Tools.execute("grep", { query = "Verona", spoiler = true }, readerui)
        assert.truthy(text:find("Verona", 1, true))
        -- result lines look like "N. [page P] (loc:K) …snippet…"
        assert.truthy(text:match("%d+%.%s+%[page%s+%d+%]%s+%(loc:%d+%)"))
        assert.truthy(summary:find("match", 1, true))
        -- last_search is the lock-step index create_highlight{search_result=i} uses.
        assert.is_table(readerui._bookbuddy_last_search)
        assert.is_true(#readerui._bookbuddy_last_search.items >= 1)
        assert.are.equal("Verona", readerui._bookbuddy_last_search.query)
    end)

    it("honours the regex flag through to crengine", function()
        -- "Rom.o" as a literal finds nothing; as a regex the '.' matches the 'e'
        -- in Romeo, so the flag must reach findAllText's regex parameter.
        local literal = Tools.execute("grep", { query = "Rom.o", regex = false, spoiler = true }, readerui)
        assert.truthy(literal:find("No matches", 1, true))
        local rx = Tools.execute("grep", { query = "Rom.o", regex = true, spoiler = true }, readerui)
        assert.truthy(rx:find("Romeo", 1, true))
    end)

    it("renders a fuller span in sentence context mode", function()
        local words = Tools.execute("grep", { query = "Verona", context = "words", spoiler = true }, readerui)
        local sentence = Tools.execute("grep", { query = "Verona", context = "sentence", spoiler = true }, readerui)
        assert.truthy(words:find("Verona", 1, true))
        assert.truthy(sentence:find("Verona", 1, true))
        -- the Prologue line "In fair Verona, where we lay our scene" is a full
        -- sentence segment; the windowed (words) mode shows a shorter neighbourhood.
        assert.truthy(sentence:find("where we lay our scene", 1, true))
    end)

    it("hides hits past the reader's current page unless spoiler=true", function()
        -- Sit early in the book; "Verona" appears later (pages 15, 29, …).
        Tools.execute("navigate", { page = 10 }, readerui)
        assert.are.equal(10, support.current_page(Tools, readerui))

        local capped = Tools.execute("grep", { query = "Verona" }, readerui)

        -- a hit beyond page 10 must not leak its page number…
        assert.is_nil(capped:find("[page 15]", 1, true))
        assert.is_nil(capped:find("[page 29]", 1, true))
        -- …and the cap is announced.
        assert.truthy(capped:find("hidden", 1, true))

        -- spoiler=true lifts the cap and reveals a later hit.
        local revealed = Tools.execute("grep", { query = "Verona", spoiler = true }, readerui)
        assert.truthy(revealed:find("[page 15]", 1, true))
    end)

    it("tightens further with max_page below the current page", function()
        Tools.execute("navigate", { page = 30 }, readerui)
        -- max_page=8 caps at page 8, so the page-15 hit is hidden even though we're
        -- at page 30 (max_page can only tighten, never widen past current).
        local out = Tools.execute("grep", { query = "Verona", max_page = 8 }, readerui)
        assert.is_nil(out:find("[page 15]", 1, true))
        assert.truthy(out:find("[page 7]", 1, true)) -- an early hit still shows
    end)

    it("reports no matches for an absent query", function()
        local text, summary = Tools.execute("grep", { query = "zzqqxxnotaword", spoiler = true }, readerui)
        assert.truthy(text:find("No matches", 1, true))
        assert.truthy(summary:find("no matches", 1, true))
    end)
end)
