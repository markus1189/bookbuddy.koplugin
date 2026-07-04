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
    -- Per-book memory is a self-rolled custom tool (a filesystem-backed /memories
    -- store in bbmemory), not Anthropic's server-side memory_20250818, so it works
    -- on any tool-using endpoint — gateways included — rather than only a native
    -- Anthropic backend. Off by default: it's opt-in and spends a little extra each
    -- conversation recalling and updating notes.
    enable_memory = false,
    -- Adaptive extended thinking; Opus 4.8 supports the adaptive mode only. On by
    -- default (the setting). The model's thinking text is itself omitted unless we ask
    -- for the summarized display, which is what makes the reasoning visible (see
    -- bbanthropic) -- adaptive thinking still only actually reasons when warranted.
    enable_thinking = true,
    -- Surface the model's live summarized thinking text in the transcript while it
    -- streams, instead of only a "Thinking..." indicator. Off by default: the
    -- reasoning can name plot points the reader hasn't reached yet, so it's a
    -- spoiler risk. Has no effect unless enable_thinking is also on.
    show_streaming_thinking = false,
    -- Server-side web search (web_search_20250305) only runs on first-party
    -- Anthropic backends; gateways routed to Vertex/Bedrock silently ignore it
    -- (and Claude Code likewise hides WebSearch there). On by default; turn it
    -- off when your endpoint can't execute it, so we don't advertise a dead tool.
    enable_web_search = true,
    -- Subagent delegation: a `delegate` tool that hands wide, multi-round research to
    -- a read-only child agent whose intermediate grep/read churn stays out of the
    -- main conversation's resent history. Off by default (opt-in, like
    -- show_streaming_thinking): it double-bills the sub-task and adds latency, so it
    -- only pays off on genuinely wide exploration. When off, the tool is not advertised.
    enable_subagents = false,
    -- How many tool rounds a delegated child may take before it must answer in text.
    -- Bounded (well under SUBAGENT_MAX_TURNS_CEILING) so one delegation can't grind
    -- unbounded double-billed rounds, but generous enough for genuinely wide research.
    subagent_max_turns = 12,
    -- Clarifying questions: an `ask_user` tool that lets BookBuddy pause mid-turn to ask
    -- the reader one disambiguating question (button choices and/or free text) and resume
    -- the same turn with their answer. On by default (unlike subagents): it spends no
    -- extra tokens and opens no new spoiler surface, and an agent that can ask beats one
    -- that guesses. When off, the tool is not advertised.
    enable_clarifying_questions = true,
    -- Cap on stored chats per book (bbchats): saving past the cap prunes the
    -- oldest by last-updated time. Chats live in the book's .sdr sidecar and sync
    -- with the book, so the cap also bounds what rides along via Syncthing.
    max_saved_chats = 20,
    -- Optional user text appended to BookBuddy's built-in system prompt
    -- (Prompts.SYSTEM_PROMPT). Empty by default; the base prompt is no longer
    -- user-editable, so customizations don't have to restate the internals.
    additional_system_prompt = "",
}

