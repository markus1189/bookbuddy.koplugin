-- Pure-luajit checks for the bbtools `grep` executor: the findAllText call
-- contract, the spoiler/current-page cap, max_page interplay, the empty result,
-- and the last_search bookkeeping. Real hits over real crengine are proven in
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
