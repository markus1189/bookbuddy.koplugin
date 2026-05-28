-- Builds the scrollable transcript window. Thin wrapper over TextViewer with a
-- custom button row. While a reply is streaming the row shows Stop (opts.on_stop);
-- once the turn is done it shows Ask follow-up (opts.on_followup).
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local ChatViewer = {}

-- opts: { title, text, on_followup, on_stop, scroll_to_bottom }
function ChatViewer.build(opts)
    local viewer
    local first_row = {}
    if opts.on_stop then
        first_row[#first_row + 1] = {
            text = _("Stop"),
            callback = function()
                if opts.on_stop then opts.on_stop() end
            end,
        }
    else
        first_row[#first_row + 1] = {
            text = _("Ask follow-up"),
            callback = function()
                if opts.on_followup then opts.on_followup() end
            end,
        }
    end
    if Device:hasClipboard() then
        first_row[#first_row + 1] = {
            text = _("Copy"),
            callback = function()
                -- Read the live widget text so copying mid-stream isn't stale.
                Device.input.setClipboardText(viewer.scroll_text_w.text_widget.text)
                UIManager:show(InfoMessage:new{
                    text = _("Conversation copied to clipboard."),
                    timeout = 2,
                })
            end,
        }
    end
    first_row[#first_row + 1] = {
        text = _("Close"),
        callback = function()
            UIManager:close(viewer)
        end,
    }
    viewer = TextViewer:new{
        title = opts.title or _("BookBuddy"),
        text = opts.text,
        text_type = "lookup",
        buttons_table = { first_row },
        add_default_buttons = false,
    }
    -- Land on the newest turn. The text widget is fully laid out at construction,
    -- so this is safe before the viewer is shown: the first paint renders at the
    -- bottom rather than flashing the top first.
    if opts.scroll_to_bottom then
        viewer.scroll_text_w:scrollToBottom()
    end
    return viewer
end

-- Replace the viewer's text in place and repaint, for live streaming updates.
-- The deferred refresh region (function form) is evaluated after the next paint,
-- so it works even if called before the viewer's first paint laid out the frame.
function ChatViewer.updateText(viewer, text, scroll_to_bottom)
    if not viewer then return end
    viewer.scroll_text_w.text_widget:setText(text)
    viewer.scroll_text_w:updateScrollBar(true)
    if scroll_to_bottom then
        viewer.scroll_text_w:scrollToBottom()
    end
    UIManager:setDirty(viewer, function()
        return "ui", viewer.frame.dimen
    end)
end

return ChatViewer
