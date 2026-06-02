-- Pure-luajit checks for the bbtools `book_context` executor: the assembled
-- title/author/series/page/chapter report, the rolling-vs-paging current-page
-- source, the "page N of M" summary, and the unknown/absent fallbacks. Real
-- props/page/TOC extraction over real crengine is proven in
-- tests/integration/real/context_real.lua (`.#test-real`); this spec keeps only
-- what trivial fakes can decide.

local stubs = require("support.stubs")

describe("book_context (pure)", function()
    local Tools
    setup(function()
        Tools = stubs.load_tools()
    end)

    it("reports title, author, series, page and chapter for a rolling book", function()
        local ui = {
            rolling = {}, -- rolling => current page comes from getCurrentPage
            document = {
                getProps = function()
                    return { title = "The Sea", authors = "A. Writer", series = "Tides #2" }
                end,
                getCurrentPage = function()
                    return 10
                end,
                getPageCount = function()
                    return 200
                end,
            },
            toc = {
                getTocTitleOfCurrentPage = function()
                    return "Chapter 2"
                end,
            },
        }
        local out, summary = Tools.execute("book_context", {}, ui)
        assert.truthy(out:find("Title: The Sea", 1, true))
        assert.truthy(out:find("Author: A. Writer", 1, true))
        assert.truthy(out:find("Series: Tides #2", 1, true))
        assert.truthy(out:find("Current page: 10 of 200", 1, true))
        assert.truthy(out:find("Current chapter: Chapter 2", 1, true))
        assert.are.equal("page 10 of 200", summary)
    end)

    it("reads the current page from view.state for a paging book and omits series/chapter when absent", function()
        local ui = {
            -- no ui.rolling => paging; current page comes from view.state.page
            view = { state = { page = 5 } },
            document = {
                getProps = function()
                    return { title = "Scanned", authors = "Nobody" }
                end,
                getPageCount = function()
                    return 42
                end,
            },
            -- no ui.toc => no chapter line
        }
        local out, summary = Tools.execute("book_context", {}, ui)
        assert.truthy(out:find("Current page: 5 of 42", 1, true))
        assert.is_nil(out:match("Series:"))
        assert.is_nil(out:match("Current chapter:"))
        assert.are.equal("page 5 of 42", summary)
    end)

    it("falls back to (unknown)/? when props, page count and current page are unavailable", function()
        local ui = {
            -- no rolling, no view => currentPage is nil
            document = {
                getProps = function()
                    return nil
                end,
                getPageCount = function()
                    return nil
                end,
            },
        }
        local out, summary = Tools.execute("book_context", {}, ui)
        assert.truthy(out:find("Title: (unknown)", 1, true))
        assert.truthy(out:find("Author: (unknown)", 1, true))
        assert.truthy(out:find("Current page: ? of ?", 1, true))
        assert.are.equal("page ? of ?", summary)
    end)
end)
