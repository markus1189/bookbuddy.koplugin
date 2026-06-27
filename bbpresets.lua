local _ = require("gettext")
local T = require("ffi/util").template
local Font = require("ui/font")

local Presets = {}

-- Pixel height for an N-line InputDialog text box using its default input face
-- (x_smallinfofont). Mirrors TextBoxWidget's line_height_px formula
-- (round((1 + 0.3em spacing) * face.size)) so the box shows exactly N lines;
-- face.size is already DPI-scaled, so this tracks the device.
function Presets.inputLines(n)
    local line_px = math.floor(1.3 * Font:getFace("x_smallinfofont").size + 0.5)
    return line_px * n
end

Presets.book = {
    {
        _("Get started"),
        _(
            "I'm just starting this book. Before I get into it, interview me about what I want to focus on or pay attention to as I read -- ask a few short questions, one at a time, then note what I tell you so you can keep it in mind as we go."
        ),
    },
    { _("Overview"), _("Give me a brief overview of this book.") },
    { _("Characters"), _("Who are the main characters so far?") },
    { _("Themes"), _("What are the main themes of this book?") },
    { _("Recap"), _("Recap what has happened up to where I am.") },
    { _("Highlights"), _("Let's chat about my current highlights and notes") },
    { _("Memories"), _("Let's chat about the book memories") },
    {
        _("Update notes"),
        _(
            "Update your memory notes up to my current position, then end with a short section on the most important progressions."
        ),
    },
}

Presets.passage = {
    { _("Explain"), _("Explain this passage and its significance in the book.") },
    { _("Why it matters"), _("Why is this passage significant?") },
    { _("Define"), _("Define any difficult terms or references in this passage.") },
    { _("Simpler"), _("Explain this passage in simpler terms.") },
}

Presets.followup = {
    { _("Yes"), _("Yes.") },
    { _("Memorize"), _("Write a memory for this.") },
    { _("Highlight"), _("Create a highlight with a note") },
}

function Presets.buttonRows(list, get_dialog, per_row)
    per_row = per_row or 2

    local rows = {}
    local row

    for i, preset in ipairs(list) do
        if (i - 1) % per_row == 0 then
            row = {}
            rows[#rows + 1] = row
        end
        local prompt = preset[2]
        row[#row + 1] = {
            -- Trailing ellipsis + non-bold weight mark these as prefill buttons:
            -- they drop text into the input for you to edit, rather than acting.
            -- Action buttons (Send/Cancel/Reply) stay bold and unsuffixed.
            text = T(_("%1…"), preset[1]),
            font_bold = false,
            callback = function()
                local dialog = get_dialog()
                if dialog then
                    dialog:setInputText(prompt, nil, false)
                end
            end,
        }
    end

    return rows
end

return Presets
