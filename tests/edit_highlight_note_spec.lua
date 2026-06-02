-- Pure-luajit checks for the bbtools `edit_highlight_note` executor: addressing
-- highlights past bare bookmarks, set vs. append behaviour, the AnnotationsModified
-- dispatch, and the error guards. Real annotation persistence is proven in
-- tests/integration/real/*_real.lua (`.#test-real`); this spec keeps only what
-- trivial fakes can decide.

local stubs = require("support.stubs")

-- bbtools requires ui/event (not part of stubs.install): a recording Event double.
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
