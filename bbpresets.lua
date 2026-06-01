local _ = require("gettext")

local Presets = {}

Presets.book = {
    { _("Overview"), _("Give me a brief overview of this book.") },
    { _("Characters"), _("Who are the main characters so far?") },
    { _("Themes"), _("What are the main themes of this book?") },
    { _("Recap"), _("Recap what has happened up to where I am.") },
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
            text = preset[1],
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
