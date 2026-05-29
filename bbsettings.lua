local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local Memory = require("bbmemory")
local Updater = require("bbupdate")

local DEFAULTS = {
    base_url = "https://api.portkey.ai",
    model = "@vertex-eu-global/anthropic.claude-opus-4-8",
    max_tokens = 64000,
    max_turns = 20,
    enable_memory = true,
    -- Adaptive extended thinking. Opus 4.8 supports adaptive thinking only, off
    -- unless requested; its thinking text is omitted unless we ask for the
    -- summarized display, which is what makes reasoning visible (see bbanthropic).
    enable_thinking = true,
    system_prompt = "You are BookBuddy, a concise and insightful reading companion embedded in an e-reader. "
        .. "The user is reading a book and has highlighted a passage to ask you about. "
        .. "You have tools to search the book, read page ranges and chapters, inspect the table of contents, "
        .. "and fetch the book's metadata and the reader's current position. "
        .. "Use these tools to ground your answers in the actual text instead of guessing. "
        .. "You can also move the reader within the book with the navigate tool: to a page, a percentage, "
        .. "a chapter from the table of contents, or back to where they were. When you navigate, tell the "
        .. "reader where you took them; their current spot is saved first, so they can tap Back to return. "
        .. "You can add a note to one of the reader's highlights with the edit_highlight_note tool, "
        .. "identifying it by its number from get_highlights (call that first); your text is appended to "
        .. "any existing note and never overwrites or deletes what the reader already wrote. "
        .. "You can also search the web, but prefer the book itself: use web search only for outside "
        .. "knowledge the book cannot answer (real-world facts, author background, references), and never to "
        .. "look up where the story is heading, since web results can spoil what lies ahead. "
        .. "Quote sparingly, avoid spoilers beyond the reader's current position unless explicitly asked, "
        .. "and keep answers focused and readable on a small e-ink screen. "
        .. "Your replies are displayed as plain text with no markdown rendering, so write in plain prose: "
        .. "do not use markdown formatting such as **bold**, *italics*, # headings, `code`, tables, or "
        .. "bullet characters. Use short paragraphs, and where you need a list, write it in sentences.",
}

local Settings = {}
Settings.__index = Settings

function Settings:new(plugin_name)
    local o = setmetatable({}, self)
    o.file = DataStorage:getSettingsDir() .. "/" .. plugin_name .. ".lua"
    o.store = LuaSettings:open(o.file)
    return o
end

function Settings:get(key)
    return self.store:readSetting(key, DEFAULTS[key])
end

function Settings:set(key, value)
    self.store:saveSetting(key, value)
    self.store:flush()
end

-- Plain serializable table for the HTTP layer (no widget/document refs).
function Settings:getConfig()
    return {
        base_url = self:get("base_url"),
        portkey_api_key = self:get("portkey_api_key"),
        model = self:get("model"),
        max_tokens = tonumber(self:get("max_tokens")) or DEFAULTS.max_tokens,
        max_turns = math.max(1, tonumber(self:get("max_turns")) or DEFAULTS.max_turns),
        system_prompt = self:get("system_prompt"),
        enable_memory = self:get("enable_memory") and true or false,
        enable_thinking = self:get("enable_thinking") and true or false,
    }
end

function Settings:isConfigured()
    local key = self:get("portkey_api_key")
    return key ~= nil and key ~= ""
end

