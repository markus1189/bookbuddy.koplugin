-- Pure-luajit checks for the bbtools `create_highlight` executor: color/drawer
-- validation, the reflowable-only gate, occurrence/ambiguity math, and reuse of a
-- prior search_result's xpointers. Real highlighting over real crengine is proven
-- in tests/integration/real/*_real.lua (`.#test-real`); this spec keeps only what
-- trivial fakes can decide.

local stubs = require("support.stubs")
local noop = stubs.noop

-- bbtools requires ui/event (not part of stubs.install): a recording Event double.
local function installEvent()
    package.loaded["ui/event"] = {
        new = function(_, handler, a, b)
            return { handler = handler, args = { a, b } }
        end,
    }
end

-- Load a fresh real bbtools with all its load-time deps stubbed.
local function loadTools()
    stubs.install()
    installEvent()
    package.loaded["bbtools"] = nil
    return require("bbtools")
end

describe("create_highlight (pure)", function()
    local Tools
    setup(function()
        Tools = loadTools()
    end)

    -- A rolling (EPUB) reader whose document re-searches via findAllText; positions
    -- are the seeded xpointers, never invented by the model.
    local function makeCreateUI(o)
        o = o or {}
        local anns = {}
        local ui
        ui = {
            rolling = (o.rolling ~= false) or nil,
            view = { highlight = { saved_drawer = "lighten", saved_color = "yellow" } },
            document = {
                getCurrentPage = function()
                    return 1
                end,
                findAllText = function()
                    return o.hits
                end,
                getPageFromXPointer = function(_, xp)
                    return (o.page_of and o.page_of[xp]) or 1
                end,
                getTextFromXPointers = function(_, p0)
                    return (o.text_of and o.text_of[p0]) or "located text"
                end,
                isXPointerInDocument = function()
                    return true
                end,
            },
            toc = {
                getTocTitleByPage = function()
                    return "Some Chapter"
                end,
            },
            annotation = {
                annotations = anns,
                addItem = function(_, item)
                    item.pageno = ui.document:getPageFromXPointer(item.page)
                    anns[#anns + 1] = item
                    return #anns
                end,
            },
            handleEvent = noop,
        }
        return ui, anns
    end

    it("validates color and drawer against the allowed sets", function()
        local ui = makeCreateUI({ hits = {} })
        assert.truthy(
            Tools.execute("create_highlight", { text = "x", color = "chartreuse" }, ui):find("'color' must be")
        )
        assert.truthy(
            Tools.execute("create_highlight", { text = "x", drawer = "squiggle" }, ui):find("'drawer' must be")
        )
    end)

    it("rejects a paging engine as EPUB-only", function()
        local ui = makeCreateUI({ rolling = false })
        assert.truthy(Tools.execute("create_highlight", { text = "x" }, ui):find("reflowable"))
    end)

    it("errors with no input, a stale search_result, or text with no match", function()
        local ui = makeCreateUI({ hits = {} })
        assert.truthy(Tools.execute("create_highlight", {}, ui):find("provide"))
        assert.truthy(Tools.execute("create_highlight", { search_result = 1 }, ui):find("no recent search results"))
        assert.truthy(Tools.execute("create_highlight", { text = "absent" }, ui):find("No passage matching"))
    end)

    it("asks which occurrence when a passage matches more than once", function()
        local ui, anns = makeCreateUI({
            hits = { { start = "xp1", ["end"] = "xp1b" }, { start = "xp2", ["end"] = "xp2b" } },
            page_of = { xp1 = 4, xp2 = 9 },
        })
        local result, summary = Tools.execute("create_highlight", { text = "dup" }, ui)
        assert.truthy(result:find("4") and result:find("9")) -- names both pages
        assert.truthy(result:find("occurrence"))
        assert.are.equal(0, #anns) -- highlights nothing while ambiguous
        assert.truthy(summary:find("ambiguous"))
    end)

    it("resolves the chosen occurrence to that match's xpointers", function()
        local ui, anns = makeCreateUI({
            hits = { { start = "xp1", ["end"] = "xp1b" }, { start = "xp2", ["end"] = "xp2b" } },
            page_of = { xp1 = 4, xp2 = 9 },
            text_of = { xp2 = "second one" },
        })
        Tools.execute("create_highlight", { text = "dup", occurrence = 2 }, ui)
        assert.are.equal("xp2", anns[1].pos0)
        assert.are.equal("second one", anns[1].text)
    end)

    it("reuses a prior search_result's xpointers verbatim", function()
        local ui, anns = makeCreateUI({
            hits = { { start = "xpA", ["end"] = "xpA2", matched_text = "alpha" } },
            page_of = { xpA = 3 },
            text_of = { xpA = "the alpha passage" },
        })
        Tools.execute("grep", { query = "alpha", spoiler = true }, ui) -- populates last_search
        local result =
            Tools.execute("create_highlight", { search_result = 1, color = "red", drawer = "underscore" }, ui)
        assert.are.equal("xpA", anns[1].pos0)
        assert.are.equal("the alpha passage", anns[1].text)
        assert.are.equal("red", anns[1].color)
        assert.are.equal("underscore", anns[1].drawer)
        assert.truthy(result:find("page 3"))
    end)
end)
