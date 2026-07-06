local ConfirmBox = require("ui/widget/confirmbox")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

local Settings = require("bbsettings")
local Chats = require("bbchats")
local Conversation = require("bbconversation")
local Presets = require("bbpresets")

local BookBuddy = WidgetContainer:extend({
    name = "bookbuddy",
    is_doc_only = true,
})

function BookBuddy:init()
    self.settings = Settings:new(self.name)
    self:onDispatcherRegisterActions()
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
    if self.ui and self.ui.highlight then
        self.ui.highlight:addToHighlightDialog("13_bookbuddy", function(this)
            return {
                text = _("Chat with BookBuddy"),
                callback = function()
                    local sel = this.selected_text
                    if not (sel and sel.text and sel.text ~= "") then
                        this:onClose()
                        return
                    end
                    local text = util.cleanupSelectedText(sel.text)
                    -- Reached via an existing highlight's "…" menu, sel is a copy of
                    -- the whole annotation, so it may carry the reader's own note.
                    -- A fresh selection has no note. Keep the note's wording intact
                    -- (cleanupSelectedText is for extracted document text, not prose).
                    local note = sel.note
                    if note == "" then
                        note = nil
                    end
                    this:onClose()
                    self:promptAndStart(text, note)
                end,
            }
        end)
    end
end

function BookBuddy:onDispatcherRegisterActions()
    Dispatcher:registerAction("bookbuddy_ask_selection", {
        category = "none",
        event = "BookBuddyAskSelection",
        title = _("Chat with BookBuddy about selection"),
        reader = true,
    })
    Dispatcher:registerAction("bookbuddy_ask_book", {
        category = "none",
        event = "BookBuddyAskBook",
        title = _("Chat with BookBuddy about this book"),
        reader = true,
    })
end

-- Triggered by a gesture/shortcut: use the current text selection if any.
function BookBuddy:onBookBuddyAskSelection()
    local hl = self.ui and self.ui.highlight
    local sel = hl and hl.selected_text
    if not (sel and sel.text and sel.text ~= "") then
        UIManager:show(InfoMessage:new({
            text = _("Select some text first, then chat with BookBuddy about it."),
        }))
        return true
    end
    local text = util.cleanupSelectedText(sel.text)
    hl:onClose()
    self:promptAndStart(text)
    return true
end

-- Triggered by a gesture/shortcut: a book-level chat, no selection needed.
-- Mirrors the menu's "Chat about this book" entry.
function BookBuddy:onBookBuddyAskBook()
    self:promptAndStart(nil)
    return true
end

function BookBuddy:addToMainMenu(menu_items)
    local menu = self.settings:getMenu(self.ui)
    -- A book-level entry point: start a chat about the whole book, no highlight
    -- needed. Omit keep_menu_open so the menu closes when the chat opens.
    table.insert(menu.sub_item_table, 1, {
        text = _("Chat about this book"),
        callback = function()
            self:promptAndStart(nil)
        end,
    })
    -- Past chats for this book, stored in its sidecar (bbchats). sub_item_table_func
    -- rebuilds the rows on every open, so the list reflects saves/deletes made since.
    table.insert(menu.sub_item_table, 2, {
        text = _("Chat history"),
        -- Divider closing the action cluster; the next row up (Check for updates)
        -- is then framed on its own for prominence.
        separator = true,
        sub_item_table_func = function()
            return self:getChatHistoryItems()
        end,
    })
    menu_items.bookbuddy = menu
end