-- Generic single-line string/number editor.
function Settings:editText(touchmenu_instance, opts)
    local dialog
    dialog = InputDialog:new{
        title = opts.title,
        description = opts.description,
        input = tostring(self:get(opts.key) or ""),
        input_type = opts.input_type,
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local value = dialog:getInputText()
                    if opts.input_type == "number" then
                        value = tonumber(value) or DEFAULTS[opts.key]
                    end
                    self:set(opts.key, value)
                    UIManager:close(dialog)
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Multi-line editor (used for the system prompt).
function Settings:editMultiline(touchmenu_instance, opts)
    local dialog
    dialog = InputDialog:new{
        title = opts.title,
        input = tostring(self:get(opts.key) or ""),
        allow_newline = true,
        para_direction_rtl = false,
        fullscreen = true,
        condensed = true,
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Reset to default"),
                callback = function()
                    self:set(opts.key, DEFAULTS[opts.key])
                    UIManager:close(dialog)
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
            },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    self:set(opts.key, dialog:getInputText())
                    UIManager:close(dialog)
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Show the current book/series memory with an option to clear it.
function Settings:showMemory(ui)
    local viewer
    viewer = TextViewer:new{
        title = _("BookBuddy memory"),
        text = Memory.summaryText(ui),
        add_default_buttons = false,
        buttons_table = {{
            {
                text = _("Clear memory"),
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text = _("Delete all stored memory for the current book or series?"),
                        ok_text = _("Delete"),
                        ok_callback = function()
                            Memory.clear(ui)
                            UIManager:close(viewer)
                            UIManager:show(InfoMessage:new{
                                text = _("BookBuddy memory cleared."),
                                timeout = 2,
                            })
                        end,
                    })
                end,
            },
            {
                text = _("Close"),
                callback = function() UIManager:close(viewer) end,
            },
        }},
    }
    UIManager:show(viewer)
end

function Settings:getMenu(ui)
    local items = {
            {
                text_func = function()
                    return T(_("Portkey API key: %1"),
                        self:isConfigured() and _("set") or _("not set"))
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:editText(touchmenu_instance, {
                        key = "portkey_api_key",
                        title = _("Portkey API key"),
                        description = _("Sent as the x-portkey-api-key header."),
                        input_type = "password",
                    })
                end,
            },
            {
                text_func = function()
                    return T(_("Base URL: %1"), self:get("base_url"))
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:editText(touchmenu_instance, {
                        key = "base_url",
                        title = _("Gateway base URL"),
                        description = _("The Messages endpoint is <base URL>/v1/messages."),
                    })
                end,
            },
            {
                text_func = function()
                    return T(_("Model: %1"), self:get("model"))
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:editText(touchmenu_instance, {
                        key = "model",
                        title = _("Model"),
                        description = _("Portkey model slug, e.g. @vertex-eu-global/anthropic.claude-opus-4-8."),
                    })
                end,
            },
            {
                text_func = function()
                    return T(_("Max tokens: %1"), tostring(self:get("max_tokens")))
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:editText(touchmenu_instance, {
                        key = "max_tokens",
                        title = _("Max tokens per reply"),
                        input_type = "number",
                    })
                end,
            },
            {
                text_func = function()
                    return T(_("Max tool rounds: %1"), tostring(self:get("max_turns")))
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:editText(touchmenu_instance, {
                        key = "max_turns",
                        title = _("Max tool rounds"),
                        description = _("How many tool-using exchanges before BookBuddy must give a final answer."),
                        input_type = "number",
                    })
                end,
            },
            {
                text = _("System prompt"),
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:editMultiline(touchmenu_instance, {
                        key = "system_prompt",
                        title = _("System prompt"),
                    })
                end,
            },
            {
                text = _("Per-book memory"),
                help_text = _("Let BookBuddy keep notes about this book across conversations, stored in the book's sidecar so they travel with the book."),
                checked_func = function() return self:get("enable_memory") and true or false end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:set("enable_memory", not (self:get("enable_memory") and true or false))
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
            },
            {
                text = _("Extended thinking"),
                help_text = _("Let the model reason before answering. A \"Thinking...\" indicator appears while it reasons. Requires a model that supports adaptive thinking, such as Claude Opus 4.8."),
                checked_func = function() return self:get("enable_thinking") and true or false end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:set("enable_thinking", not (self:get("enable_thinking") and true or false))
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
            },
        }
        if ui then
            items[#items + 1] = {
                text = _("Show book memory"),
                keep_menu_open = true,
                callback = function() self:showMemory(ui) end,
            }
        end
        items[#items + 1] = {
            text_func = function()
                return T(_("Check for updates (v%1)"), Updater.getInstalledVersion())
            end,
            keep_menu_open = true,
            callback = function() Updater.check() end,
        }
        return {
            text = _("BookBuddy"),
            sorting_hint = "tools",
            sub_item_table = items,
        }
end

return Settings
