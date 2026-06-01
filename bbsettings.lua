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
    base_url = "https://openrouter.ai/api",
    model = "anthropic/claude-opus-4.8",
    max_tokens = 64000,
    max_turns = 20,
    -- Off by default: per-book memory rides on Anthropic's server-side memory
    -- tool (memory_20250818), which the common gateways reject (OpenRouter:
    -- "Unknown server-tool shorthand"; Requesty/Vertex: treats it as a custom
    -- tool and 400s). Opt in only when pointing at a native Anthropic endpoint.
    enable_memory = false,
    -- Adaptive extended thinking. Opus 4.8 supports adaptive thinking only, off
    -- unless requested; its thinking text is omitted unless we ask for the
    -- summarized display, which is what makes reasoning visible (see bbanthropic).
    enable_thinking = true,
    -- Optional user text appended to BookBuddy's built-in system prompt
    -- (Prompts.SYSTEM_PROMPT). Empty by default; the base prompt is no longer
    -- user-editable, so customizations don't have to restate the internals.
    additional_system_prompt = "",
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
        api_key = self:get("api_key"),
        model = self:get("model"),
        max_tokens = tonumber(self:get("max_tokens")) or DEFAULTS.max_tokens,
        max_turns = math.max(1, tonumber(self:get("max_turns")) or DEFAULTS.max_turns),
        additional_system_prompt = self:get("additional_system_prompt"),
        enable_memory = self:get("enable_memory") and true or false,
        enable_thinking = self:get("enable_thinking") and true or false,
    }
end

function Settings:isConfigured()
    local key = self:get("api_key")
    return key ~= nil and key ~= ""
end

-- Generic single-line string/number editor.
function Settings:editText(touchmenu_instance, opts)
    local dialog
    dialog = InputDialog:new({
        title = opts.title,
        description = opts.description,
        input = tostring(self:get(opts.key) or ""),
        input_type = opts.input_type,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
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
                        if touchmenu_instance then
                            touchmenu_instance:updateItems()
                        end
                    end,
                },
            },
        },
    })
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Multi-line editor (used for the system prompt).
function Settings:editMultiline(touchmenu_instance, opts)
    local dialog
    dialog = InputDialog:new({
        title = opts.title,
        description = opts.description,
        input = tostring(self:get(opts.key) or ""),
        allow_newline = true,
        para_direction_rtl = false,
        fullscreen = true,
        condensed = true,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Reset to default"),
                    callback = function()
                        self:set(opts.key, DEFAULTS[opts.key])
                        UIManager:close(dialog)
                        if touchmenu_instance then
                            touchmenu_instance:updateItems()
                        end
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        self:set(opts.key, dialog:getInputText())
                        UIManager:close(dialog)
                        if touchmenu_instance then
                            touchmenu_instance:updateItems()
                        end
                    end,
                },
            },
        },
    })
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Show the current book/series memory with an option to clear it.
function Settings:showMemory(ui)
    local viewer
    viewer = TextViewer:new({
        title = _("BookBuddy memory"),
        text = Memory.summaryText(ui),
        add_default_buttons = false,
        buttons_table = {
            {
                {
                    text = _("Clear memory"),
                    callback = function()
                        UIManager:show(ConfirmBox:new({
                            text = _("Delete all stored memory for the current book or series?"),
                            ok_text = _("Delete"),
                            ok_callback = function()
                                Memory.clear(ui)
                                UIManager:close(viewer)
                                UIManager:show(InfoMessage:new({
                                    text = _("BookBuddy memory cleared."),
                                    timeout = 2,
                                }))
                            end,
                        }))
                    end,
                },
                {
                    text = _("Close"),
                    callback = function()
                        UIManager:close(viewer)
                    end,
                },
            },
        },
    })
    UIManager:show(viewer)
end

function Settings:getMenu(ui)
    local items = {
        {
            text_func = function()
                return T(_("Claude API key: %1"), self:isConfigured() and _("set") or _("not set"))
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:editText(touchmenu_instance, {
                    key = "api_key",
                    title = _("Claude API key"),
                    description = _("Sent as an Authorization: Bearer token."),
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
                    description = _("Model slug for the endpoint, e.g. anthropic/claude-opus-4.8."),
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
            text = _("Additional system prompt"),
            help_text = _(
                "Optional text appended to BookBuddy's built-in system prompt. Use it to add your own preferences (tone, language, focus) without restating the built-in instructions. Leave empty for the default behavior."
            ),
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:editMultiline(touchmenu_instance, {
                    key = "additional_system_prompt",
                    title = _("Additional system prompt"),
                    description = _(
                        "Appended to BookBuddy's built-in system prompt. Leave empty for the default behavior."
                    ),
                })
            end,
        },
        {
            text = _("Per-book memory"),
            help_text = _(
                "Let BookBuddy keep notes about this book across conversations, stored in the book's sidecar so they travel with the book."
            ),
            checked_func = function()
                return self:get("enable_memory") and true or false
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:set("enable_memory", not (self:get("enable_memory") and true or false))
                if touchmenu_instance then
                    touchmenu_instance:updateItems()
                end
            end,
        },
        {
            text = _("Extended thinking"),
            help_text = _(
                'Let the model reason before answering. A "Thinking..." indicator appears while it reasons. Requires a model that supports adaptive thinking, such as Claude Opus 4.8.'
            ),
            checked_func = function()
                return self:get("enable_thinking") and true or false
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:set("enable_thinking", not (self:get("enable_thinking") and true or false))
                if touchmenu_instance then
                    touchmenu_instance:updateItems()
                end
            end,
        },
    }
    if ui then
        items[#items + 1] = {
            text = _("Show book memory"),
            keep_menu_open = true,
            callback = function()
                self:showMemory(ui)
            end,
        }
    end
    items[#items + 1] = {
        text_func = function()
            return T(_("Check for updates (v%1)"), Updater.getInstalledVersion())
        end,
        keep_menu_open = true,
        callback = function()
            Updater.check()
        end,
    }
    return {
        text = _("BookBuddy"),
        sorting_hint = "tools",
        sub_item_table = items,
    }
end

return Settings
