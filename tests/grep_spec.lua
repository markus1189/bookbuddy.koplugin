-- Pure-luajit checks for the bbtools `grep` executor: the findAllText call
-- contract, the spoiler/current-page cap, max_page interplay, the min_page window
-- (which filters independently of spoiler), the empty result, and the last_search
-- bookkeeping. Real hits over real crengine are proven in
-- tests/integration/real/*_real.lua (`.#test-real`); this spec keeps only what
-- trivial fakes can decide.

local stubs = require("support.stubs")

describe("grep (pure)", function()
    local Tools
    setup(function()
        Tools = stubs.load_tools()
    end)

    it("requires a query", function()
        local out = Tools.execute("grep", { query = "" }, { document = {} })
        assert.truthy(out:find("'query' is required"))
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

    it("reports the all-hidden case when every hit is past the current page", function()
        -- limit==0: nothing visible survives the spoiler cap, so grep takes the early
        -- all-hidden return and never enters the snippet loop (where the budget is sized).
        local ui = makeGrepUI({
            current_page = 5,
            hits = {
                { start = "a", matched_text = "later" },
                { start = "b", matched_text = "latest" },
            },
            page_of = { a = 15, b = 29 },
        })
        local text, summary = Tools.execute("grep", { query = "Verona" }, ui)
        assert.truthy(text:find("2 match(es) hidden", 1, true))
        assert.is_nil(text:find("[page 15]", 1, true)) -- no later-page hit leaks
        assert.is_nil(text:find("[page 29]", 1, true))
        assert.are.equal("all hidden", summary)
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

    it("still applies an explicit max_page when the reader's page is unknown", function()
        -- Spoiler-safety regression guard: when currentPage is nil the cap must fall
        -- back to max_page, not be dropped (which would reveal every later-page hit).
        local ui = {
            rolling = {},
            view = { state = {} }, -- no resolvable page
            document = {
                getCurrentPage = function()
                    return nil
                end,
                findAllText = function()
                    return {
                        { start = "a", matched_text = "early" },
                        { start = "b", matched_text = "late" },
                    }
                end,
                getPageFromXPointer = function(_, xp)
                    return ({ a = 5, b = 40 })[xp]
                end,
            },
        }
        local text = Tools.execute("grep", { query = "q", max_page = 10 }, ui)
        assert.truthy(text:find("[page 5]", 1, true)) -- within the explicit cap → shown
        assert.is_nil(text:find("[page 40]", 1, true)) -- beyond it → hidden, not leaked
        assert.truthy(text:find("hidden", 1, true)) -- only counted
    end)

    it("hides matches before min_page and reports their count", function()
        local ui = makeGrepUI({
            current_page = 100, -- well past every hit: the spoiler cap drops nothing
            hits = {
                { start = "a", matched_text = "x" },
                { start = "b", matched_text = "y" },
                { start = "c", matched_text = "z" },
            },
            page_of = { a = 5, b = 10, c = 25 },
        })
        local text = Tools.execute("grep", { query = "q", min_page = 10 }, ui)
        assert.is_nil(text:find("[page 5]", 1, true)) -- below the window → dropped
        assert.truthy(text:find("[page 10]", 1, true)) -- at the floor → shown
        assert.truthy(text:find("[page 25]", 1, true)) -- above it → shown
        assert.truthy(text:find("1 earlier match(es) before page 10", 1, true))
    end)

    it("windows a search to [min_page, max_page]", function()
        local ui = makeGrepUI({
            current_page = 100,
            hits = {
                { start = "a", matched_text = "x" },
                { start = "b", matched_text = "y" },
                { start = "c", matched_text = "z" },
            },
            page_of = { a = 5, b = 15, c = 25 },
        })
        local text = Tools.execute("grep", { query = "q", min_page = 10, max_page = 20 }, ui)
        assert.is_nil(text:find("[page 5]", 1, true)) -- below the window
        assert.truthy(text:find("[page 15]", 1, true)) -- inside the window
        assert.is_nil(text:find("[page 25]", 1, true)) -- above the window
    end)

    it("still filters before min_page even with spoiler=true", function()
        -- min_page is a display window, not a spoiler control: spoiler reveals the
        -- later hit but the earlier one stays filtered (it was never a spoiler).
        local ui = makeGrepUI({
            current_page = 10, -- page-25 hit is a spoiler unless spoiler=true
            hits = {
                { start = "a", matched_text = "x" },
                { start = "c", matched_text = "z" },
            },
            page_of = { a = 5, c = 25 },
        })
        local text = Tools.execute("grep", { query = "q", min_page = 10, spoiler = true }, ui)
        assert.is_nil(text:find("[page 5]", 1, true)) -- below min_page → still dropped
        assert.truthy(text:find("[page 25]", 1, true)) -- spoiler revealed it
        assert.truthy(text:find("earlier match(es) before page 10", 1, true))
    end)

    it("reports 'all before page N' rather than 'No matches' when min_page drops everything", function()
        local ui = makeGrepUI({
            current_page = 100,
            hits = { { start = "a", matched_text = "x" }, { start = "b", matched_text = "y" } },
            page_of = { a = 3, b = 7 },
        })
        local text, summary = Tools.execute("grep", { query = "q", min_page = 50 }, ui)
        assert.truthy(text:find("all before page 50", 1, true))
        assert.is_nil(text:find("No matches found", 1, true)) -- the false-negative we guard against
        assert.truthy(summary:find("all earlier", 1, true))
    end)

    it("lets max_results return more than the old cap of 20 (up to 40)", function()
        local hits, page_of = {}, {}
        for i = 1, 30 do
            local xp = "h" .. i
            hits[i] = { start = xp, matched_text = "m" }
            page_of[xp] = i
        end
        local ui = makeGrepUI({ current_page = 100, hits = hits, page_of = page_of })
        local text = Tools.execute("grep", { query = "q", max_results = 40 }, ui)
        assert.truthy(text:find("Found 30 match(es)", 1, true)) -- all 30 shown, no clamp at 20
        assert.truthy(text:find("30. [page 30]", 1, true))
    end)

    it("rejects a present-but-invalid max_results instead of silently reporting no matches", function()
        local function grep(mr)
            local ui = makeGrepUI({ hits = { { start = "a", matched_text = "hit" } }, page_of = { a = 1 } })
            return Tools.execute("grep", { query = "q", max_results = mr }, ui)
        end
        for _, bad in ipairs({ 0, -1, 2.5 }) do
            local out = grep(bad)
            assert.truthy(out:find("'max_results' must be a whole number", 1, true))
            assert.is_nil(out:find("No matches", 1, true)) -- the false-negative we are guarding against
        end
    end)

    it("clamps an over-large max_results to the cap rather than erroring", function()
        local ui = makeGrepUI({ hits = { { start = "a", matched_text = "hit" } }, page_of = { a = 1 } })
        local out = Tools.execute("grep", { query = "q", max_results = 100 }, ui)
        assert.is_nil(out:find("must be a whole number", 1, true)) -- over-asking is allowed
        assert.truthy(out:find("1. [page 1]", 1, true)) -- and the hit is returned
    end)

    it("reports shown-of-available and points at max_results when visible hits exceed it", function()
        local hits, page_of = {}, {}
        for i = 1, 5 do
            local xp = "h" .. i
            hits[i] = { start = xp, matched_text = "m" .. i }
            page_of[xp] = i
        end
        local ui = makeGrepUI({ current_page = 100, hits = hits, page_of = page_of })
        local text = Tools.execute("grep", { query = "q", max_results = 2 }, ui)
        assert.truthy(text:find("Showing 2 of 5 match(es)", 1, true))
        assert.truthy(text:find("raise max_results", 1, true))
        assert.truthy(text:find("2. [page 2]", 1, true)) -- exactly two lines printed
        assert.is_nil(text:find("3. [page 3]", 1, true))
    end)

    it("uses the plain 'Found N' header when nothing is dropped", function()
        local ui =
            makeGrepUI({ current_page = 100, hits = { { start = "a", matched_text = "x" } }, page_of = { a = 1 } })
        local text = Tools.execute("grep", { query = "solo", ["max_page"] = nil }, ui)
        assert.truthy(text:find('Found 1 match(es) for "solo":', 1, true))
        assert.is_nil(text:find("Showing", 1, true))
    end)

    it("budgets each snippet so a full page of long hits never trips the final truncate", function()
        local long = string.rep("verona ", 2000) -- ~14k chars per hit, far over MAX_RESULT_CHARS alone
        local hits, page_of = {}, {}
        for i = 1, 8 do
            local xp = "h" .. i
            hits[i] = { start = xp, matched_text = long }
            page_of[xp] = i
        end
        local ui = makeGrepUI({ current_page = 100, hits = hits, page_of = page_of })
        local text = Tools.execute("grep", { query = "verona" }, ui) -- default max_results = 8
        assert.is_nil(text:find("[truncated]", 1, true)) -- per-result budget kept us under the backstop…
        assert.truthy(text:find("8. [page 8]", 1, true)) -- …so every one of the 8 hits stays visible
        assert.truthy(#text <= 6000) -- and the whole result fits MAX_RESULT_CHARS
    end)

    it("budgets sentence-context snippets too", function()
        local long = string.rep("a sentence that runs on. ", 1000)
        local ui = {
            rolling = {},
            view = { state = { page = 100 } },
            document = {
                getCurrentPage = function()
                    return 100
                end,
                findAllText = function()
                    return { { start = "a", ["end"] = "b", matched_text = "x" } }
                end,
                getPageFromXPointer = function()
                    return 1
                end,
                extendXPointersToSentenceSegment = function()
                    return { text = long, pos0 = "a", pos1 = "b" }
                end,
            },
        }
        local text = Tools.execute("grep", { query = "q", context = "sentence" }, ui)
        assert.is_nil(text:find("[truncated]", 1, true))
        assert.truthy(#text <= 6000)
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
