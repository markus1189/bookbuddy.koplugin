-- luacheck: std +busted
-- luacheck: globals disable_plugins
-- (disable_plugins is injected as a global by koreader's commonrequire.)
-- (busted globals aren't auto-detected here because the filename omits the _spec
--  suffix on purpose — see .busted: tests/integration/* is run by explicit path.)
--
-- BookBuddy real-crengine smoke spec (Tier 2). Run with `nix run .#test-real` —
-- fully hermetic (no local koreader checkout): prebuilt nixpkgs#koreader libs +
-- koreader source @ v2025.10 + test-data juliet.epub. NOT part of the pure-luajit
-- `nix run .#test` / `.#check`. Exercises bbtools against a live ReaderUI over the
-- real juliet.epub. See .plans/spike-sdl3-pin.md and AGENTS.md.

describe("BookBuddy tools against a real document", function()
    -- Path to juliet.epub. Defaults to the in-tree emulator layout
    -- (spec/front/unit/data -> test); the hermetic flake harness overrides it via
    -- BB_SAMPLE_EPUB to point straight at the test-data store path.
    local sample_epub = os.getenv("BB_SAMPLE_EPUB") or "spec/front/unit/data/juliet.epub"
    local DocumentRegistry, ReaderUI, Screen, Tools
    local readerui

    setup(function()
        require("commonrequire")
        disable_plugins()
        DocumentRegistry = require("document/documentregistry")
        ReaderUI = require("apps/reader/readerui")
        Screen = require("device").screen
        Tools = require("bbtools")
        readerui = ReaderUI:new{
            dimen = Screen:getSize(),
            document = DocumentRegistry:openDocument(sample_epub),
        }
    end)

    teardown(function()
        readerui:closeDocument()
        readerui:onClose()
    end)

    it("book_context reports title and a real page count", function()
        local text, summary = Tools.execute("book_context", {}, readerui)
        assert.is_string(text)
        assert.truthy(text:find("Title:", 1, true))
        assert.truthy(text:find("Current page:", 1, true))
        -- page count comes from real crengine, so it must be a positive integer
        local total = text:match("Current page:%s*%S+%s+of%s+(%d+)")
        assert.truthy(total)
        assert.is_true(tonumber(total) > 0)
        assert.is_string(summary)
    end)

    it("grep finds a real page-tagged hit for 'Verona'", function()
        -- spoiler=true lifts the current-page cap so the hit can't be hidden.
        local text, summary = Tools.execute("grep", { query = "Verona", spoiler = true }, readerui)
        assert.is_string(text)
        assert.truthy(text:find("Verona", 1, true))
        -- a real result line is "N. [page P] (loc:K) …snippet…"
        local page = text:match("%[page%s+(%d+)%]")
        assert.truthy(page, "expected a [page N] tagged hit, got:\n" .. text)
        assert.is_true(tonumber(page) > 0)
        assert.truthy(text:find("loc:", 1, true))
        assert.is_string(summary)
    end)
end)
