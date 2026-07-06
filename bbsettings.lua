local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local MultiInputDialog = require("ui/widget/multiinputdialog")
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
    -- Spoiler confirmation: when the model wants a tool to look past the reader's
    -- current position (grep/read with spoiler=true, delegate with
    -- allow_spoiler=true), pause and ask the reader to approve first -- once, or
    -- for the rest of the conversation. On by default: spoiler safety is the
    -- product's core promise, and without this gate the main agent can pass
    -- spoiler=true on its own judgement with only the prompt discouraging it
    -- (subagents are hard-clamped; the parent was not). Off restores that
    -- prompt-trust behaviour.
    confirm_spoilers = true,
    -- Optional user text appended to BookBuddy's built-in system prompt
    -- (Prompts.SYSTEM_PROMPT). Empty by default; the base prompt is no longer
    -- user-editable, so customizations don't have to restate the internals.
    additional_system_prompt = "",
}

-- The reader's own prompt templates ("custom presets") are stored under the
-- custom_presets key as a list of { label = ..., prompt = ... } tables. They are
-- not in DEFAULTS (an absent key reads as an empty list) and are normalized on
-- every read (getCustomPresets), so a hand-edited settings file with junk entries
-- degrades to missing buttons rather than a crashed chat dialog.

-- Bump SETTINGS_VERSION and add a MIGRATIONS[v] entry whenever a *default*
-- changes in a way that should reach readers who never deliberately customized
-- that key. Each migration runs once, in order; keep it self-contained (do not
-- reference the current DEFAULTS, which drift out from under old versions) and
-- guarded so it only touches a value still equal to the specific old default --
-- a deliberate pick is left alone. Together with set()/reset() below, this is
-- how a shipped default actually reaches existing installs.
local SETTINGS_VERSION = 2

-- migrations[v] transforms a store from version v-1 to v.
local MIGRATIONS = {
    -- v2: the default model moved to anthropic/claude-opus-4.8. Un-pin readers
    -- still carrying the previous default so they float up to the new one;
    -- anyone who chose a different model keeps it.
    [2] = function(store)
        if store:readSetting("model") == "anthropic/claude-opus-4.7" then
            store:delSetting("model")
        end
    end,
}

-- Preference keys eligible for "Reset settings to defaults". Connection config
-- (api_key, base_url) is excluded on purpose: it's onboarding state, not a
-- preference, and clearing it would lock the reader out of their endpoint. The
-- reader's own custom_presets are user-authored content, not a default, so a
-- blanket reset leaves them alone too; settings_version is bookkeeping.
local RESETTABLE = {
    "model",
    "max_tokens",
    "max_turns",
    "enable_memory",
    "enable_thinking",
    "show_streaming_thinking",
    "enable_web_search",
    "enable_subagents",
    "subagent_max_turns",
    "enable_clarifying_questions",
    "confirm_spoilers",
    "additional_system_prompt",
    "max_saved_chats",
}

