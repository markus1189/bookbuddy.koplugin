-- Pure-luajit checks for the bbtools executors that need NO real document: input
-- validation, dispatch contracts (which Event a tool emits and with what args),
-- occurrence/ambiguity math, and the error guards. Engine behaviour — that grep
-- finds real hits, read steps real words, navigate truly moves the page — is
-- proven against real crengine in tests/integration/real/*_real.lua (`.#test-real`),
-- so this spec deliberately keeps only what trivial fakes can decide deterministically.
-- (Salvaged from the old tests/integration/tools.lua, now retired.)

local stubs = require("support.stubs")
local noop = stubs.noop

-- bbtools requires ui/event (not part of stubs.install): a recording Event double
-- whose .handler/.args let us assert exactly what a tool dispatched.
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

describe("navigate (pure)", function()
    local Tools
    setup(function()
        Tools = loadTools()
    end)

    -- A fake reader: paging engine unless o.rolling; records pushes/back calls and
    -- every dispatched Event.
    local function makeUI(o)
        o = o or {}
        local rec = { events = {}, pushes = 0, backs = 0 }
        local page = o.page or 10
        local ui = {
            rolling = o.rolling,
            view = { state = { page = page } },
            document = {
                getCurrentPage = function()
                    return page
                end,
                getPageCount = function()
                    return o.page_count or 200
                end,
                getToc = function()
                    return o.toc or {}
                end,
            },
            toc = {
                getTocTitleOfCurrentPage = function()
                    return o.chapter or ""
                end,
            },
            link = {
                location_stack = o.location_stack or {},
                addCurrentLocationToStack = function()
                    rec.pushes = rec.pushes + 1
                end,
                onGoBackLink = function()
                    rec.backs = rec.backs + 1
                end,
            },
            handleEvent = function(_, event)
                rec.events[#rec.events + 1] = event
            end,
        }
        return ui, rec
    end

    it("dispatches GotoPage and pushes history on a page jump", function()
        local ui, rec = makeUI({ page = 10, chapter = "Chapter 1" })
        local result = Tools.execute("navigate", { page = 88 }, ui)
        assert.are.equal(1, rec.pushes)
        assert.are.equal(1, #rec.events)
        assert.are.equal("GotoPage", rec.events[1].handler)
        assert.are.equal(88, rec.events[1].args[1])
        assert.truthy(result:find("page 10")) -- reports where it left from
    end)

    it("dispatches GotoPercent on a percent jump", function()
        local ui, rec = makeUI({ page = 10 })
        Tools.execute("navigate", { percent = 50 }, ui)
        assert.are.equal(1, rec.pushes)
        assert.are.equal("GotoPercent", rec.events[1].handler)
        assert.are.equal(50, rec.events[1].args[1])
    end)

    it("uses GotoXPointer for a rolling chapter jump, GotoPage when no xpointer", function()
        local rolling_ui, rrec = makeUI({
            rolling = true,
            page = 5,
            toc = {
                { title = "One", page = 1, xpointer = "xp1" },
                { title = "Two", page = 40, xpointer = "xp40" },
            },
        })
        Tools.execute("navigate", { chapter_index = 2 }, rolling_ui)
        assert.are.equal("GotoXPointer", rrec.events[1].handler)
        assert.are.equal("xp40", rrec.events[1].args[1])

        local paging_ui, prec =
            makeUI({ page = 5, toc = { { title = "One", page = 1 }, { title = "Two", page = 40 } } })
        Tools.execute("navigate", { chapter_index = 2 }, paging_ui)
        assert.are.equal("GotoPage", prec.events[1].handler)
        assert.are.equal(40, prec.events[1].args[1])
    end)

    it("goes back via onGoBackLink without pushing, and refuses an empty stack", function()
        local ui, rec = makeUI({ page = 88, location_stack = { { page = 10 } } })
        Tools.execute("navigate", { back = true }, ui)
        assert.are.equal(1, rec.backs)
        assert.are.equal(0, rec.pushes)

        local empty_ui, erec = makeUI({ page = 88, location_stack = {} })
        local result = Tools.execute("navigate", { back = true }, empty_ui)
        assert.are.equal(0, erec.backs)
        assert.truthy(result:find("no previous location"))
    end)

    it("rejects zero or multiple targets and a non-numeric page", function()
        local ui = makeUI({})
        assert.truthy(Tools.execute("navigate", {}, ui):find("exactly one"))
        assert.truthy(Tools.execute("navigate", { page = 5, percent = 50 }, ui):find("only one"))
        assert.truthy(Tools.execute("navigate", { page = "soon" }, ui):find("'page' must be a number"))
    end)
end)

describe("read guards (pure)", function()
    local Tools
    setup(function()
        Tools = loadTools()
    end)

    -- A reflowable doc that satisfies read's API guard (so we reach the locator
    -- resolution) but whose stepping methods are never actually called in these cases.
    local function reflowableUI()
        return {
            rolling = {},
            view = { state = { page = 1 } },
            document = {
                info = { has_pages = false },
                getCurrentPage = function()
                    return 1
                end,
                getPageCount = function()
                    return 100
                end,
                getPageXPointer = noop,
                getNextVisibleWordEnd = noop,
                compareXPointers = noop,
                getTextFromXPointers = noop,
            },
        }
    end

    it("refuses a paging (non-reflowable) document", function()
        local ui = reflowableUI()
        ui.document.info.has_pages = true
        local out = Tools.execute("read", {}, ui)
        assert.is_true(out:find("EPUB") ~= nil or out:find("reflowable") ~= nil)
    end)

    it("treats an unknown or garbled locator as stale", function()
        assert.truthy(Tools.execute("read", { from = "loc:999" }, reflowableUI()):find("stale"))
        assert.truthy(Tools.execute("read", { from = "@@@" }, reflowableUI()):find("stale"))
    end)
end)

describe("grep / get_toc (pure)", function()
    local Tools
    setup(function()
        Tools = loadTools()
    end)

    it("requires a query", function()
        local out = Tools.execute("grep", { query = "" }, { document = {} })
        assert.truthy(out:find("'query' is required"))
    end)

    it("reports an absent table of contents", function()
        local ui = { document = {
            getToc = function()
                return {}
            end,
        } }
        assert.truthy(Tools.execute("get_toc", {}, ui):find("no table of contents"))
    end)

    it("omits a loc token for a TOC entry that carries no xpointer", function()
        local ui = {
            document = {
                getToc = function()
                    return { { title = "Front matter", page = 1, depth = 1 } }
                end,
            },
        }
        local out = Tools.execute("get_toc", {}, ui)
        assert.truthy(out:find("Front matter", 1, true))
        assert.is_nil(out:match("loc:%d+"))
    end)
end)

describe("grep (pure)", function()
    local Tools
    setup(function()
        Tools = loadTools()
    end)

    -- A rolling (EPUB) reader whose findAllText returns synthetic hits and RECORDS
    -- its own arguments, and whose getPageFromXPointer maps each hit's start xpointer
    -- to a page (o.page_of). o.current_page drives the spoiler cap. No
    -- extendXPointersToSentenceSegment, so grep takes the word-window snippet path.
    local function makeGrepUI(o)
        o = o or {}
        local rec = {}
        local ui = {
            rolling = {},
            view = { state = { page = o.current_page or 1 } },
            document = {
                getCurrentPage = function()
                    return o.current_page or 1
                end,
                findAllText = function(_, query, case, ctx_words, max_hits, regex)
                    rec.findall =
                        { query = query, case = case, ctx_words = ctx_words, max_hits = max_hits, regex = regex }
                    return o.hits
                end,
                getPageFromXPointer = function(_, xp)
                    return o.page_of and o.page_of[xp]
                end,
            },
        }
        return ui, rec
    end

    it("passes case, context-word and hit-cap constants and the coerced regex flag to findAllText", function()
        local function call(input)
            local ui, rec = makeGrepUI({ hits = { { start = "xp1", matched_text = "m" } }, page_of = { xp1 = 1 } })
            Tools.execute("grep", input, ui)
            return rec.findall
        end
        local literal = call({ query = "Rom.o" })
        assert.are.equal("Rom.o", literal.query)
        assert.are.equal(true, literal.case) -- case-insensitive is hard-coded on
        assert.are.equal(10, literal.ctx_words) -- FINDALL_CONTEXT_WORDS
        assert.are.equal(5000, literal.max_hits) -- FINDALL_MAX_HITS
        assert.are.equal(false, literal.regex)
        assert.are.equal(true, call({ query = "x", regex = true }).regex)
        -- only a literal boolean true enables regex; a truthy string stays literal
        assert.are.equal(false, call({ query = "x", regex = "true" }).regex)
    end)

    it("hides hits past the reader's current page and counts them in a trailer", function()
        local ui = makeGrepUI({
            current_page = 10,
            hits = {
                { start = "a", matched_text = "early" },
                { start = "b", matched_text = "mid" },
                { start = "c", matched_text = "late" },
            },
            page_of = { a = 7, b = 15, c = 29 },
        })
        local text, summary = Tools.execute("grep", { query = "Verona" }, ui)
        assert.truthy(text:find("[page 7]", 1, true)) -- at/before current page → shown
        assert.is_nil(text:find("[page 15]", 1, true)) -- later hits leak neither page…
        assert.is_nil(text:find("[page 29]", 1, true))
        assert.truthy(text:find("2 match(es) hidden", 1, true)) -- …nor anything but a count
        assert.truthy(summary:find("match", 1, true))
    end)

    it("reveals every hit and omits the trailer when spoiler=true", function()
        local ui = makeGrepUI({
            current_page = 10,
            hits = {
                { start = "a", matched_text = "early" },
                { start = "b", matched_text = "mid" },
                { start = "c", matched_text = "late" },
            },
            page_of = { a = 7, b = 15, c = 29 },
        })
        local text = Tools.execute("grep", { query = "Verona", spoiler = true }, ui)
        assert.truthy(text:find("[page 15]", 1, true))
        assert.truthy(text:find("[page 29]", 1, true))
        assert.is_nil(text:find("hidden", 1, true)) -- spoiler nils the cap AND the trailer
    end)

    it("lets max_page only tighten the cap, never widen it past the current page", function()
        local function grep(input)
            local ui = makeGrepUI({
                current_page = 20,
                hits = {
                    { start = "a", matched_text = "x" },
                    { start = "b", matched_text = "y" },
                    { start = "c", matched_text = "z" },
                },
                page_of = { a = 5, b = 10, c = 25 },
            })
            return Tools.execute("grep", input, ui)
        end
        -- below current page → tightens: only the page-5 hit survives
        local tight = grep({ query = "q", max_page = 8 })
        assert.truthy(tight:find("[page 5]", 1, true))
        assert.is_nil(tight:find("[page 10]", 1, true))
        assert.is_nil(tight:find("[page 25]", 1, true))
        -- above current page → ignored: cap stays at 20, so page 25 is still hidden
        local wide = grep({ query = "q", max_page = 50 })
        assert.truthy(wide:find("[page 5]", 1, true))
        assert.truthy(wide:find("[page 10]", 1, true))
        assert.is_nil(wide:find("[page 25]", 1, true))
        -- spoiler wins outright: max_page is not even consulted
        local spoiled = grep({ query = "q", max_page = 8, spoiler = true })
        assert.truthy(spoiled:find("[page 25]", 1, true))
    end)

    it("reports no matches for an empty result set", function()
        local ui = makeGrepUI({ hits = {} })
        local text, summary = Tools.execute("grep", { query = "ghost" }, ui)
        assert.truthy(text:find("No matches found", 1, true))
        assert.truthy(summary:find("no matches", 1, true))
    end)

    it("records last_search lock-step with the printed index and loc tokens", function()
        local h1 = { start = "a", matched_text = "one" }
        local h2 = { start = "b", matched_text = "two" }
        local h3 = { start = "c", matched_text = "three" }
        local ui = makeGrepUI({
            current_page = 100, -- well past every hit: nothing is capped
            hits = { h1, h2, h3 },
            page_of = { a = 1, b = 2, c = 3 },
        })
        local text = Tools.execute("grep", { query = "trio" }, ui)
        -- printed line index, page tag and minted loc all agree, 1-based and in order
        assert.truthy(text:find("1. [page 1] (loc:1)", 1, true))
        assert.truthy(text:find("2. [page 2] (loc:2)", 1, true))
        assert.truthy(text:find("3. [page 3] (loc:3)", 1, true))
        -- last_search mirrors exactly the visible hits: same objects, same order
        local ls = ui._bookbuddy_last_search
        assert.are.equal("trio", ls.query)
        assert.are.equal(3, #ls.items)
        assert.are.equal(h1, ls.items[1])
        assert.are.equal(h2, ls.items[2])
        assert.are.equal(h3, ls.items[3])
    end)
end)

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

describe("edit_highlight_note (pure)", function()
    local Tools
    setup(function()
        Tools = loadTools()
    end)

    local function makeHlUI(anns)
        local rec = { events = {} }
        local ui = {
            annotation = { annotations = anns },
            handleEvent = function(_, event)
                rec.events[#rec.events + 1] = event
            end,
        }
        return ui, rec
    end

    it("sets a note on a note-less highlight, skipping a bare bookmark", function()
        local anns = {
            { text = nil, note = nil, pageno = 1 }, -- bare bookmark, not addressable
            { text = "passage", note = nil, pageno = 10 }, -- highlight #1
            { text = "more", note = "old", pageno = 20 }, -- highlight #2
        }
        local ui, rec = makeHlUI(anns)
        local result = Tools.execute("edit_highlight_note", { highlight_index = 1, note = "new" }, ui)
        assert.are.equal("new", anns[2].note) -- index 1 maps past the bookmark
        assert.is_nil(anns[1].note)
        assert.are.equal("old", anns[3].note)
        assert.truthy(result:find("Added"))
        assert.are.equal("AnnotationsModified", rec.events[1].handler)
        assert.are.equal(1, rec.events[1].args[1].nb_notes_added)
    end)

    it("appends below an existing note with a blank line", function()
        local anns = { { text = "passage", note = "old", pageno = 10 } }
        local ui, rec = makeHlUI(anns)
        local result = Tools.execute("edit_highlight_note", { highlight_index = 1, note = "added" }, ui)
        assert.are.equal("old\n\nadded", anns[1].note)
        assert.truthy(result:find("Appended"))
        assert.is_true(rec.events[1].args[1].modify_datetime)
    end)

    it("errors on a bad index, a blank note, or an empty book, mutating nothing", function()
        local anns = { { text = "passage", note = "keep", pageno = 10 } }
        local ui = makeHlUI(anns)
        assert.truthy(
            Tools.execute("edit_highlight_note", { highlight_index = 9, note = "x" }, ui):find("between 1 and")
        )
        assert.truthy(Tools.execute("edit_highlight_note", { highlight_index = 1, note = "   " }, ui):find("required"))
        assert.are.equal("keep", anns[1].note)
        assert.truthy(
            Tools.execute("edit_highlight_note", { highlight_index = 1, note = "x" }, makeHlUI({}))
                :find("no highlights")
        )
    end)
end)
