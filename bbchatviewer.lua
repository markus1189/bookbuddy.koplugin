-- Builds the scrollable transcript window. Thin wrapper over TextViewer with a
-- custom button row. While a reply is streaming the row shows Stop (opts.on_stop);
-- once the turn is done it shows Reply (opts.on_followup).
--
-- When opts.status_text is set, a one-line status bar (spinner/elapsed/context,
-- composed by bbstatusbar via bbconversation) is inserted into the TextViewer's
-- layout between the text and the buttons, and updateStatus repaints just that
-- row. The insertion reaches into TextViewer internals, so it is feature-detected
-- and pcall-guarded: if a KOReader upgrade rearranges the layout, the bar
-- degrades to a text line appended to the transcript (the _showRetryStatus
-- idiom) instead of crashing the plugin.
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InfoMessage = require("ui/widget/infomessage")
local Size = require("ui/size")
local TextViewer = require("ui/widget/textviewer")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local Screen = Device.screen
local _ = require("gettext")

local ChatViewer = {}

-- Splice the status row into the TextViewer frame's VerticalGroup, above the
-- button row. Layout coupling (verified against KOReader v2024.11-v2025.08):
-- viewer.frame[1] is VerticalGroup{ titlebar, CenterContainer(text),
-- CenterContainer(buttons) }. Anything unexpected errors out to the pcall in
-- build(), which flips the viewer into text-append fallback mode.
local function attachStatusBar(viewer, status_widget, bar_height)
    local vg = viewer.frame and viewer.frame[1]
    if type(vg) ~= "table" or #vg < 3 or not viewer.button_table then
        error("unexpected TextViewer layout")
    end
    -- The zero-border FrameContainer wrapper is not decoration: unlike
    -- CenterContainer (which never records its own x/y), FrameContainer:paintTo
    -- sets self.dimen on every paint, and updateStatus needs that positioned
    -- dimen as its partial-refresh region.
    local container = FrameContainer:new({
        bordersize = 0,
        margin = 0,
        padding = 0,
        CenterContainer:new({
            dimen = Geom:new({ w = viewer.width, h = bar_height }),
            status_widget,
        }),
    })
    table.insert(vg, #vg, container)
    -- Insertion happens before the first paint, so layout caches should be cold;
    -- reset defensively in case a future TextViewer sizes the group in init().
    if vg.resetLayout then
        vg:resetLayout()
    end
    viewer._bb_status = { widget = status_widget, container = container }
end

-- opts: { title, text, on_followup, on_stop, status_text, on_close, scroll_to_bottom }
function ChatViewer.build(opts)
    local viewer
    local first_row = {}
    if opts.on_stop then
        first_row[#first_row + 1] = {
            text = _("Stop"),
            callback = function()
                if opts.on_stop then
                    opts.on_stop()
                end
            end,
        }
    else
        first_row[#first_row + 1] = {
            text = _("Reply"),
            callback = function()
                if opts.on_followup then
                    opts.on_followup()
                end
            end,
        }
    end
    if Device:hasClipboard() then
        first_row[#first_row + 1] = {
            text = _("Copy"),
            callback = function()
                -- Read the live widget text so copying mid-stream isn't stale.
                Device.input.setClipboardText(viewer.scroll_text_w.text_widget.text)
                UIManager:show(InfoMessage:new({
                    text = _("Conversation copied to clipboard."),
                    timeout = 2,
                }))
            end,
        }
    end
    first_row[#first_row + 1] = {
        text = _("Close"),
        callback = function()
            UIManager:close(viewer)
        end,
    }
    -- Build the status widget first: its height decides how much to shave off the
    -- TextViewer so the composed window keeps the stock footprint.
    local status_widget, bar_height
    if opts.status_text then
        status_widget = TextWidget:new({
            text = opts.status_text,
            face = Font:getFace("xx_smallinfofont"),
            -- Truncate rather than wrap: the bar must stay exactly one line tall,
            -- since its height was subtracted from the text area below.
            max_width = Screen:getWidth() - Screen:scaleBySize(30) - 2 * Size.padding.large,
        })
        bar_height = status_widget:getSize().h + 2 * Size.padding.small
    end
    viewer = TextViewer:new({
        title = opts.title or _("BookBuddy"),
        text = opts.text,
        text_type = "lookup",
        buttons_table = { first_row },
        add_default_buttons = false,
        -- Shrink the text area by exactly the bar's height so the total window
        -- height stays at TextViewer's default. Mirrors the stock formula
        -- (textviewer.lua: height or Screen:getHeight() - Screen:scaleBySize(30));
        -- if that default ever changes the window is merely a bar taller/shorter.
        height = bar_height and (Screen:getHeight() - Screen:scaleBySize(30) - bar_height) or nil,
    })
    -- Latest transcript body, kept for the fallback path of updateStatus (which
    -- must re-append the status line to the CURRENT text, not the build-time one).
    viewer._bb_body = opts.text
    if opts.status_text then
        local ok = pcall(attachStatusBar, viewer, status_widget, bar_height)
        if not ok then
            viewer._bb_status_fallback = true
            ChatViewer.updateStatus(viewer, opts.status_text)
        end
    end
    if opts.on_close then
        -- Chain, don't clobber: TextViewer:onCloseWidget does its own refresh.
        -- Fires on every close path (Close button, titlebar x, tap-outside,
        -- multiswipe), which is how the conversation stops the status ticker when
        -- the reader dismisses the viewer mid-stream.
        local orig_close = viewer.onCloseWidget
        viewer.onCloseWidget = function(this)
            opts.on_close()
            if orig_close then
                return orig_close(this)
            end
        end
    end
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
    if not viewer then
        return
    end
    -- Track the body for updateStatus's fallback composition -- but not when the
    -- caller IS that fallback, or each repaint would fold the previous status
    -- line into the body and stack duplicates.
    if not viewer._bb_status_painting then
        viewer._bb_body = text
    end
    viewer.scroll_text_w.text_widget:setText(text)
    viewer.scroll_text_w:updateScrollBar(true)
    if scroll_to_bottom then
        viewer.scroll_text_w:scrollToBottom()
    end
    UIManager:setDirty(viewer, function()
        return "ui", viewer.frame.dimen
    end)
end

-- Repaint just the status row (widget path: a one-line "ui" region refresh, far
-- cheaper on e-ink than a full-frame repaint). In fallback mode the status rides
-- as the transcript's last line instead; a streaming flush overwrites it until
-- the next ticker paint re-appends it -- a cosmetic, self-healing degradation.
function ChatViewer.updateStatus(viewer, text)
    if not viewer then
        return
    end
    local st = viewer._bb_status
    if st then
        st.widget:setText(text)
        UIManager:setDirty(viewer, function()
            -- The container's dimen is positioned by its first paint; until then
            -- (or if a relayout cleared it) fall back to the whole frame.
            return "ui", st.container.dimen or viewer.frame.dimen
        end)
    elseif viewer._bb_status_fallback then
        viewer._bb_status_painting = true
        ChatViewer.updateText(viewer, (viewer._bb_body or "") .. "\n\n" .. text, true)
        viewer._bb_status_painting = false
    end
end

return ChatViewer
