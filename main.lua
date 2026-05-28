local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

local Settings = require("bbsettings")
local Conversation = require("bbconversation")

local BookBuddy = WidgetContainer:extend{
    name = "bookbuddy",
    is_doc_only = true,
}

function BookBuddy:init()
    self.settings = Settings:new(self.name)
    self:onDispatcherRegisterActions()
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
    if self.ui and self.ui.highlight then
        self.ui.highlight:addToHighlightDialog("13_bookbuddy", function(this)
            return {
                text = _("Ask BookBuddy"),
                callback = function()
                    local sel = this.selected_text
                    if not (sel and sel.text and sel.text ~= "") then
                        this:onClose()
                        return
                    end
                    local text = util.cleanupSelectedText(sel.text)
                    this:onClose()
                    self:promptAndStart(text)
                end,
            }
        end)
    end
end

function BookBuddy:onDispatcherRegisterActions()
    Dispatcher:registerAction("bookbuddy_ask_selection", {
        category = "none",
        event = "BookBuddyAskSelection",
        title = _("Ask BookBuddy about selection"),
        reader = true,
    })
end

-- Triggered by a gesture/shortcut: use the current text selection if any.
function BookBuddy:onBookBuddyAskSelection()
    local hl = self.ui and self.ui.highlight
    local sel = hl and hl.selected_text
    if not (sel and sel.text and sel.text ~= "") then
        UIManager:show(InfoMessage:new{
            text = _("Select some text first, then ask BookBuddy about it."),
        })
        return true
    end
    local text = util.cleanupSelectedText(sel.text)
    hl:onClose()
    self:promptAndStart(text)
    return true
end

function BookBuddy:addToMainMenu(menu_items)
    menu_items.bookbuddy = self.settings:getMenu()
end

-- Open an input dialog seeded with the highlighted passage, then start a chat.
function BookBuddy:promptAndStart(text)
    if not self.settings:isConfigured() then
        UIManager:show(InfoMessage:new{
            text = _("BookBuddy is not configured yet.\nOpen the menu → BookBuddy to set your Portkey API key."),
        })
        return
    end

    local preview = text
    if #preview > 400 then
        preview = preview:sub(1, 400) .. "…"
    end

    local dialog
    dialog = InputDialog:new{
        title = _("Ask BookBuddy"),
        description = T(_("About this passage:\n\n%1"), preview),
        input = "",
        input_hint = _("e.g. What does this mean in context?"),
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function()
                    UIManager:close(dialog)
                end,
            },
            {
                text = _("Ask"),
                is_enter_default = true,
                callback = function()
                    local question = dialog:getInputText()
                    UIManager:close(dialog)
                    if not question or question == "" then
                        question = _("Explain this passage and its significance in the book.")
                    end
                    local conversation = Conversation:new{
                        ui = self.ui,
                        settings = self.settings,
                        selected_text = text,
                    }
                    conversation:ask(question)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

return BookBuddy
