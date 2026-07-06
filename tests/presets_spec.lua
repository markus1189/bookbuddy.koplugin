-- Pure-luajit checks for bbpresets `buttonRows` (the row-chunking, the prefill
-- button formatting -- trailing ellipsis + non-bold weight -- and the callback that
-- prefills the dialog input) and `withCustom` (merging the reader's own prompt
-- templates after a built-in list). The static preset tables (book/passage/followup)
-- and the DPI-dependent inputLines() pixel math are data/device concerns, out of scope.

local stubs = require("support.stubs")

describe("Presets.buttonRows", function()
    local Presets
    setup(function()
        stubs.install()
        Presets = require("bbpresets")
    end)

    local function list(n)
        local out = {}
        for i = 1, n do
            out[i] = { "Label" .. i, "Prompt " .. i }
        end
        return out
    end

    it("chunks into rows of two by default", function()
        local rows = Presets.buttonRows(list(5), function() end)
        assert.are.equal(3, #rows)
        assert.are.equal(2, #rows[1])
        assert.are.equal(2, #rows[2])
        assert.are.equal(1, #rows[3])
    end)

    it("honors an explicit per_row", function()
        local rows = Presets.buttonRows(list(4), function() end, 3)
        assert.are.equal(2, #rows)
        assert.are.equal(3, #rows[1])
        assert.are.equal(1, #rows[2])
    end)

    it("labels buttons as prefill controls (ellipsis, non-bold)", function()
        local rows = Presets.buttonRows({ { "Explain", "Explain this passage." } }, function() end)
        local button = rows[1][1]
        assert.are.equal("Explain…", button.text)
        assert.is_false(button.font_bold)
    end)

    it("prefills the dialog input with the preset prompt", function()
        local captured
        local dialog = {
            setInputText = function(_, text)
                captured = text
            end,
        }
        local rows = Presets.buttonRows({ { "Explain", "Explain this passage." } }, function()
            return dialog
        end)
        rows[1][1].callback()
        assert.are.equal("Explain this passage.", captured)
    end)

    it("is a no-op when no dialog is available", function()
        local rows = Presets.buttonRows({ { "Explain", "Explain this passage." } }, function()
            return nil
        end)
        assert.has_no.errors(function()
            rows[1][1].callback()
        end)
    end)
end)

describe("Presets.withCustom", function()
    local Presets
    setup(function()
        stubs.install()
        Presets = require("bbpresets")
    end)

    local builtin = { { "Explain", "Explain this passage." }, { "Define", "Define terms." } }

    it("appends custom templates after the built-ins as {label, prompt} pairs", function()
        local merged = Presets.withCustom(builtin, {
            { label = "Vocab", prompt = "List the difficult vocabulary." },
        })
        assert.are.equal(3, #merged)
        assert.are.equal("Explain", merged[1][1])
        assert.are.equal("Vocab", merged[3][1])
        assert.are.equal("List the difficult vocabulary.", merged[3][2])
    end)

    it("keeps the custom templates' stored order", function()
        local merged = Presets.withCustom({}, {
            { label = "A", prompt = "pa" },
            { label = "B", prompt = "pb" },
        })
        assert.are.equal("A", merged[1][1])
        assert.are.equal("B", merged[2][1])
    end)

    it("returns a plain copy of the built-ins for a nil or empty custom list", function()
        assert.are.equal(2, #Presets.withCustom(builtin, nil))
        assert.are.equal(2, #Presets.withCustom(builtin, {}))
    end)

    it("does not mutate the built-in list", function()
        Presets.withCustom(builtin, { { label = "X", prompt = "px" } })
        assert.are.equal(2, #builtin)
    end)

    it("feeds buttonRows so a custom template prefills the dialog", function()
        local captured
        local dialog = {
            setInputText = function(_, text)
                captured = text
            end,
        }
        local merged = Presets.withCustom({}, { { label = "Vocab", prompt = "List the difficult vocabulary." } })
        local rows = Presets.buttonRows(merged, function()
            return dialog
        end)
        assert.are.equal("Vocab…", rows[1][1].text)
        rows[1][1].callback()
        assert.are.equal("List the difficult vocabulary.", captured)
    end)
end)
