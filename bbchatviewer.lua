-- Builds the scrollable transcript window. Thin wrapper over TextViewer with a
-- custom button row (Ask follow-up / Copy / Close).
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local ChatViewer = {}

-- opts: { title, text, on_followup }
function ChatViewer.build(opts)
    local viewer
    local first_row = {
        {
            text = _("Ask follow-up"),
            callback = function()
                if opts.on_followup then opts.on_followup() end
            end,
        },
        {
            text = _("Close"),
            callback = function()
                UIManager:close(viewer)
            end,
        },
    }
    if Device:hasClipboard() then
        table.insert(first_row, 2, {
            text = _("Copy"),
            callback = function()
                Device.input.setClipboardText(opts.text)
                UIManager:show(InfoMessage:new{
                    text = _("Conversation copied to clipboard."),
                    timeout = 2,
                })
            end,
        })
    end
    viewer = TextViewer:new{
        title = opts.title or _("BookBuddy"),
        text = opts.text,
        text_type = "lookup",
        buttons_table = { first_row },
        add_default_buttons = false,
    }
    return viewer
end

return ChatViewer
