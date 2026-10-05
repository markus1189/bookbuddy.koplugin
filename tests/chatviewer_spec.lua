-- bbchatviewer against both TextViewer field layouts: KOReader v2026.07 (#15588)
-- exposes the ScrollTextWidget as scroll_widget, earlier releases as scroll_text_w.
local stubs = require("support.stubs")

describe("chatviewer", function()
    local ChatViewer, clipboard
    local saved = {}
    local faked = {
        "device",
        "ui/geometry",
        "ui/size",
        "ui/widget/container/centercontainer",
        "ui/widget/container/framecontainer",
        "ui/widget/textviewer",
        "ui/widget/textwidget",
    }

    local function newScroll(text)
        local s = { text_widget = { text = text }, bottom = 0 }
        function s.text_widget:setText(t)
            self.text = t
        end
        function s:scrollToBottom()
            self.bottom = self.bottom + 1
        end
        function s:updateScrollBar() end
        return s
    end

    -- field: which name the fake TextViewer stores its ScrollTextWidget under.
    local function installTextViewer(field)
        package.loaded["ui/widget/textviewer"] = {
            new = function(_, o)
                o[field] = newScroll(o.text)
                o.frame = { dimen = {} }
                return o
            end,
        }
        package.loaded["bbchatviewer"] = nil
        ChatViewer = require("bbchatviewer")
    end

    setup(function()
        stubs.install()
        for _, m in ipairs(faked) do
            saved[m] = package.loaded[m]
        end
        package.loaded["device"] = {
            screen = {
                getWidth = function()
                    return 600
                end,
                getHeight = function()
                    return 800
                end,
                scaleBySize = function(_, n)
                    return n
                end,
            },
            hasClipboard = function()
                return true
            end,
            input = {
                setClipboardText = function(t)
                    clipboard = t
                end,
            },
        }
        package.loaded["ui/geometry"] = {}
        package.loaded["ui/size"] = { padding = { large = 10, small = 2 } }
        package.loaded["ui/widget/container/centercontainer"] = {}
        package.loaded["ui/widget/container/framecontainer"] = {}
        package.loaded["ui/widget/textwidget"] = {}
        local UIManager = package.loaded["ui/uimanager"]
        UIManager.setDirty = UIManager.setDirty or function() end
    end)

    teardown(function()
        for _, m in ipairs(faked) do
            package.loaded[m] = saved[m]
        end
        package.loaded["bbchatviewer"] = nil
    end)

    for _, field in ipairs({ "scroll_widget", "scroll_text_w" }) do
        describe("with TextViewer." .. field, function()
            before_each(function()
                clipboard = nil
                installTextViewer(field)
            end)

            it("builds, scrolls to bottom, streams text, and copies the live text", function()
                local v = ChatViewer.build({ text = "You: hi", scroll_to_bottom = true, on_stop = function() end })
                assert.are.equal(1, v[field].bottom)

                ChatViewer.updateText(v, "You: hi\n\nBookBuddy: hello", true)
                assert.are.equal("You: hi\n\nBookBuddy: hello", v[field].text_widget.text)
                assert.are.equal(2, v[field].bottom)

                local copy
                for _, b in ipairs(v.buttons_table[1]) do
                    if b.text == "Copy" then
                        copy = b
                    end
                end
                copy.callback()
                assert.are.equal("You: hi\n\nBookBuddy: hello", clipboard)
            end)
        end)
    end
end)
