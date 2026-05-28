local DataStorage = require("datastorage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local DEFAULTS = {
    base_url = "https://api.portkey.ai",
    model = "@vertex-ai/anthropic.claude-sonnet-4-6",
    max_tokens = 64000,
    max_turns = 20,
    system_prompt = "You are BookBuddy, a concise and insightful reading companion embedded in an e-reader. "
        .. "The user is reading a book and has highlighted a passage to ask you about. "
        .. "You have tools to search the book, read page ranges and chapters, inspect the table of contents, "
        .. "and fetch the book's metadata and the reader's current position. "
        .. "Use these tools to ground your answers in the actual text instead of guessing. "
        .. "Quote sparingly, avoid spoilers beyond the reader's current position unless explicitly asked, "
        .. "and keep answers focused and readable on a small e-ink screen.",
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

function Settings:getMenu()
    return {
        text = _("BookBuddy"),
        sub_item_table = {
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
                        description = _("Portkey model slug, e.g. @vertex-ai/anthropic.claude-sonnet-4-6."),
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
        },
    }
end

return Settings
