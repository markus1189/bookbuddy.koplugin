-- Pure-luajit checks for the bbtools `get_toc` executor: the empty-TOC report and
-- loc-token minting for entries with/without an xpointer. Real TOC extraction over
-- real crengine is proven in tests/integration/real/*_real.lua (`.#test-real`);
-- this spec keeps only what trivial fakes can decide.

local stubs = require("support.stubs")

describe("get_toc (pure)", function()
    local Tools
    setup(function()
        Tools = stubs.load_tools()
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

    it("mints a point locator for a TOC entry that carries an xpointer", function()
        -- The central feature of get_toc: hand the model a read-from-chapter locator.
        local ui = {
            document = {
                getToc = function()
                    return { { title = "Chapter One", page = 12, depth = 1, xpointer = "xpA" } }
                end,
            },
        }
        local out = Tools.execute("get_toc", {}, ui)
        assert.truthy(out:find("Chapter One", 1, true))
        assert.truthy(out:find("(page 12) (loc:1)", 1, true))
        -- The minted token is a point (not a span), so read(from=loc:1) resolves it.
        assert.are.same({ kind = "point", xp = "xpA" }, ui._bookbuddy_locators[1])
    end)
end)