-- Menu rows for the stored chats: `title · relative-time`, tap to reopen and
-- continue, long-press to delete (with confirmation), plus a trailing
-- "Clear all chats" entry — mirroring Settings:showMemory's clear pattern.
function BookBuddy:getChatHistoryItems()
    local items = {}
    -- The submenu was pushed with the table sub_item_table_func returned, so a
    -- delete/clear must swap a freshly built table in before repainting — a bare
    -- updateItems() would re-render the stale rows.
    local function refresh(touchmenu_instance)
        if touchmenu_instance then
            touchmenu_instance.item_table = self:getChatHistoryItems()
            touchmenu_instance:updateItems()
        end
    end
    for _, row in ipairs(Chats.list(self.ui)) do
        local id, title = row.id, row.title or _("Untitled chat")
        items[#items + 1] = {
            text = T("%1 · %2", title, Chats.relativeTime(row.ts_updated)),
            callback = function()
                self:resumeChat(id)
            end,
            hold_callback = function(touchmenu_instance)
                UIManager:show(ConfirmBox:new({
                    text = T(_("Delete this chat?\n\n%1"), title),
                    ok_text = _("Delete"),
                    ok_callback = function()
                        Chats.delete(self.ui, id)
                        refresh(touchmenu_instance)
                    end,
                }))
            end,
        }
    end
    if #items == 0 then
        items[1] = { text = _("No saved chats yet"), enabled = false }
        return items
    end
    items[#items].separator = true
    items[#items + 1] = {
        text = _("Clear all chats"),
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            UIManager:show(ConfirmBox:new({
                text = _("Delete all saved chats for this book?"),
                ok_text = _("Delete"),
                ok_callback = function()
                    Chats.clear(self.ui)
                    refresh(touchmenu_instance)
                end,
            }))
        end,
    }
    return items
end

-- Reopen a stored chat: rebuild a live Conversation from its payload and show
-- it in Reply mode. A follow-up then resends the restored wire history through
-- the ordinary ask() path — identical to an in-session reply.
function BookBuddy:resumeChat(id)
    local state = Chats.load(self.ui, id)
    if not state then
        UIManager:show(InfoMessage:new({ text = _("BookBuddy: could not load this chat.") }))
        return
    end
    local conversation = Conversation:new({
        ui = self.ui,
        settings = self.settings,
        resume_state = state,
    })
    conversation:reopen()
end

-- Open an input dialog seeded with the highlighted passage (and the reader's note
-- on it, if any), then start a chat.
function BookBuddy:promptAndStart(text, note)
    if not self.settings:isConfigured() then
        UIManager:show(InfoMessage:new({
            text = _("BookBuddy is not configured yet.\nOpen the menu → BookBuddy to set your Claude API key."),
        }))
        return
    end

    -- Truncate on codepoint boundaries: #s / s:sub count bytes, so a 400-byte cut can
    -- land inside a multibyte UTF-8 character (accents, CJK, smart quotes) and render
    -- as a broken glyph in the preview. splitToChars gives codepoint-safe slicing.
    local function clip(s)
        local chars = util.splitToChars(s)
        if #chars > 400 then
            return table.concat(chars, "", 1, 400) .. "…"
        end
        return s
    end

    local has_text = text and text ~= ""
    local description, input_hint
    if not has_text then
        -- Book-level chat: no passage to show, just invite a question about the book.
        description = _("Chat with BookBuddy about this book.")
        input_hint = _("e.g. Who are the main characters so far?")
    else
        if note and note ~= "" then
            description = T(_("About this passage:\n\n%1\n\nYour note:\n\n%2"), clip(text), clip(note))
        else
            description = T(_("About this passage:\n\n%1"), clip(text))
        end
        input_hint = _("e.g. What does this mean in context?")
    end

    local dialog
    local presets = Presets.withCustom(has_text and Presets.passage or Presets.book, self.settings:getCustomPresets())
    local buttons = Presets.buttonRows(presets, function()
        return dialog
    end)
    buttons[#buttons + 1] = {
        {
            text = _("Cancel"),
            id = "close",
            callback = function()
                UIManager:close(dialog)
            end,
        },
        {
            text = _("Send"),
            is_enter_default = true,
            callback = function()
                local question = dialog:getInputText()
                UIManager:close(dialog)
                if not question or question == "" then
                    if not has_text then
                        question = _("Give me a brief overview of this book.")
                    elseif note and note ~= "" then
                        question = _("Discuss my note on this passage.")
                    else
                        question = _("Explain this passage and its significance in the book.")
                    end
                end
                local conversation = Conversation:new({
                    ui = self.ui,
                    settings = self.settings,
                    selected_text = text,
                    note = note,
                })
                conversation:ask(question)
            end,
        },
    }
    dialog = InputDialog:new({
        title = _("Chat with BookBuddy"),
        description = description,
        input = "",
        input_hint = input_hint,
        text_height = Presets.inputLines(2),
        buttons = buttons,
    })
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

return BookBuddy