-- Longest derived button label. The chat dialogs lay preset buttons out two per
-- row, so anything much longer than this gets ellipsized by the button widget
-- anyway; explicit labels are the reader's own and are not capped.
local PRESET_LABEL_MAX_CHARS = 24

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Button label derived from a prompt when the reader left the label blank: the
-- prompt's first line, whitespace-collapsed, cut back to the last completed word
-- within PRESET_LABEL_MAX_CHARS. The back-off lands on a space (ASCII), so it can
-- never split a multibyte character; only a single first word longer than the cap
-- falls through to a hard byte cut (display-only, mirrors bbtools' truncate()).
local function deriveLabel(prompt)
    local line = prompt:match("[^\r\n]*") or ""
    line = trim(line:gsub("%s+", " "))
    if #line <= PRESET_LABEL_MAX_CHARS then
        return line
    end
    local head = line:sub(1, PRESET_LABEL_MAX_CHARS)
    if line:sub(PRESET_LABEL_MAX_CHARS + 1):match("^%S") then
        head = head:match("^(.-)%s+%S*$") or head
    end
    return trim(head)
end

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
    o:migrate()
    return o
end

-- Run any pending MIGRATIONS once, then stamp the file at SETTINGS_VERSION. A
-- pre-versioning install has no stored version and reads as 1 (the baseline
-- before this scheme existed); a brand-new install also lands there, but the
-- guards inside each migration make it a no-op since nothing is stored yet.
function Settings:migrate()
    local from = self.store:readSetting("settings_version", 1)
    if from >= SETTINGS_VERSION then
        return
    end
    for v = from + 1, SETTINGS_VERSION do
        local step = MIGRATIONS[v]
        if step then
            step(self.store)
        end
    end
    self.store:saveSetting("settings_version", SETTINGS_VERSION)
    self.store:flush()
end

function Settings:get(key)
    return self.store:readSetting(key, DEFAULTS[key])
end

-- Persist only genuine deviations: a value equal to the current default is
-- stored as *absence* (delSetting), so a later DEFAULTS bump reaches everyone
-- who never deviated -- get() falls back through the live default. Keys absent
-- from DEFAULTS (api_key, custom_presets) have a nil default, so a real value
-- never compares equal and always persists.
function Settings:set(key, value)
    if value == DEFAULTS[key] then
        self.store:delSetting(key)
    else
        self.store:saveSetting(key, value)
    end
    self.store:flush()
end

-- Forget a single key so get() falls back to the live default. The one-key
-- primitive under both the per-field "Reset to default" buttons and the bulk
-- resetToDefaults() below.
function Settings:reset(key)
    self.store:delSetting(key)
    self.store:flush()
end

-- Clear every resettable preference in one flush, restoring defaults for all of
-- them. Connection config and custom_presets are preserved (see RESETTABLE).
function Settings:resetToDefaults()
    for _, key in ipairs(RESETTABLE) do
        self.store:delSetting(key)
    end
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
        -- Default ON, same nil-coalescing shape as enable_clarifying_questions above.
        confirm_spoilers = self:get("confirm_spoilers") ~= false,
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

-- Validated, display-ready form of the stored custom_presets list, in stored
-- order: each entry with a usable prompt keeps it trimmed, and a blank/missing
-- label is derived from the prompt. Malformed entries (non-tables, no prompt
-- text) are skipped. Both the chat dialogs (via Presets.withCustom) and the
-- template editor below consume THIS list, so their 1-based indices agree.
function Settings:getCustomPresets()
    local raw = self:get("custom_presets")
    local out = {}
    if type(raw) ~= "table" then
        return out
    end
    for _, entry in ipairs(raw) do
        if type(entry) == "table" and type(entry.prompt) == "string" then
            local prompt = trim(entry.prompt)
            if prompt ~= "" then
                local label = type(entry.label) == "string" and trim(entry.label) or ""
                if label == "" then
                    label = deriveLabel(prompt)
                end
                out[#out + 1] = { label = label, prompt = prompt }
            end
        end
    end
    return out
end

-- Add/edit dialog for one custom prompt template. index nil creates a new
-- template; otherwise the index-th entry of the normalized list is edited (or
-- deleted). Every write stores the whole normalized list back, so junk entries
-- in a hand-edited file are flushed on the first save, and the indices the menu
-- rows captured stay valid. The label field may be left blank -- getCustomPresets
-- derives one from the prompt on the next read.
function Settings:editCustomPreset(touchmenu_instance, index)
    local presets = self:getCustomPresets()
    local existing = index and presets[index] or nil
    local dialog
    local function saveList()
        self:set("custom_presets", presets)
        UIManager:close(dialog)
        -- Rebuild the submenu rows in place: updateItems() re-renders from
        -- item_table, so reassigning it is how a row list changes size (a plain
        -- updateItems() would repaint the stale rows).
        if touchmenu_instance then
            touchmenu_instance.item_table = self:customPresetMenuItems()
            touchmenu_instance:updateItems()
        end
    end
    local rows = {}
    if existing then
        rows[#rows + 1] = {
            {
                text = _("Delete"),
                callback = function()
                    UIManager:show(ConfirmBox:new({
                        text = T(_('Delete the prompt template "%1"?'), existing.label),
                        ok_text = _("Delete"),
                        ok_callback = function()
                            table.remove(presets, index)
                            saveList()
                        end,
                    }))
                end,
            },
        }
    end
    rows[#rows + 1] = {
        {
            text = _("Cancel"),
            id = "close",
            callback = function()
                UIManager:close(dialog)
            end,
        },
        {
            text = _("Save"),
            callback = function()
                local fields = dialog:getFields()
                local label, prompt = fields[1] or "", fields[2] or ""
                if prompt:gsub("%s", "") == "" then
                    UIManager:show(InfoMessage:new({ text = _("Enter the prompt text first."), timeout = 2 }))
                    return -- keep the dialog open so the reader can fill it in
                end
                local entry = { label = label, prompt = prompt }
                if index then
                    presets[index] = entry
                else
                    presets[#presets + 1] = entry
                end
                saveList()
            end,
        },
    }
    dialog = MultiInputDialog:new({
        title = existing and _("Edit prompt template") or _("Add prompt template"),
        fields = {
            { text = existing and existing.label or "", hint = _("Button label (optional)") },
            { text = existing and existing.prompt or "", hint = _("Prompt text") },
        },
        buttons = rows,
    })
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Rows for the "Prompt templates" submenu: a leading "Add" row, then one row per
-- stored template (tap to edit or delete; hold shows the full prompt as help
-- text). Rebuilt fresh by sub_item_table_func each time the submenu opens, and
-- reassigned into the live touchmenu after every save/delete (see saveList).
function Settings:customPresetMenuItems()
    local items = {
        {
            text = _("Add a prompt template"),
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:editCustomPreset(touchmenu_instance, nil)
            end,
        },
    }
    for i, preset in ipairs(self:getCustomPresets()) do
        items[#items + 1] = {
            text = preset.label,
            help_text = preset.prompt,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:editCustomPreset(touchmenu_instance, i)
            end,
        }
    end
    return items
end

-- Generic single-line string/number editor.
function Settings:editText(touchmenu_instance, opts)
    local dialog
    local row = {
        {
            text = _("Cancel"),
            id = "close",
            callback = function()
                UIManager:close(dialog)
            end,
        },
    }
    -- Offer a reset only for keys that have a default to fall back to. api_key
    -- has none (DEFAULTS[api_key] is nil), and "reset" there would just blank
    -- the credential -- not a default, so no button.
    if DEFAULTS[opts.key] ~= nil then
        row[#row + 1] = {
            text = _("Reset to default"),
            callback = function()
                self:reset(opts.key)
                UIManager:close(dialog)
                if touchmenu_instance then
                    touchmenu_instance:updateItems()
                end
            end,
        }
    end
    row[#row + 1] = {
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
    }
    dialog = InputDialog:new({
        title = opts.title,
        description = opts.description,
        input = tostring(self:get(opts.key) or ""),
        input_type = opts.input_type,
        buttons = { row },
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
                    -- reset() (delSetting), not set(default): both land on the
                    -- default now, but forgetting the key keeps floating with a
                    -- future DEFAULTS bump instead of pinning today's value.
                    callback = function()
                        self:reset(opts.key)
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
    -- Set-once connection config: touched at onboarding, then never again, so it
    -- lives in a submenu instead of hogging page 1's best seats.
    local connection = {
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
    }
    -- Occasional behavior toggles. Extended thinking and Confirm spoilers are
    -- promoted to the top level (below) as the two most people flip; the rest,
    -- plus the numeric fields gated on them, stay grouped here.
    local behavior = {
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
    -- Prompt-shaping controls, grouped: your quick-prompt buttons and the extra
    -- system-prompt text.
    local prompts = {
        {
            text = _("Prompt templates"),
            help_text = _(
                "Your own quick-prompt buttons, shown alongside the built-in ones in every chat dialog. Tapping one prefills the input box with its prompt so you can tweak the wording before sending. Tap a template here to edit or delete it; long-press it to preview the full prompt."
            ),
            sub_item_table_func = function()
                return self:customPresetMenuItems()
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
    }
    -- Top level, following the "Chat about this book" / "Chat history" actions
    -- that addToMainMenu prepends. Check for updates rides up here on purpose:
    -- during active development it's checked far more than any setting, so it sits
    -- framed on its own between separators rather than buried in a maintenance tail.
    local items = {
        {
            text_func = function()
                return T(_("Check for updates (v%1)"), Updater.getInstalledVersion())
            end,
            keep_menu_open = true,
            separator = true,
            callback = function()
                Updater.check()
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
            text = _("Confirm spoilers"),
            help_text = _(
                "Ask you before BookBuddy searches or reads past your current page, or sends a helper ahead with spoilers allowed. You can allow it once or for the rest of the conversation. On by default; turn it off to let BookBuddy decide on its own judgement when you ask about things ahead."
            ),
            -- Default on: a never-set value is nil, which must read as checked, so test ~= false.
            checked_func = function()
                return self:get("confirm_spoilers") ~= false
            end,
            keep_menu_open = true,
            separator = true,
            callback = function(touchmenu_instance)
                self:set("confirm_spoilers", self:get("confirm_spoilers") == false)
                if touchmenu_instance then
                    touchmenu_instance:updateItems()
                end
            end,
        },
        {
            text = _("Connection"),
            help_text = _("Endpoint and model: API key, base URL, model slug, token and tool-round limits."),
            sub_item_table = connection,
        },
        {
            text = _("Behavior"),
            help_text = _(
                "How BookBuddy works: per-book memory, streaming reasoning, web search, subagent delegation, and clarifying questions."
            ),
            sub_item_table = behavior,
        },
        {
            text = _("Prompts"),
            help_text = _("Prompt templates and extra system-prompt text."),
            sub_item_table = prompts,
            separator = true,
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
    items[#items + 1] = {
        text = _("Reset settings to defaults"),
        help_text = _(
            "Restore behavior, prompt, and limit settings to their defaults. Your API key, base URL, and saved prompt templates are kept."
        ),
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            UIManager:show(ConfirmBox:new({
                text = _(
                    "Reset BookBuddy settings to their defaults? Your API key, base URL, and prompt templates are kept."
                ),
                ok_text = _("Reset"),
                ok_callback = function()
                    self:resetToDefaults()
                    if touchmenu_instance then
                        touchmenu_instance:updateItems()
                    end
                end,
            }))
        end,
    }
    return {
        text = _("BookBuddy"),
        sorting_hint = "tools",
        sub_item_table = items,
    }
end

return Settings
