-- bbsettings config getters against an in-memory LuaSettings + DataStorage. The
-- focus is the serializable getConfig() the HTTP layer consumes: DEFAULTS
-- fallback, the max_turns clamp, and isConfigured.
local stubs = require("support.stubs")

describe("bbsettings", function()
    local Settings

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
                function store:flush() end
                return store
            end,
        }
        package.loaded["ui/widget/confirmbox"] = {
            new = function(_, o)
                return o or {}
            end,
        }
        package.loaded["ui/widget/textviewer"] = {
            new = function(_, o)
                return o or {}
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
            assert.is_true(c.enable_memory)
            assert.is_true(c.enable_thinking)
            assert.are.equal("", c.additional_system_prompt)
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

    it("coerces enable_memory/enable_thinking to real booleans", function()
        local s = fresh()
        s:set("enable_memory", false)
        local c = s:getConfig()
        assert.are.equal(false, c.enable_memory)
        assert.are.equal("boolean", type(c.enable_thinking))
    end)
end)
