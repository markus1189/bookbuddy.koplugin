-- Hardcoded quick-action presets for the chat input dialogs. Each entry is
-- { label, prompt }: the label is the button text, the prompt seeds the input
-- box (prefill-then-edit) when tapped, so the reader can tweak it before
-- sending. Grouped by chat context: book-level, passage-level, and follow-up.
local _ = require("gettext")

local Presets = {}

Presets.book = {
    { _("Overview"),   _("Give me a brief overview of this book.") },
    { _("Characters"), _("Who are the main characters so far?") },
    { _("Themes"),     _("What are the main themes of this book?") },
    { _("Recap"),      _("Recap what has happened up to where I am.") },
}

Presets.passage = {
    { _("Explain"),        _("Explain this passage and its significance in the book.") },
    { _("Why it matters"), _("Why is this passage significant?") },
    { _("Define"),         _("Define any difficult terms or references in this passage.") },
    { _("Simpler"),        _("Explain this passage in simpler terms.") },
}

Presets.followup = {
    -- "Yes" is first so it's the obvious tap when the agent ends a turn with a
    -- yes/no question. It prefills like the rest, so it's still tap-then-Send.
    { _("Yes"),     _("Yes.") },
    { _("Go on"),   _("Go on.") },
    { _("Simpler"), _("Explain that in simpler terms.") },
    { _("Example"), _("Give me a concrete example.") },
    { _("Why?"),    _("Why is that?") },
}

-- Build InputDialog button rows that prefill the input box when tapped, chunked
-- `per_row` buttons to a row (e-ink screens are narrow). `get_dialog` is a
-- getter rather than the dialog itself: the dialog reference is only assigned
-- after InputDialog:new() returns, so the callbacks close over the getter.
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
            text = preset[1],
            callback = function()
                local dialog = get_dialog()
                if dialog then
                    -- false = leave the cursor at the end so the reader can
                    -- keep typing straight after the seeded prompt.
                    dialog:setInputText(prompt, nil, false)
                end
            end,
        }
    end
    return rows
end

return Presets
