-- bbsettings config getters against an in-memory LuaSettings + DataStorage. The
-- focus is the serializable getConfig() the HTTP layer consumes: DEFAULTS
-- fallback, the max_turns clamp, and isConfigured.
local stubs = require("support.stubs")

describe("bbsettings", function()
    local Settings
    local dialogs

    setup(function()
        stubs.install()
        stubs.install_bbmemory_stub()
        package.loaded["bbupdate"] = {} -- required at load; unused by the getters
        package.loaded["datastorage"] = {
            getSettingsDir = function()
                return "/tmp/bookbuddy-test"
            end,
        }
        -- In-memory LuaSettings: open() hands back a store backed by a plain table.
        package.loaded["luasettings"] = {
            open = function(_, _file)
                local store = { _data = {} }
                function store:readSetting(key, default)
                    local v = self._data[key]
                    if v == nil then
                        return default
                    end
                    return v
                end
                function store:saveSetting(key, value)
                    self._data[key] = value
                end
                function store:delSetting(key)
                    self._data[key] = nil
                end
                function store:flush() end
                return store
            end,
        }
        package.loaded["ui/widget/confirmbox"] = {
            new = function(_, o)
                return o or {}
            end,
        }
        package.loaded["ui/widget/multiinputdialog"] = {
            new = function(_, o)
                return o or {}
            end,
        }
        package.loaded["ui/widget/textviewer"] = {
            new = function(_, o)
                return o or {}
            end,
        }
        -- InputDialog double recording each dialog and answering the two methods
        -- editText drives (getInputText at Save, onShowKeyboard after show), so the
        -- numeric save-time clamp can be exercised end to end. Set dlg._typed to
        -- simulate the user replacing the prefilled text.
        dialogs = {}
        package.loaded["ui/widget/inputdialog"] = {
            new = function(_, o)
                o = o or {}
                o.getInputText = function(dlg)
                    return dlg._typed or dlg.input
                end
                o.onShowKeyboard = stubs.noop
                dialogs[#dialogs + 1] = o
                return o
            end,
        }
        Settings = require("bbsettings")
    end)

    local function fresh()
        return Settings:new("bookbuddy")
    end

    describe("getConfig DEFAULTS fallback", function()
        it("falls back to defaults when nothing is stored", function()
            local c = fresh():getConfig()
            assert.are.equal("anthropic/claude-opus-4.8", c.model)
            assert.are.equal(64000, c.max_tokens)
            assert.are.equal(20, c.max_turns)
            assert.are.equal("https://openrouter.ai/api", c.base_url)
            assert.is_false(c.enable_memory)
            assert.is_true(c.enable_thinking)
            assert.is_false(c.show_streaming_thinking)
            assert.is_true(c.enable_web_search)
            assert.is_false(c.enable_subagents)
            assert.are.equal(12, c.subagent_max_turns)
            assert.are.equal("", c.additional_system_prompt)
            assert.is_true(c.confirm_spoilers)
        end)

        it("resolves confirm_spoilers default-on: only an explicit false disables it", function()
            local s = fresh()
            assert.is_true(s:getConfig().confirm_spoilers) -- never set (nil) reads as on
            s:set("confirm_spoilers", false)
            assert.is_false(s:getConfig().confirm_spoilers)
            s:set("confirm_spoilers", true)
            assert.is_true(s:getConfig().confirm_spoilers)
        end)

        it("falls back to the default max_tokens for a non-numeric stored value", function()
            local s = fresh()
            s:set("max_tokens", "not a number")
            assert.are.equal(64000, s:getConfig().max_tokens)
        end)
    end)

    describe("max_turns clamp", function()
        it("clamps a stored value below 1 up to 1", function()
            local s = fresh()
            s:set("max_turns", 0)
            assert.are.equal(1, s:getConfig().max_turns)
            s:set("max_turns", -5)
            assert.are.equal(1, s:getConfig().max_turns)
        end)

        it("falls back to the default when the stored value is non-numeric", function()
            local s = fresh()
            s:set("max_turns", "abc")
            assert.are.equal(20, s:getConfig().max_turns)
        end)

        it("passes a sane stored value through unchanged", function()
            local s = fresh()
            s:set("max_turns", 7)
            assert.are.equal(7, s:getConfig().max_turns)
        end)
    end)

    describe("subagent_max_turns clamp", function()
        it("clamps a stored value below 1 up to 1", function()
            local s = fresh()
            s:set("subagent_max_turns", 0)
            assert.are.equal(1, s:getConfig().subagent_max_turns)
            s:set("subagent_max_turns", -3)
            assert.are.equal(1, s:getConfig().subagent_max_turns)
        end)

        it("clamps a mistyped large value down to the ceiling", function()
            local s = fresh()
            s:set("subagent_max_turns", 999)
            assert.are.equal(50, s:getConfig().subagent_max_turns)
        end)

        it("falls back to the default when the stored value is non-numeric", function()
            local s = fresh()
            s:set("subagent_max_turns", "abc")
            assert.are.equal(12, s:getConfig().subagent_max_turns)
        end)

        it("passes a sane stored value through unchanged", function()
            local s = fresh()
            s:set("subagent_max_turns", 10)
            assert.are.equal(10, s:getConfig().subagent_max_turns)
        end)

        it("effectiveSubagentMaxTurns (the menu label) agrees with getConfig for an over-ceiling store", function()
            local s = fresh()
            s:set("subagent_max_turns", 999)
            assert.are.equal(50, s:effectiveSubagentMaxTurns())
            assert.are.equal(s:getConfig().subagent_max_turns, s:effectiveSubagentMaxTurns())
        end)
    end)

    describe("editText numeric bounds", function()
        -- Drive the recorded dialog's Save button (the is_enter_default one) with
        -- the given typed text, as if the user edited the field and hit Save.
        local function saveTyped(dlg, typed)
            dlg._typed = typed
            for _, btn in ipairs(dlg.buttons[1]) do
                if btn.is_enter_default then
                    btn.callback()
                end
            end
        end

        it("clamps an over-max entry at save time so the stored value matches the runtime one", function()
            local s = fresh()
            s:editText(nil, { key = "subagent_max_turns", input_type = "number", min = 1, max = 50 })
            saveTyped(dialogs[#dialogs], "999")
            assert.are.equal(50, s:get("subagent_max_turns"))
            assert.are.equal(50, s:getConfig().subagent_max_turns)
        end)

        it("clamps a below-min entry up at save time", function()
            local s = fresh()
            s:editText(nil, { key = "max_turns", input_type = "number", min = 1 })
            saveTyped(dialogs[#dialogs], "0")
            assert.are.equal(1, s:get("max_turns"))
        end)

        it("prefills with the clamped value for a pre-clamp out-of-range store", function()
            local s = fresh()
            s:set("subagent_max_turns", 999)
            s:editText(nil, { key = "subagent_max_turns", input_type = "number", min = 1, max = 50 })
            assert.are.equal("50", dialogs[#dialogs].input)
        end)

        it("leaves an in-range entry untouched", function()
            local s = fresh()
            s:editText(nil, { key = "subagent_max_turns", input_type = "number", min = 1, max = 50 })
            saveTyped(dialogs[#dialogs], "15")
            assert.are.equal(15, s:get("subagent_max_turns"))
        end)
    end)

    describe("isConfigured", function()
        it("is false with no API key", function()
            assert.is_false(fresh():isConfigured())
        end)

        it("is false with an empty API key", function()
            local s = fresh()
            s:set("api_key", "")
            assert.is_false(s:isConfigured())
        end)

        it("is true once an API key is set", function()
            local s = fresh()
            s:set("api_key", "secret")
            assert.is_true(s:isConfigured())
        end)
    end)

    describe("getCustomPresets", function()
        it("returns an empty list when nothing is stored", function()
            assert.are.same({}, fresh():getCustomPresets())
        end)

        it("returns an empty list for a non-table stored value", function()
            local s = fresh()
            s:set("custom_presets", "oops")
            assert.are.same({}, s:getCustomPresets())
        end)

        it("round-trips entries in stored order, trimming label and prompt", function()
            local s = fresh()
            s:set("custom_presets", {
                { label = "  Vocab ", prompt = " List the difficult vocabulary. " },
                { label = "Recap", prompt = "Recap the chapter." },
            })
            local presets = s:getCustomPresets()
            assert.are.equal(2, #presets)
            assert.are.equal("Vocab", presets[1].label)
            assert.are.equal("List the difficult vocabulary.", presets[1].prompt)
            assert.are.equal("Recap", presets[2].label)
        end)

        it("preserves interior newlines in the prompt", function()
            local s = fresh()
            s:set("custom_presets", { { label = "Multi", prompt = "First line.\nSecond line." } })
            assert.are.equal("First line.\nSecond line.", s:getCustomPresets()[1].prompt)
        end)

        it("skips malformed entries but keeps the valid ones", function()
            local s = fresh()
            s:set("custom_presets", {
                "not a table",
                { label = "No prompt" },
                { label = "Blank prompt", prompt = "   " },
                { label = "Numeric prompt", prompt = 42 },
                { label = "Good", prompt = "A real prompt." },
            })
            local presets = s:getCustomPresets()
            assert.are.equal(1, #presets)
            assert.are.equal("Good", presets[1].label)
        end)

        it("derives a label from the prompt's first line when the label is blank or missing", function()
            local s = fresh()
            s:set("custom_presets", {
                { prompt = "Recap the chapter." },
                { label = "   ", prompt = "Short one.\nSecond line is ignored." },
            })
            local presets = s:getCustomPresets()
            assert.are.equal("Recap the chapter.", presets[1].label)
            assert.are.equal("Short one.", presets[2].label)
        end)

        it("cuts a long derived label back to the last completed word", function()
            local s = fresh()
            s:set("custom_presets", { { prompt = "Summarize this chapter in three sentences." } })
            assert.are.equal("Summarize this chapter", s:getCustomPresets()[1].label)
        end)

        it("hard-cuts a derived label whose first word alone exceeds the cap", function()
            local s = fresh()
            s:set("custom_presets", { { prompt = string.rep("x", 40) } })
            assert.are.equal(string.rep("x", 24), s:getCustomPresets()[1].label)
        end)
    end)

    it("coerces enable_memory/enable_thinking to real booleans", function()
        local s = fresh()
        s:set("enable_memory", false)
        local c = s:getConfig()
        assert.are.equal(false, c.enable_memory)
        assert.are.equal("boolean", type(c.enable_thinking))
    end)

    -- A store backed by a caller-supplied table, so tests can seed the file
    -- state a migration runs against (fresh()'s open() always starts empty).
    local function store_with(data)
        local store = { _data = data or {} }
        function store:readSetting(key, default)
            local v = self._data[key]
            if v == nil then
                return default
            end
            return v
        end
        function store:saveSetting(key, value)
            self._data[key] = value
        end
        function store:delSetting(key)
            self._data[key] = nil
        end
        function store:flush() end
        return store
    end

    describe("set stores only deviations from the current default", function()
        it("persists a value that differs from the default", function()
            local s = fresh()
            s:set("max_tokens", 1000)
            assert.are.equal(1000, s.store._data.max_tokens)
        end)

        it("forgets a value equal to the default so a future default bump reaches it", function()
            local s = fresh()
            s:set("max_tokens", 1000)
            s:set("max_tokens", 64000) -- == DEFAULTS.max_tokens
            assert.is_nil(s.store._data.max_tokens)
            assert.are.equal(64000, s:get("max_tokens"))
        end)

        it("still persists keys that have no default (api_key, custom_presets)", function()
            local s = fresh()
            s:set("api_key", "")
            assert.are.equal("", s.store._data.api_key)
        end)
    end)

    describe("reset", function()
        it("forgets a single customized key, restoring the live default", function()
            local s = fresh()
            s:set("model", "custom/model")
            s:reset("model")
            assert.is_nil(s.store._data.model)
            assert.are.equal("anthropic/claude-opus-4.8", s:get("model"))
        end)
    end)

    describe("resetToDefaults", function()
        it("clears preferences but keeps connection config and custom presets", function()
            local s = fresh()
            s:set("api_key", "secret")
            s:set("base_url", "https://my.gateway")
            s:set("model", "custom/model")
            s:set("max_turns", 5)
            s:set("enable_subagents", true)
            s:set("custom_presets", { { label = "X", prompt = "do x" } })

            s:resetToDefaults()

            -- Connection config and user-authored presets survive.
            assert.are.equal("secret", s:get("api_key"))
            assert.are.equal("https://my.gateway", s:get("base_url"))
            assert.are.equal(1, #s:getCustomPresets())
            -- Preferences fall back to defaults.
            assert.are.equal("anthropic/claude-opus-4.8", s:get("model"))
            assert.are.equal(20, s:getConfig().max_turns)
            assert.is_false(s:getConfig().enable_subagents)
        end)
    end)

    describe("migrate", function()
        local function migrated(data)
            local s = setmetatable({ store = store_with(data) }, Settings)
            s:migrate()
            return s
        end

        it("un-pins a reader still carrying the previous default model", function()
            local s = migrated({ model = "anthropic/claude-opus-4.7" })
            assert.is_nil(s.store._data.model) -- forgotten, floats to new default
            assert.are.equal("anthropic/claude-opus-4.8", s:get("model"))
            assert.are.equal(2, s.store._data.settings_version)
        end)

        it("leaves a deliberately chosen model alone", function()
            local s = migrated({ model = "some/other-model" })
            assert.are.equal("some/other-model", s:get("model"))
            assert.are.equal(2, s.store._data.settings_version)
        end)

        it("is a no-op on an already-current store", function()
            local s = migrated({ settings_version = 2, model = "anthropic/claude-opus-4.7" })
            assert.are.equal("anthropic/claude-opus-4.7", s:get("model")) -- migration skipped
        end)

        it("stamps the version on a brand-new (empty) store without touching anything", function()
            local s = migrated({})
            assert.are.equal(2, s.store._data.settings_version)
            assert.are.equal("anthropic/claude-opus-4.8", s:get("model"))
        end)
    end)
end)