-- Upper bound on subagent_max_turns at resolve time. The setting is a free number
-- field (see the menu), so a mistyped large value would otherwise let one delegation
-- grind dozens of double-billed tool rounds; cap it the way max_tokens/max_turns are
-- floored. Generous enough that no realistic research task hits it.
local SUBAGENT_MAX_TURNS_CEILING = 20

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
        -- Clamp to >= 1 like max_turns below: 0 is truthy in Lua, so a user-entered 0
        -- or negative would otherwise pass straight into the request body and the
        -- gateway 400s on a non-positive max_tokens.
        max_tokens = math.max(1, tonumber(self:get("max_tokens")) or DEFAULTS.max_tokens),
        max_turns = math.max(1, tonumber(self:get("max_turns")) or DEFAULTS.max_turns),
        additional_system_prompt = self:get("additional_system_prompt"),
        enable_memory = self:get("enable_memory") and true or false,
        enable_thinking = self:get("enable_thinking") and true or false,
        show_streaming_thinking = self:get("show_streaming_thinking") and true or false,
        enable_web_search = self:get("enable_web_search") and true or false,
        enable_subagents = self:get("enable_subagents") and true or false,
        -- Default ON: a nil (never-set) value must resolve true, so coalesce nil to the
        -- default rather than the usual `and true or false` (which would force nil->false).
        enable_clarifying_questions = self:get("enable_clarifying_questions") ~= false,
        subagent_max_turns = math.max(
            1,
            math.min(
                SUBAGENT_MAX_TURNS_CEILING,
                tonumber(self:get("subagent_max_turns")) or DEFAULTS.subagent_max_turns
            )
        ),
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
                    description = _("Sent as both an Authorization: Bearer token and an x-api-key header."),
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
        {
            text = _("Show streaming thinking"),
            help_text = _(
                "Show the model's reasoning text live as it streams, instead of just a \"Thinking...\" indicator. Off by default: the reasoning may mention plot points you haven't read yet, so it can spoil the book. Requires Extended thinking to be on."
            ),
            enabled_func = function()
                return self:get("enable_thinking") and true or false
            end,
            checked_func = function()
                return self:get("show_streaming_thinking") and true or false
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:set("show_streaming_thinking", not (self:get("show_streaming_thinking") and true or false))
                if touchmenu_instance then
                    touchmenu_instance:updateItems()
                end
            end,
        },
        {
            text = _("Web search"),
            help_text = _(
                "Let BookBuddy search the web for outside facts. Uses Anthropic's server-side web search, which only runs on a native Anthropic endpoint (or a gateway that routes to one, like OpenRouter's Anthropic models). Endpoints routed through Vertex or Bedrock silently ignore it, so turn it off there."
            ),
            checked_func = function()
                return self:get("enable_web_search") and true or false
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:set("enable_web_search", not (self:get("enable_web_search") and true or false))
                if touchmenu_instance then
                    touchmenu_instance:updateItems()
                end
            end,
        },
        {
            text = _("Subagent delegation"),
            help_text = _(
                "Let BookBuddy hand wide, multi-step research (tracing a motif or a minor character across the whole book) to a read-only helper agent, so all that searching stays out of your conversation and only a condensed summary comes back. Off by default: it costs extra tokens and adds a pause while the helper works. The helper is spoiler-safe and reads only up to your current page."
            ),
            checked_func = function()
                return self:get("enable_subagents") and true or false
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:set("enable_subagents", not (self:get("enable_subagents") and true or false))
                if touchmenu_instance then
                    touchmenu_instance:updateItems()
                end
            end,
        },
        {
            text_func = function()
                return T(_("Helper tool rounds: %1"), tostring(self:get("subagent_max_turns")))
            end,
            enabled_func = function()
                return self:get("enable_subagents") and true or false
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:editText(touchmenu_instance, {
                    key = "subagent_max_turns",
                    title = _("Helper tool rounds"),
                    description = _("How many tool-using rounds a delegated helper may take before it must answer."),
                    input_type = "number",
                })
            end,
        },
        {
            text = _("Clarifying questions"),
            help_text = _(
                "Let BookBuddy pause to ask you a short question when it is unclear what you meant -- which character you mean, how far back to look -- and continue once you pick an option or type a reply. On by default: it costs no extra tokens and never reveals anything past your current page. Turn it off if you would rather it always answer without asking."
            ),
            -- Default on: a never-set value is nil, which must read as checked, so test ~= false.
            checked_func = function()
                return self:get("enable_clarifying_questions") ~= false
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:set("enable_clarifying_questions", self:get("enable_clarifying_questions") == false)
                if touchmenu_instance then
                    touchmenu_instance:updateItems()
                end
            end,
        },
    }
    items[#items + 1] = {
        text_func = function()
            return T(_("Saved chats per book: %1"), tostring(self:get("max_saved_chats")))
        end,
        help_text = _(
            "How many finished chats to keep per book. Chats are saved in the book's sidecar so they survive restarts and travel with the book; saving past the cap deletes the oldest."
        ),
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            self:editText(touchmenu_instance, {
                key = "max_saved_chats",
                title = _("Saved chats per book"),
                description = _("Oldest chats are deleted when a new one is saved past this limit."),
                input_type = "number",
            })
        end,
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
