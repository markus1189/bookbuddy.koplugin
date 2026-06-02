-- Pure-luajit checks for the bbtools `read` executor's guards: the reflowable-only
-- gate and stale-locator handling. Real stepping over real words is proven in
-- tests/integration/real/*_real.lua (`.#test-real`); this spec keeps only what
-- trivial fakes can decide.

local stubs = require("support.stubs")
local noop = stubs.noop

describe("read guards (pure)", function()
    local Tools
    setup(function()
        Tools = stubs.load_tools()
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
