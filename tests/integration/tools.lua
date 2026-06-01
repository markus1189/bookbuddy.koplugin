-- Integration tests: BookBuddy tool executors driven against hand-rolled fake
-- KOReader documents/UIs (no real crengine). These are PARKED here until Tier 2
-- (real-crengine in-tree tool tests) absorbs them. The pure-logic checks that
-- used to sit beside them — the conversation loop, SSE parser, request
-- validator, markdown stripping, memory/update/settings — now live in the busted
-- suite (tests/*_spec.lua, run via `nix run .#test`).
--
-- Run it with: luajit tests/integration/tools.lua   (from the plugin dir)
--          or: nix run nixpkgs#luajit -- tests/integration/tools.lua

-- Resolve paths. `here` is tests/integration; the plugin root is two levels up.
-- `dir` is kept at tests/ so the moved blocks' `dir .. "/../bbtools.lua"` (a
-- verbatim relic of the old harness layout) still resolves to the plugin root.
local script = (arg and arg[0]) or "tests/integration/tools.lua"
local here = script:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../../?.lua;" .. package.path
local dir = here .. "/.."

local function noop() end

-- bbtools' load-time deps. Only cleanupSelectedText (util), template (ffi/util)
-- and rapidjson.object (getSpecs, unused by the executors) are actually reached.
package.loaded["logger"] = { dbg = noop, warn = noop, info = noop, error = noop }
package.loaded["gettext"] = function(s)
    return s
end
package.loaded["ffi/util"] = {
    template = function(fmt, ...)
        local args = { ... }
        return (fmt:gsub("%%(%d+)", function(n)
            return tostring(args[tonumber(n)] or "")
        end))
    end,
}
package.loaded["util"] = {
    cleanupSelectedText = function(text)
        return (tostring(text or ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
    end,
}
package.loaded["rapidjson"] = {
    object = function(t)
        return t or {}
    end,
}

local total_pass, total_fail = 0, 0

print("\n=== Unit: navigate tool executor ===")
do
    package.loaded["ui/event"] = {
        new = function(_, handler, a, b)
            return { handler = handler, args = { a, b } }
        end,
    }
    local RealTools = dofile(dir .. "/../bbtools.lua")

    local function makeUI(o)
        o = o or {}
        local rec = { events = {}, pushes = 0, backs = 0 }
        local page = o.page or 10
        local ui = {
            rolling = o.rolling, -- nil => paging engine
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
                findAllText = function()
                    return o.hits
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

    local function check(label, cond)
        if cond then
            total_pass = total_pass + 1
            print("  ok:   " .. label)
        else
            total_fail = total_fail + 1
            print("  FAIL: " .. label)
        end
    end

    do -- page jump (paging engine)
        local ui, rec = makeUI({ page = 10, chapter = "Chapter 1" })
        local result, summary = RealTools.execute("navigate", { page = 88 }, ui)
        check("page: pushed to history once", rec.pushes == 1)
        check(
            "page: one GotoPage event to 88",
            #rec.events == 1 and rec.events[1].handler == "GotoPage" and rec.events[1].args[1] == 88
        )
        check("page: result reports prior page 10", result:find("page 10") ~= nil)
        check("page: summary set", summary ~= nil and summary ~= "")
    end

    do -- percent jump
        local ui, rec = makeUI({ page = 10 })
        RealTools.execute("navigate", { percent = 50 }, ui)
        check("percent: pushed once", rec.pushes == 1)
        check(
            "percent: GotoPercent 50",
            rec.events[1] and rec.events[1].handler == "GotoPercent" and rec.events[1].args[1] == 50
        )
    end

    do -- chapter jump, rolling engine with xpointer
        local ui, rec = makeUI({
            rolling = true,
            page = 5,
            toc = {
                { title = "One", page = 1, xpointer = "xp1" },
                { title = "Two", page = 40, xpointer = "xp40" },
            },
        })
        RealTools.execute("navigate", { chapter_index = 2 }, ui)
        check("chapter(rolling): pushed once", rec.pushes == 1)
        check(
            "chapter(rolling): GotoXPointer xp40",
            rec.events[1] and rec.events[1].handler == "GotoXPointer" and rec.events[1].args[1] == "xp40"
        )
    end

    do -- chapter jump, paging engine without xpointer
        local ui, rec = makeUI({ page = 5, toc = { { title = "One", page = 1 }, { title = "Two", page = 40 } } })
        RealTools.execute("navigate", { chapter_index = 2 }, ui)
        check(
            "chapter(paging): GotoPage 40",
            rec.events[1] and rec.events[1].handler == "GotoPage" and rec.events[1].args[1] == 40
        )
    end

    do -- back with a non-empty history stack
        local ui, rec = makeUI({ page = 88, location_stack = { { page = 10 } } })
        RealTools.execute("navigate", { back = true }, ui)
        check("back: called onGoBackLink", rec.backs == 1)
        check("back: did not push to stack", rec.pushes == 0)
    end

    do -- back with an empty history stack
        local ui, rec = makeUI({ page = 88, location_stack = {} })
        local result = RealTools.execute("navigate", { back = true }, ui)
        check("back(empty): did not call onGoBackLink", rec.backs == 0)
        check("back(empty): explains there is nothing to go back to", result:find("no previous location") ~= nil)
    end

    do -- no target / multiple targets
        local ui = makeUI({})
        check("no target: errors", RealTools.execute("navigate", {}, ui):find("exactly one") ~= nil)
        check(
            "multi target: errors",
            RealTools.execute("navigate", { page = 5, percent = 50 }, ui):find("only one") ~= nil
        )
    end

    -- grep tool executor: regex/context forwarding, sentence-anchored locators, and
    -- the page-level spoiler cap. A ROLLING stub so currentPage(ui) is driven by
    -- getCurrentPage; getPageFromXPointer maps each hit's start xpointer to a page;
    -- findAllText returns seeded hits and records the regex (5th) arg;
    -- extendXPointersToSentenceSegment returns o.seg (a table or nil).
    -- grep tool executor: regex/context forwarding, sentence-anchored locators, and
    -- the page-level spoiler cap. A ROLLING stub so currentPage(ui) is driven by
    -- getCurrentPage; getPageFromXPointer maps each hit's start xpointer to a page;
    -- findAllText returns seeded hits and records the regex (5th) arg;
    -- extendXPointersToSentenceSegment returns o.seg (a table or nil).
    print("\n=== Unit: grep tool executor ===")
    local function makeGrepUI(o)
        o = o or {}
        local rec = { regex = nil }
        local ui = {
            rolling = {},
            view = { state = { page = o.current_page or 1 } },
            document = {
                getCurrentPage = function()
                    return o.current_page or 1
                end,
                findAllText = function(_, _q, _ci, _nw, _mx, regex)
                    rec.regex = regex
                    return o.hits
                end,
                getPageFromXPointer = function(_, xp)
                    return o.page_of and o.page_of[xp]
                end,
                extendXPointersToSentenceSegment = function(_, _p0, _p1)
                    return o.seg
                end,
            },
        }
        return ui, rec
    end

    -- Scenario 9: context="words" (default), regex flag forwarded, loc minted, last_search lock-step.
    do
        local ui, rec = makeGrepUI({
            current_page = 99,
            hits = {
                {
                    start = "xpA",
                    ["end"] = "xpA2",
                    matched_text = "Mara",
                    prev_text = "when ",
                    next_text = " walked",
                },
            },
            page_of = { xpA = 2 },
        })
        local out = RealTools.execute("grep", { query = "Mara", regex = true }, ui)
        check("9 regex forwarded as 5th findAllText arg", rec.regex == true)
        check("9 word snippet contains query", out:find("Mara", 1, true) ~= nil)
        check("9 mints a loc token", out:find("loc:%d") ~= nil)
        check(
            "9 last_search lock-step with shown hit",
            ui._bookbuddy_last_search and ui._bookbuddy_last_search.items and #ui._bookbuddy_last_search.items == 1
        )
    end

    -- Scenario 10: context="sentence" renders the sentence span and anchors the loc to it.
    do
        local ui = makeGrepUI({
            current_page = 99,
            hits = { { start = "xpA", ["end"] = "xpA2", matched_text = "harbour" } },
            page_of = { xpA = 2 },
            seg = { text = "Mara walked to the harbour.", pos0 = "xpS0", pos1 = "xpS1" },
        })
        local out = RealTools.execute("grep", { query = "harbour", context = "sentence" }, ui)
        check("10 sentence mode shows full sentence", out:find("Mara walked to the harbour", 1, true) ~= nil)
        local n = tonumber(out:match("loc:(%d+)"))
        check("10 loc anchored to sentence pos0", n and ui._bookbuddy_locators[n].xp == "xpS0")
        check("10 loc anchored to sentence pos1", n and ui._bookbuddy_locators[n].xp_end == "xpS1")
    end

    -- Scenario 15: page-level spoiler cap. Hits on pages 2,4,5; current page 3.
    do
        local function ghits()
            return {
                { start = "xp2", ["end"] = "xp2b", matched_text = "Mara" },
                { start = "xp4", ["end"] = "xp4b", matched_text = "Mara" },
                { start = "xp5", ["end"] = "xp5b", matched_text = "Mara" },
            }
        end
        local page_of = { xp2 = 2, xp4 = 4, xp5 = 5 }
        -- default: page-2 hit visible, pages 4&5 hidden + counted, pages not leaked.
        local ui = makeGrepUI({ current_page = 3, hits = ghits(), page_of = page_of })
        local out = RealTools.execute("grep", { query = "Mara" }, ui)
        check("15 default cap shows page-2 hit", out:find("page 2", 1, true) ~= nil)
        check("15 hidden page 4 not leaked", out:find("page 4", 1, true) == nil)
        check("15 hidden page 5 not leaked", out:find("page 5", 1, true) == nil)
        check("15 reports a hidden count", out:find("hidden") ~= nil)
        -- spoiler=true reveals all three.
        local ui2 = makeGrepUI({ current_page = 3, hits = ghits(), page_of = page_of })
        local out2 = RealTools.execute("grep", { query = "Mara", spoiler = true }, ui2)
        check("15 spoiler reveals page 4", out2:find("page 4", 1, true) ~= nil)
        check("15 spoiler reveals page 5", out2:find("page 5", 1, true) ~= nil)
        -- max_page below current tightens further: cap=1 hides even page-2 hit.
        local ui3 = makeGrepUI({ current_page = 3, hits = ghits(), page_of = page_of })
        local out3 = RealTools.execute("grep", { query = "Mara", max_page = 1 }, ui3)
        check("15 max_page=1 tightens (page 2 hidden)", out3:find("page 2", 1, true) == nil)
    end

    print("\n=== Unit: edit_highlight_note tool executor ===")
    local function makeHlUI(anns)
        local rec = { events = {}, pdf = {} }
        local ui = {
            annotation = { annotations = anns },
            highlight = {
                writePdfAnnotation = function(_, action, item, content)
                    rec.pdf[#rec.pdf + 1] = { action = action, item = item, content = content }
                end,
            },
            handleEvent = function(_, event)
                rec.events[#rec.events + 1] = event
            end,
        }
        return ui, rec
    end

    do -- set-if-empty on a note-less highlight; display index 1 skips the bookmark
        local anns = {
            { text = nil, note = nil, pageno = 1 }, -- bare bookmark
            { text = "passage", note = nil, pageno = 10, chapter = "Ch 1" }, -- highlight, no note
            { text = "more", note = "old", pageno = 20 }, -- highlight with note
        }
        local ui, rec = makeHlUI(anns)
        local result, summary = RealTools.execute("edit_highlight_note", { highlight_index = 1, note = "new" }, ui)
        check(
            "edit: index 1 maps past the bare bookmark to annotations[2]",
            anns[2].note == "new" and anns[1].note == nil
        )
        check("edit: untouched highlight keeps its note", anns[3].note == "old")
        check("edit: result reports it was added", result:find("Added") ~= nil)
        check("edit: result echoes the new note", result:find("new") ~= nil)
        check("edit: summary set", summary ~= nil and summary ~= "")
        check(
            "edit: fired AnnotationsModified with note counter +1",
            rec.events[1]
                and rec.events[1].handler == "AnnotationsModified"
                and rec.events[1].args[1].nb_notes_added == 1
        )
        check("edit: wrote pdf annotation content", rec.pdf[1] and rec.pdf[1].action == "content")
    end

    do -- append to a highlight that already has a note
        local anns = {
            { text = "passage", note = nil, pageno = 10 },
            { text = "more", note = "old", pageno = 20 },
        }
        local ui, rec = makeHlUI(anns)
        local result = RealTools.execute("edit_highlight_note", { highlight_index = 2, note = "added" }, ui)
        check("edit(append): joined below the existing note with a blank line", anns[2].note == "old\n\nadded")
        check("edit(append): result reports it was appended", result:find("Appended") ~= nil)
        check(
            "edit(append): fired AnnotationsModified to refresh timestamp",
            rec.events[1] and rec.events[1].args[1].modify_datetime == true
        )
    end

    do -- error cases leave notes untouched
        local anns = { { text = "passage", note = "keep", pageno = 10 } }
        local ui = makeHlUI(anns)
        check(
            "edit: out-of-range index errors",
            RealTools.execute("edit_highlight_note", { highlight_index = 9, note = "x" }, ui):find("between 1 and")
                ~= nil
        )
        check(
            "edit: blank note errors",
            RealTools.execute("edit_highlight_note", { highlight_index = 1, note = "   " }, ui):find("required") ~= nil
        )
        check("edit: errors did not mutate the note", anns[1].note == "keep")
    end

    do -- no highlights to edit
        local ui = makeHlUI({})
        check(
            "edit: empty book errors",
            RealTools.execute("edit_highlight_note", { highlight_index = 1, note = "x" }, ui):find("no highlights")
                ~= nil
        )
    end

    -- create_highlight: positions never come from the model. The search_result path
    -- reuses the xpointers grep already produced; the text path re-searches
    -- and disambiguates by occurrence/page. A rolling (EPUB) ui with the document,
    -- annotation, view and toc surfaces the tool touches.
    print("\n=== Unit: create_highlight tool executor ===")
    local function makeCreateUI(o)
        o = o or {}
        local rec = { events = {} }
        local anns = {}
        local ui
        ui = {
            rolling = (o.rolling ~= false) or nil, -- default rolling; pass rolling=false for paging
            view = {
                highlight = { saved_drawer = "lighten", saved_color = "yellow" },
                footer = { maybeUpdateFooter = function() end },
            },
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
                    return o.invalid_xp ~= true
                end,
            },
            toc = {
                getTocTitleByPage = function()
                    return o.chapter or "Some Chapter"
                end,
                getTocTitleOfCurrentPage = function()
                    return o.chapter or "Some Chapter"
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
            handleEvent = function(_, event)
                rec.events[#rec.events + 1] = event
            end,
        }
        return ui, rec, anns
    end

    do -- highlight a prior search result by its number; reuses that match's xpointers
        local hits = {
            { start = "xpA", ["end"] = "xpA2", matched_text = "alpha" },
            { start = "xpB", ["end"] = "xpB2", matched_text = "beta" },
        }
        local ui, rec, anns = makeCreateUI({
            hits = hits,
            page_of = { xpA = 3, xpB = 7 },
            text_of = { xpA = "the alpha passage" },
        })
        RealTools.execute("grep", { query = "x", spoiler = true }, ui) -- populates ui._bookbuddy_last_search
        local result, summary = RealTools.execute(
            "create_highlight",
            { search_result = 1, color = "red", drawer = "underscore", note = "key bit" },
            ui
        )
        check("create(handle): added exactly one annotation", #anns == 1)
        check("create(handle): reused match 1's start xpointer", anns[1] and anns[1].pos0 == "xpA")
        check("create(handle): page key set to the same xpointer", anns[1] and anns[1].page == "xpA")
        check("create(handle): text read from that position", anns[1] and anns[1].text == "the alpha passage")
        check(
            "create(handle): chosen color/drawer applied",
            anns[1] and anns[1].color == "red" and anns[1].drawer == "underscore"
        )
        check("create(handle): note attached", anns[1] and anns[1].note == "key bit")
        check("create(handle): pageno filled via getPageFromXPointer", anns[1] and anns[1].pageno == 3)
        check(
            "create(handle): fired AnnotationsModified +1",
            rec.events[1]
                and rec.events[1].handler == "AnnotationsModified"
                and rec.events[1].args[1].nb_highlights_added == 1
        )
        check("create(handle): result reports the page", result:find("page 3") ~= nil)
        check("create(handle): summary set", summary ~= nil and summary ~= "")
    end

    do -- highlight by verbatim text; color/drawer fall back to the saved style
        local ui, _, anns = makeCreateUI({
            hits = { { start = "xpC", ["end"] = "xpC2", matched_text = "gamma" } },
            page_of = { xpC = 5 },
            text_of = { xpC = "gamma sentence" },
        })
        local result = RealTools.execute("create_highlight", { text = "gamma" }, ui)
        check("create(text): added one annotation", #anns == 1)
        check(
            "create(text): default drawer/color from saved style",
            anns[1] and anns[1].drawer == "lighten" and anns[1].color == "yellow"
        )
        check("create(text): no note when none given", anns[1] and anns[1].note == nil)
        check("create(text): result echoes the text", result:find("gamma sentence") ~= nil)
    end

    do -- ambiguous text: multiple matches, no occurrence -> ask, highlight nothing
        local ui, _, anns = makeCreateUI({
            hits = { { start = "xp1", ["end"] = "xp1b" }, { start = "xp2", ["end"] = "xp2b" } },
            page_of = { xp1 = 4, xp2 = 9 },
        })
        local result, summary = RealTools.execute("create_highlight", { text = "dup" }, ui)
        check("create(ambiguous): reports both pages", result:find("4") ~= nil and result:find("9") ~= nil)
        check("create(ambiguous): asks for occurrence/page", result:find("occurrence") ~= nil)
        check("create(ambiguous): added nothing", #anns == 0)
        check("create(ambiguous): summary marks it ambiguous", summary ~= nil and summary ~= "")
    end

    do -- ambiguous text resolved by occurrence picks the right match
        local ui, _, anns = makeCreateUI({
            hits = { { start = "xp1", ["end"] = "xp1b" }, { start = "xp2", ["end"] = "xp2b" } },
            page_of = { xp1 = 4, xp2 = 9 },
            text_of = { xp2 = "second one" },
        })
        RealTools.execute("create_highlight", { text = "dup", occurrence = 2 }, ui)
        check("create(occurrence): picked the 2nd match", anns[1] and anns[1].pos0 == "xp2")
        check("create(occurrence): text from the 2nd position", anns[1] and anns[1].text == "second one")
    end

    do -- error/guard cases highlight nothing
        local ui, _, anns = makeCreateUI({ rolling = false }) -- paging engine
        check(
            "create: paging engine rejected as EPUB-only",
            RealTools.execute("create_highlight", { text = "x" }, ui):find("reflowable") ~= nil
        )
        check("create: paging added nothing", #anns == 0)

        local ui2, _, anns2 = makeCreateUI({ hits = {} })
        check("create: no input errors", RealTools.execute("create_highlight", {}, ui2):find("provide") ~= nil)
        check(
            "create: stale/empty search_result errors",
            RealTools.execute("create_highlight", { search_result = 1 }, ui2):find("no recent search results") ~= nil
        )
        check(
            "create: text with no matches errors",
            RealTools.execute("create_highlight", { text = "absent" }, ui2):find("No passage matching") ~= nil
        )
        check(
            "create: bad color rejected",
            RealTools.execute("create_highlight", { text = "x", color = "chartreuse" }, ui2):find("'color' must be")
                ~= nil
        )
        check("create: guard/error cases added nothing", #anns2 == 0)
    end
end

--------------------------------------------------------------------------------
-- Unit: the `read` tool (forward char-budgeted reader over a fake "tape").
--
-- The fake document is an ordered array of word texts (the "tape"); a position is
-- the token "tp:<i>" for 1-based tape index i. getPageXPointer(page) returns the
-- tape token at that page's first word (via opts.page_to_tape). The advance loop,
-- spoiler clamp, locator table and end-of-book handling are all exercised for real.
--
-- package.loaded["bbtools"] is the conversation-loop stub, so load the real module
-- fresh (mirroring the navigate/create_highlight executor tests) to exercise read.
--------------------------------------------------------------------------------
package.loaded["ui/event"] = package.loaded["ui/event"] or {
    new = function()
        return {}
    end,
}
local ReadTools = dofile(dir .. "/../bbtools.lua")

-- Build a ui whose document is a word tape. opts:
--   tape          : array of word strings (default 40 short words)
--   current_page  : the reader's current page (default 1)
--   page_count    : total pages (default large)
--   page_to_tape  : page -> first tape index (default {[1]=1}); unmapped pages
--                   resolve past the tape end so a single-page tape never clamps
--   tape_to_page  : tape index -> page (default everything on page 1)
--   invalid_xp    : a tape token isXPointerInDocument should report as stale
--   has_pages     : true to model a paging (non-reflowable) doc
local function makeReadUI(opts)
    opts = opts or {}
    local tape = opts.tape
    if not tape then
        tape = {}
        for i = 1, 40 do
            tape[i] = string.format("w%03d", i)
        end
    end
    local page_to_tape = opts.page_to_tape or { [1] = 1 }
    local tape_to_page = opts.tape_to_page
    local current_page = opts.current_page or 1
    local page_count = opts.page_count or 9999

    local function idx(xp)
        if type(xp) ~= "string" then
            return nil
        end
        local n = xp:match("^tp:(%d+)$")
        return n and tonumber(n) or nil
    end
    local function tok(i)
        return "tp:" .. i
    end

    local doc = {}
    doc.info = { has_pages = opts.has_pages or false }
    function doc:getCurrentPage()
        return current_page
    end
    function doc:getPageCount()
        return page_count
    end
    function doc:getPageXPointer(page)
        return tok(page_to_tape[page] or (#tape + 1))
    end
    function doc:getPageFromXPointer(xp)
        local i = idx(xp)
        if not i then
            return nil
        end
        if tape_to_page then
            return tape_to_page[i] or 1
        end
        return 1
    end
    function doc:getNextVisibleWordEnd(xp)
        local i = idx(xp)
        if not i or i >= #tape then
            return nil
        end -- end of tape (eob)
        return tok(i + 1)
    end
    function doc:getNextVisibleChar(xp)
        local i = idx(xp)
        if not i or i >= #tape then
            return nil
        end
        return tok(i + 1)
    end
    function doc:compareXPointers(a, b)
        local ia, ib = idx(a), idx(b)
        if not ia or not ib then
            return nil
        end
        if ib > ia then
            return 1
        elseif ib < ia then
            return -1
        else
            return 0
        end
    end
    function doc:getTextFromXPointers(a, b)
        local ia, ib = idx(a), idx(b)
        if not ia or not ib or ia >= ib then
            return ""
        end
        local parts = {}
        for i = ia, ib - 1 do
            parts[#parts + 1] = tape[i] or ""
        end
        return table.concat(parts, " ")
    end
    function doc:isXPointerInDocument(xp)
        return xp ~= opts.invalid_xp
    end
    function doc:extendXPointersToSentenceSegment(_pos0, _pos1)
        return opts.sentence_seg -- nil unless a scenario seeds one (Step 3 uses it)
    end

    local ui = {
        rolling = {}, -- currentPage uses getCurrentPage; the EPUB guard uses doc.info.has_pages
        document = doc,
        view = { state = { page = current_page } },
    }
    return ui, tape
end

print("\n=== Unit: read tool ===")
do
    local function check(label, cond)
        if cond then
            total_pass = total_pass + 1
            print("  ok:   " .. label)
        else
            total_fail = total_fail + 1
            print("  FAIL: " .. label)
        end
    end

    -- 1. read{} at current page: text, header, a next locator, within budget.
    --    A long tape so the default 1500-char budget stops mid-tape (emitting a
    --    continuation locator) rather than reaching end-of-book.
    do
        local long = {}
        for i = 1, 600 do
            long[i] = string.format("w%03d", i)
        end
        local ui = makeReadUI({ tape = long, page_count = 9999, page_to_tape = { [1] = 1 } })
        local out = ReadTools.execute("read", {}, ui)
        check("1 current-page: header", out:find("reading forward", 1, true) ~= nil)
        check("1 current-page: next locator", out:match("from: (loc:%d+)") ~= nil)
        local body = out:match("reading forward:\n\n(.-)\n\n%(") or ""
        check("1 current-page: body within limit", #body > 0 and #body <= 1500)
        -- Word boundary: the first tape word appears whole, nothing mid-word cut.
        check("1 current-page: whole words", out:find("w001", 1, true) ~= nil)
    end

    -- 2. read{from=next} resumes exactly where the previous chunk ended.
    do
        local t = {}
        for i = 1, 60 do
            t[i] = string.format("c%03d", i)
        end
        local ui = makeReadUI({ tape = t, page_count = 9999, page_to_tape = { [1] = 1 } })
        local out1 = ReadTools.execute("read", { limit = 40 }, ui)
        local nexttok = out1:match("from: (loc:%d+)")
        check("2 continue: first chunk emitted a next", nexttok ~= nil)
        local out2 = nexttok and ReadTools.execute("read", { from = nexttok }, ui) or ""
        -- Chunk 1 covered words up to xp_end = tp:k; chunk 2 begins at c<k>, the word
        -- immediately after chunk 1's last word c<k-1>. No gap, no overlap.
        local first2 = tonumber((out2:match("reading forward:\n\n(c%d+)") or ""):match("(%d+)"))
        local last1
        for w in out1:gmatch("c(%d+)") do
            last1 = tonumber(w)
        end
        check("2 continue: no gap/overlap at boundary", first2 ~= nil and last1 ~= nil and first2 == last1 + 1)
    end

    -- 3. read from a pre-seeded span locator starts at the span's start xpointer.
    do
        local ui = makeReadUI({ current_page = 9000, page_count = 9999, page_to_tape = { [9000] = 1 } })
        ui._bookbuddy_locators = { { kind = "span", xp = "tp:8", xp_end = "tp:10" } }
        ui._bookbuddy_loc_seq = 1
        local out = ReadTools.execute("read", { from = "loc:1", spoiler = true }, ui)
        check("3 span loc: starts at span start (w008)", out:find("w008", 1, true) ~= nil)
        check("3 span loc: excludes earlier word w007", out:find("w007", 1, true) == nil)
    end

    -- 4. read from a page-number string, and from a seeded point locator.
    do
        local ui = makeReadUI({ page_count = 100, page_to_tape = { [20] = 5 } })
        local out = ReadTools.execute("read", { from = "20", spoiler = true }, ui)
        check("4 page string: header names page 20", out:find("page 20", 1, true) ~= nil)
        check("4 page string: starts at page 20's first word (w005)", out:find("w005", 1, true) ~= nil)

        local ui2 = makeReadUI({ page_count = 100, page_to_tape = { [1] = 1 } })
        ui2._bookbuddy_locators = { { kind = "point", xp = "tp:5" } }
        ui2._bookbuddy_loc_seq = 1
        local out2 = ReadTools.execute("read", { from = "loc:1", spoiler = true }, ui2)
        check("4 point loc: starts at index 5 (w005)", out2:find("w005", 1, true) ~= nil)
    end

    -- 5. End of book: advance hits nil -> "(End of book reached.)", no next.
    --    Then reading exactly at the end -> "Nothing further".
    do
        local ui = makeReadUI({ page_count = 9999, page_to_tape = { [1] = 38 } }) -- 40-word tape
        local out = ReadTools.execute("read", {}, ui)
        check("5 eob: End of book reached", out:find("End of book reached", 1, true) ~= nil)
        check("5 eob: no next locator", out:match("loc:%d") == nil)

        -- Start one position past the last word (tp:#tape+1): no word remains, so the
        -- range is empty and getNextVisibleWordEnd is nil -> "Nothing further".
        local ui2 = makeReadUI({ page_count = 9999, page_to_tape = { [1] = 1 } }) -- 40-word tape
        ui2._bookbuddy_locators = { { kind = "point", xp = "tp:41" } }
        ui2._bookbuddy_loc_seq = 1
        local out2 = ReadTools.execute("read", { from = "loc:1", spoiler = true }, ui2)
        check("5 at-end: nothing further", out2:find("Nothing further", 1, true) ~= nil)
    end

    -- 6. Stale locator (isXPointerInDocument=false) degrades to a page fallback with
    --    a "layout changed" prefix but still returns text. Unknown/garbled -> error.
    do
        local ui = makeReadUI({
            current_page = 9000,
            page_count = 9999,
            page_to_tape = { [9000] = 1, [1] = 1 },
            tape_to_page = setmetatable({}, {
                __index = function()
                    return 1
                end,
            }),
            invalid_xp = "tp:8",
        })
        ui._bookbuddy_locators = { { kind = "point", xp = "tp:8" } }
        ui._bookbuddy_loc_seq = 1
        local out = ReadTools.execute("read", { from = "loc:1", spoiler = true }, ui)
        check("6 stale: layout changed prefix", out:find("layout changed", 1, true) ~= nil)
        check("6 stale: still returns text", out:find("reading forward", 1, true) ~= nil)

        local ui2 = makeReadUI({})
        check(
            "6 unknown loc: stale error",
            ReadTools.execute("read", { from = "loc:999" }, ui2):find("stale", 1, true) ~= nil
        )
        check("6 garbled: stale error", ReadTools.execute("read", { from = "@@@" }, ui2):find("stale", 1, true) ~= nil)
    end

    -- 7. Tiny limit must still strictly advance the cursor (forced progress).
    do
        local ui = makeReadUI({ page_count = 9999, page_to_tape = { [1] = 1 } })
        local out = ReadTools.execute("read", { limit = 1, spoiler = true }, ui)
        local nexttok = out:match("from: (loc:%d+)")
        check("7 tiny limit: emitted a next locator", nexttok ~= nil)
        if nexttok then
            local out2 = ReadTools.execute("read", { from = nexttok, limit = 1, spoiler = true }, ui)
            check("7 tiny limit: cursor advanced", out2 ~= out)
        end
    end

    -- 8. Paging (non-reflowable) doc -> EPUB-only guard, no error.
    do
        local ui = makeReadUI({ has_pages = true })
        local out = ReadTools.execute("read", {}, ui)
        check(
            "8 paging doc: EPUB/reflowable guard",
            out:find("EPUB", 1, true) ~= nil or out:find("reflowable", 1, true) ~= nil
        )
    end

    -- 13. Spoiler refuse: a start past the current page is refused (no text/next);
    --     spoiler=true reads.
    do
        local long = {}
        for i = 1, 600 do
            long[i] = string.format("w%03d", i)
        end
        local ui = makeReadUI({
            tape = long,
            current_page = 10,
            page_count = 100,
            page_to_tape = { [10] = 1, [50] = 20, [11] = 5 },
            tape_to_page = setmetatable({}, {
                __index = function(_, i)
                    if i >= 20 then
                        return 50
                    elseif i >= 5 then
                        return 11
                    else
                        return 10
                    end
                end,
            }),
        })
        local out = ReadTools.execute("read", { from = "50" }, ui)
        check("13 refuse: 'past where you are'", out:find("past where you are", 1, true) ~= nil)
        check("13 refuse: no next locator", out:match("loc:%d") == nil)
        check("13 refuse: no body text", out:find("reading forward", 1, true) == nil)

        local out2 = ReadTools.execute("read", { from = "50", spoiler = true }, ui)
        check("13 spoiler=true: reads (header)", out2:find("reading forward", 1, true) ~= nil)
        check("13 spoiler=true: emits a next locator", out2:match("loc:%d") ~= nil)
    end

    -- 14. Spoiler clamp: read{} whose forward chunk would cross into cur+1 stops at
    --     the page boundary, no next; spoiler=true crosses.
    do
        -- Words 1..5 are on page 10; word 6 onward on page 11. getPageXPointer(11)=tp:6.
        -- A long tape so the spoiler=true read stops on budget (with a next loc).
        local long = {}
        for i = 1, 600 do
            long[i] = string.format("w%03d", i)
        end
        local ui = makeReadUI({
            tape = long,
            current_page = 10,
            page_count = 100,
            page_to_tape = { [10] = 1, [11] = 6 },
            tape_to_page = setmetatable({}, {
                __index = function(_, i)
                    if i >= 6 then
                        return 11
                    else
                        return 10
                    end
                end,
            }),
        })
        local out = ReadTools.execute("read", {}, ui)
        check("14 clamp: 'Stopped at your current page'", out:find("Stopped at your current page", 1, true) ~= nil)
        check("14 clamp: no next locator", out:match("loc:%d") == nil)
        check("14 clamp: stops before w006", out:find("w006", 1, true) == nil)
        check("14 clamp: includes page-10 words", out:find("w005", 1, true) ~= nil)

        local out2 = ReadTools.execute("read", { spoiler = true }, ui)
        check("14 spoiler=true: crosses boundary (w006)", out2:find("w006", 1, true) ~= nil)
        check("14 spoiler=true: emits a next locator", out2:match("loc:%d") ~= nil)
    end

    -- A. get_toc mints a point loc: token per entry that has an xpointer, and read
    --    can resolve that token to begin reading at the chapter's start.
    do
        local long = {}
        for i = 1, 40 do
            long[i] = string.format("w%03d", i)
        end
        local ui = makeReadUI({ tape = long, page_count = 100, page_to_tape = { [1] = 1 } })
        -- makeReadUI's fake doc has no getToc; attach one returning a single chapter
        -- whose start xpointer is a tape token the doc understands (tp:5).
        ui.document.getToc = function()
            return { { title = "Ch 1", page = 1, depth = 1, xpointer = "tp:5" } }
        end
        local out = ReadTools.execute("get_toc", {}, ui)
        check("A get_toc: lists the chapter title", out:find("Ch 1", 1, true) ~= nil)
        check("A get_toc: keeps the page label", out:find("(page 1)", 1, true) ~= nil)
        check("A get_toc: mints a loc: token", out:match("loc:%d+") ~= nil)
        check("A get_toc: locator actually minted onto ui", (ui._bookbuddy_loc_seq or 0) >= 1)

        -- B. read resolves the toc-minted point locator: starts at the chapter's
        --    xpointer (tape index 5 -> w005), reads forward, not a stale error.
        local toc_loc = out:match("(loc:%d+)")
        local out2 = ReadTools.execute("read", { from = toc_loc, spoiler = true }, ui)
        check("B read toc loc: reads forward", out2:find("reading forward", 1, true) ~= nil)
        check("B read toc loc: starts at chapter xpointer (w005)", out2:find("w005", 1, true) ~= nil)
        check("B read toc loc: not a stale error", out2:find("stale", 1, true) == nil)
    end

    -- C. A TOC entry without an xpointer prints no loc: suffix and does not error
    --    (paging docs / xpointer-less entries can't drive read's forward advance).
    do
        local ui = makeReadUI({ page_count = 100, page_to_tape = { [1] = 1 } })
        ui.document.getToc = function()
            return { { title = "Front matter", page = 1, depth = 1 } } -- no xpointer
        end
        local out = ReadTools.execute("get_toc", {}, ui)
        check("C get_toc: lists the xpointer-less entry", out:find("Front matter", 1, true) ~= nil)
        check("C get_toc: no loc: suffix for it", out:match("loc:%d+") == nil)
    end
end

print(string.format("\n==== %d check(s) passed, %d failed ====", total_pass, total_fail))
os.exit(total_fail == 0 and 0 or 1)
