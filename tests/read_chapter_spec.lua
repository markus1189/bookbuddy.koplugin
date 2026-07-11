-- The bbtools `read_chapter` executor: input guards, the chapter-boundary walk
-- (sub-sections included, next sibling excluded), the page-level spoiler
-- truncation, and the continuation locator for over-budget chapters. Uses the
-- same ordered-position fake as read_spec: page p maps to xpointer p*1000, words
-- advance +100, and a span's text is 1 char per 100 units, so text lengths are
-- exact and assertable.

local stubs = require("support.stubs")

describe("read_chapter", function()
    local Tools
    setup(function()
        Tools = stubs.load_tools()
    end)

    -- Chapter layout on the p*1000 grid: One [1000,5000), Two [5000,8000) with a
    -- depth-2 sub-section at 6000 that must NOT end it, Three [8000,) running to
    -- the end of the book (word stepping stops at 20000).
    local function defaultToc()
        return {
            { title = "One", page = 1, depth = 1, xpointer = 1000 },
            { title = "Two", page = 5, depth = 1, xpointer = 5000 },
            { title = "Two point one", page = 6, depth = 2, xpointer = 6000 },
            { title = "Three", page = 8, depth = 1, xpointer = 8000 },
        }
    end

    local function steppingUI(current_page, toc)
        local cur = current_page or 50
        toc = toc or defaultToc()
        return {
            rolling = {},
            view = { state = { page = cur } },
            document = {
                info = { has_pages = false },
                getCurrentPage = function()
                    return cur
                end,
                getPageCount = function()
                    return 100
                end,
                getToc = function()
                    return toc
                end,
                getPageXPointer = function(_, p)
                    return p * 1000
                end,
                getPageFromXPointer = function(_, xp)
                    return math.floor(xp / 1000)
                end,
                getNextVisibleWordEnd = function(_, xp)
                    local n = xp + 100
                    return n <= 20000 and n or nil
                end,
                compareXPointers = function(_, a, b)
                    if b > a then
                        return 1
                    elseif b < a then
                        return -1
                    end
                    return 0
                end,
                getTextFromXPointers = function(_, a, b)
                    if not (a and b) or b <= a then
                        return ""
                    end
                    return string.rep("w", math.floor((b - a) / 100))
                end,
            },
        }
    end

    -- The chapter body is the longest run of w's in the output (the header's
    -- chapter titles contain stray single w's); its length is the number of
    -- 100-unit steps the read covered.
    local function bodyLen(out)
        local len = 0
        for run in out:gmatch("w+") do
            len = math.max(len, #run)
        end
        return len
    end

    describe("guards", function()
        it("refuses a paging (non-reflowable) document", function()
            local ui = steppingUI()
            ui.document.info.has_pages = true
            local out = Tools.execute("read_chapter", { chapter_index = 1 }, ui)
            assert.is_true(out:find("EPUB") ~= nil or out:find("reflowable") ~= nil)
        end)

        it("reports a book with no table of contents", function()
            local ui = steppingUI(50, {})
            local out = Tools.execute("read_chapter", { chapter_index = 1 }, ui)
            assert.truthy(out:find("no table of contents", 1, true))
        end)

        it("rejects a missing, fractional, or out-of-range chapter_index", function()
            for _, bad in ipairs({ nil, 0, 2.5, 99, "x" }) do
                local out = Tools.execute("read_chapter", { chapter_index = bad }, steppingUI())
                assert.truthy(out:find("'chapter_index' must be a whole number between 1 and 4", 1, true))
            end
        end)

        it("treats an unknown or garbled continuation locator as stale", function()
            local out = Tools.execute("read_chapter", { chapter_index = 2, from = "loc:999" }, steppingUI())
            assert.truthy(out:find("stale", 1, true))
        end)
    end)

    describe("chapter boundaries", function()
        it("reads a whole chapter through its sub-sections up to the next sibling", function()
            -- Chapter 2 spans 5000..8000: the depth-2 entry at 6000 must not end it,
            -- so the body is 30 steps, not 10.
            local out = Tools.execute("read_chapter", { chapter_index = 2 }, steppingUI(50))
            assert.truthy(out:find("[Chapter 2: Two]", 1, true))
            assert.are.equal(30, bodyLen(out))
            assert.truthy(out:find("(End of chapter.)", 1, true))
            assert.is_nil(out:match("loc:%d")) -- complete: no continuation locator
        end)

        it("reads the last chapter to the end of the book", function()
            -- spoiler=true removes the page clamp so the walk (not the fast-path
            -- span extract) runs and hits the fake's real end of words at 20000.
            local out = Tools.execute("read_chapter", { chapter_index = 4, spoiler = true }, steppingUI(50))
            assert.truthy(out:find("End of book reached", 1, true))
            assert.are.equal(120, bodyLen(out)) -- 8000..20000
        end)

        it("a sub-section chapter ends at the next entry of any shallower depth", function()
            -- Chapter 3 is the depth-2 sub-section [6000,8000): ended by the depth-1
            -- sibling that follows it.
            local out = Tools.execute("read_chapter", { chapter_index = 3 }, steppingUI(50))
            assert.are.equal(20, bodyLen(out))
            assert.truthy(out:find("(End of chapter.)", 1, true))
        end)
    end)

    describe("spoiler truncation", function()
        it("refuses a chapter that starts past the reader's current page, naming read_chapter", function()
            local out = Tools.execute("read_chapter", { chapter_index = 4 }, steppingUI(3))
            assert.truthy(out:find("past where you are", 1, true))
            assert.truthy(out:find("read_chapter again with spoiler=true", 1, true))
            assert.is_true(bodyLen(out) < 3) -- no body text leaked (prose has stray single w's)
        end)

        it("truncates a chapter spanning the reader's position at their current page", function()
            -- Reader on page 6, inside chapter 2 [5000,8000): clamp at page 7's start.
            local out = Tools.execute("read_chapter", { chapter_index = 2 }, steppingUI(6))
            assert.are.equal(20, bodyLen(out)) -- 5000..7000, not ..8000
            assert.truthy(out:find("Chapter truncated at your current page", 1, true))
            assert.is_nil(out:find("(End of chapter.)", 1, true))
            assert.is_nil(out:match("loc:%d")) -- no read-ahead continuation
        end)

        it("spoiler=true lifts both the refuse and the truncation", function()
            local refused = Tools.execute("read_chapter", { chapter_index = 4, spoiler = true }, steppingUI(3))
            assert.is_nil(refused:find("past where you are", 1, true))
            local clamped = Tools.execute("read_chapter", { chapter_index = 2, spoiler = true }, steppingUI(6))
            assert.are.equal(30, bodyLen(clamped))
            assert.truthy(clamped:find("(End of chapter.)", 1, true))
        end)

        it("prefers the end-of-chapter trailer when the clamp and the chapter end coincide", function()
            -- Reader on page 7, chapter 2 ends at page 8's start: the clamp (8000)
            -- ties with the chapter end (8000), and the tie reads as a complete chapter.
            local out = Tools.execute("read_chapter", { chapter_index = 2 }, steppingUI(7))
            assert.are.equal(30, bodyLen(out))
            assert.truthy(out:find("(End of chapter.)", 1, true))
        end)
    end)

    describe("continuation", function()
        it("an over-budget chapter yields a locator that resumes where it stopped", function()
            local ui = steppingUI(50)
            local first = Tools.execute("read_chapter", { chapter_index = 2, limit = 10 }, ui)
            assert.truthy(first:find("Chapter not finished", 1, true))
            local tok = first:match("from: (loc:%d+)")
            assert.is_not_nil(tok)
            local first_len = bodyLen(first)
            assert.is_true(first_len < 30 and first_len >= 10)

            local rest = Tools.execute("read_chapter", { chapter_index = 2, from = tok }, ui)
            assert.truthy(rest:find("(End of chapter.)", 1, true))
            assert.are.equal(30 - first_len, bodyLen(rest)) -- no overlap, no gap
        end)

        it("a continuation landing exactly on the chapter end answers cleanly", function()
            -- Mint a locator at chapter 2's end boundary by hand and resume from it.
            local ui = steppingUI(50)
            ui._bookbuddy_locators = { { kind = "point", xp = 8000 } }
            ui._bookbuddy_loc_seq = 1
            local out = Tools.execute("read_chapter", { chapter_index = 2, from = "loc:1" }, ui)
            assert.truthy(out:find("nothing further in it to read", 1, true))
            assert.are.equal(0, bodyLen(out))
        end)
    end)
end)
