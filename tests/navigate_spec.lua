-- Pure-luajit checks for the bbtools `navigate` executor: which Event a jump
-- emits and with what args, history push/back behaviour, and the input guards.
-- Real movement across real crengine is proven in tests/integration/real/*_real.lua
-- (`.#test-real`); this spec keeps only what trivial fakes can decide.

local stubs = require("support.stubs")

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
