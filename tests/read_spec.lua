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

    -- A richer reflowable fake that MODELS ordered positions: page p maps to the
    -- integer xpointer p*1000, words advance +100, and a span's text is ~1 char per
    -- step. That lets the spoiler gate's refuse and clamp branches -- the most
    -- safety-critical code in read -- actually run, where reflowableUI() (noop
    -- stepping) can only reach the guards. compareXPointers returns 1 iff the second
    -- arg is after the first, matching crengine's contract.
    local function steppingUI(current_page)
        local cur = current_page or 10
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

    describe("page-level spoiler gate", function()
        it("refuses a start past the reader's current page, with no text or locator", function()
            local out = Tools.execute("read", { from = "100" }, steppingUI(10))
            assert.truthy(out:find("past where you are", 1, true))
            assert.is_nil(out:find("reading forward", 1, true))
            assert.is_nil(out:match("loc:%d"))
        end)

        it("clamps a forward read at the next page, with no read-ahead continuation", function()
            local out = Tools.execute("read", {}, steppingUI(10))
            assert.truthy(out:find("Stopped at your current page", 1, true))
            assert.is_nil(out:match("from: loc:%d"))
        end)

        it("spoiler=true lifts both the refuse and the clamp", function()
            local refused = Tools.execute("read", { from = "100", spoiler = true }, steppingUI(10))
            assert.is_nil(refused:find("past where you are", 1, true))
            local clamped = Tools.execute("read", { spoiler = true }, steppingUI(10))
            assert.is_nil(clamped:find("Stopped at your current page", 1, true))
        end)
    end)
end)
