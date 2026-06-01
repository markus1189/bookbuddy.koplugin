-- Shared KOReader/plugin stubs for the busted suite.
--
-- `install()` registers the lightweight KOReader doubles into package.loaded and
-- returns a handle holding the mutable bits a spec might poke (the chat-viewer
-- double, the nextTick queue). Call it inside a spec's setup() *before* requiring
-- the module under test, so the module's load-time requires resolve to these
-- stubs. busted's per-block insulate rolls package.loaded back afterwards, so a
-- stubbed module in one spec cannot leak into another spec's real one.
--
-- Optional doubles `install_bbmemory_stub()` / `install_bbtools_stub(handle)` are
-- only needed by the conversation-loop specs.

local M = {}

--------------------------------------------------------------------------------
-- Minimal JSON (encode/decode) so the suite has no external dependency for the
-- SSE scripting helpers. Ported verbatim from the old tests/harness.lua.
--------------------------------------------------------------------------------
local json = {}
M.json = json

local function utf8char(cp)
    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
    else
        return string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
    end
end

local enc_escapes = {
    ['"'] = '\\"',
    ["\\"] = "\\\\",
    ["\b"] = "\\b",
    ["\f"] = "\\f",
    ["\n"] = "\\n",
    ["\r"] = "\\r",
    ["\t"] = "\\t",
}
local function encodeString(s)
    return '"'
        .. s:gsub('[%z\1-\31\\"]', function(c)
            return enc_escapes[c] or string.format("\\u%04x", c:byte())
        end)
        .. '"'
end

function json.encode(v)
    local t = type(v)
    if v == nil then
        return "null"
    elseif t == "boolean" then
        return v and "true" or "false"
    elseif t == "number" then
        if v == math.floor(v) and math.abs(v) < 1e15 then
            return string.format("%d", v)
        end
        return tostring(v)
    elseif t == "string" then
        return encodeString(v)
    elseif t == "table" then
        -- An explicit __array marker (set by our decoder) wins; otherwise treat a
        -- pure 1..#v sequence as an array and anything else as an object.
        local n = 0
        for _ in pairs(v) do
            n = n + 1
        end
        local is_array = v.__array or (n > 0 and #v == n)
        if is_array then
            local parts = {}
            for i = 1, #v do
                parts[i] = json.encode(v[i])
            end
            return "[" .. table.concat(parts, ",") .. "]"
        elseif n == 0 then
            return "{}"
        else
            local parts = {}
            for k, val in pairs(v) do
                if k ~= "__array" then
                    parts[#parts + 1] = encodeString(tostring(k)) .. ":" .. json.encode(val)
                end
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    end
    error("cannot encode " .. t)
end

function json.decode(str)
    local pos = 1
    local parseValue
    local function skipws()
        local _, e = str:find("^[ \t\r\n]*", pos)
        pos = e + 1
    end
    local function parseString()
        pos = pos + 1 -- skip opening quote
        local buf = {}
        while true do
            local c = str:sub(pos, pos)
            if c == "" then
                error("unterminated string")
            end
            if c == '"' then
                pos = pos + 1
                break
            end
            if c == "\\" then
                local n = str:sub(pos + 1, pos + 1)
                local map = {
                    ['"'] = '"',
                    ["\\"] = "\\",
                    ["/"] = "/",
                    b = "\b",
                    f = "\f",
                    n = "\n",
                    r = "\r",
                    t = "\t",
                }
                if map[n] then
                    buf[#buf + 1] = map[n]
                    pos = pos + 2
                elseif n == "u" then
                    buf[#buf + 1] = utf8char(tonumber(str:sub(pos + 2, pos + 5), 16))
                    pos = pos + 6
                else
                    error("bad escape \\" .. n)
                end
            else
                buf[#buf + 1] = c
                pos = pos + 1
            end
        end
        return table.concat(buf)
    end
    parseValue = function()
        skipws()
        local c = str:sub(pos, pos)
        if c == "{" then
            pos = pos + 1
            skipws()
            local obj = {}
            if str:sub(pos, pos) == "}" then
                pos = pos + 1
                return obj
            end
            while true do
                skipws()
                local key = parseString()
                skipws()
                pos = pos + 1 -- skip ':'
                obj[key] = parseValue()
                skipws()
                local ch = str:sub(pos, pos)
                pos = pos + 1
                if ch == "}" then
                    break
                elseif ch ~= "," then
                    error("expected , or }")
                end
            end
            return obj
        elseif c == "[" then
            pos = pos + 1
            skipws()
            local arr = { __array = true }
            if str:sub(pos, pos) == "]" then
                pos = pos + 1
                return arr
            end
            while true do
                arr[#arr + 1] = parseValue()
                skipws()
                local ch = str:sub(pos, pos)
                pos = pos + 1
                if ch == "]" then
                    break
                elseif ch ~= "," then
                    error("expected , or ]")
                end
            end
            return arr
        elseif c == '"' then
            return parseString()
        elseif c == "t" then
            pos = pos + 4
            return true
        elseif c == "f" then
            pos = pos + 5
            return false
        elseif c == "n" then
            pos = pos + 4
            return nil
        else
            local s, e = str:find("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", pos)
            if not s then
                error("unexpected char '" .. c .. "' at " .. pos)
            end
            local num = tonumber(str:sub(s, e))
            pos = e + 1
            return num
        end
    end
    return parseValue()
end

--------------------------------------------------------------------------------
-- KOReader dependency stubs.
--------------------------------------------------------------------------------
local function noop() end
M.noop = noop

-- Register the lightweight KOReader doubles and return a handle. The handle owns
-- the nextTick queue (shared by the uimanager/trapper doubles) and the chat-viewer
-- double, so each install() call is self-contained and per-spec isolated.
function M.install()
    local handle = { tick_queue = {} }

    package.loaded["rapidjson"] = {
        encode = json.encode,
        decode = function(s)
            local ok, r = pcall(json.decode, s)
            if ok then
                return r
            end
            return nil
        end,
        object = function(t)
            return t or {}
        end,
    }
    package.loaded["logger"] = { dbg = noop, warn = noop, info = noop, error = noop }
    package.loaded["gettext"] = function(s)
        return s
    end
    package.loaded["ffi/util"] = {
        template = function(fmt, ...)
            local args = { ... }
            return (
                fmt:gsub("%%(%d+)", function(n)
                    return tostring(args[tonumber(n)] or "")
                end)
            )
        end,
    }
    package.loaded["util"] = {
        -- Trim + collapse interior whitespace, matching util.cleanupSelectedText's intent.
        cleanupSelectedText = function(text)
            return (tostring(text or ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
        end,
    }
    -- The loop yields once per round at its UI boundary, scheduling a nextTick that
    -- resumes it (so a real device dispatches a buffered Stop tap there). Headlessly
    -- we model the event loop: nextTick queues the callback, and Trapper:wrap pumps
    -- the queue after each yield, resuming the coroutine until it finishes.
    package.loaded["ui/uimanager"] = {
        scheduleIn = noop,
        unschedule = noop,
        show = noop,
        close = noop,
        nextTick = function(_, fn)
            handle.tick_queue[#handle.tick_queue + 1] = fn
        end,
    }
    -- Run the conversation inside a coroutine so the loop can coroutine.yield() at
    -- its UI boundary, matching Trapper:wrap on a device (LuaJIT can't yield from the
    -- main thread). After each yield, drain the nextTick queue (each entry resumes us).
    package.loaded["ui/trapper"] = {
        wrap = function(_, fn)
            handle.tick_queue = {}
            local co = coroutine.create(fn)
            local ok, err = coroutine.resume(co)
            if not ok then
                error(err)
            end
            while coroutine.status(co) == "suspended" do
                local cb = table.remove(handle.tick_queue, 1)
                if not cb then
                    break
                end
                cb()
            end
        end,
    }
    package.loaded["ui/network/manager"] = {
        willRerunWhenOnline = function()
            return false
        end,
    }
    package.loaded["ui/widget/infomessage"] = {
        new = function(_, o)
            return o or {}
        end,
    }
    package.loaded["ui/widget/inputdialog"] = {
        new = function(_, o)
            return o or {}
        end,
    }

    local chatviewer = {
        last_text = nil,
        last_on_stop = nil,
    }
    chatviewer.build = function(o)
        chatviewer.last_text = o and o.text
        if o and o.on_stop then
            chatviewer.last_on_stop = o.on_stop
        end
        return { _stub = true }
    end
    chatviewer.updateText = function(_, text)
        chatviewer.last_text = text
    end
    package.loaded["bbchatviewer"] = chatviewer
    handle.chatviewer = chatviewer

    return handle
end

-- A no-op-ish bbmemory double for specs that don't exercise real memory.
function M.install_bbmemory_stub()
    local stub = {
        baseDirForBook = function()
            return nil
        end,
        new = function()
            return {}
        end,
        spec = function()
            return {}
        end,
        summaryText = function()
            return ""
        end,
        clear = noop,
    }
    package.loaded["bbmemory"] = stub
    return stub
end

-- A bbtools double for the conversation-loop specs. Set `stub.state.stop_during_tool`
-- to simulate the reader tapping Stop *while a synchronous tool runs* (the real gap:
-- no live stream, _cancel is nil). When set, execute() fires the chat-viewer's captured
-- on_stop closure mid-execution; the loop must then abort at its next UI boundary
-- without issuing another request. Pass the handle from install() so the double can
-- reach the chat-viewer's on_stop.
function M.install_bbtools_stub(handle)
    local state = { stop_during_tool = false }
    local stub = {
        state = state,
        getSpecs = function()
            return {
                { name = "grep", description = "", input_schema = { type = "object" } },
                { type = "web_search_20250305", name = "web_search", max_uses = 5 },
            }
        end,
        execute = function(name)
            if name == "book_context" then
                return "Title: Test Book\nAuthor: Tester\nCurrent page: 10 of 200", "page 10 of 200"
            end
            local cv = handle and handle.chatviewer
            if state.stop_during_tool and cv and cv.last_on_stop then
                state.stop_during_tool = false
                cv.last_on_stop()
            end
            return "TOOL_RESULT(" .. tostring(name) .. ")", "ok"
        end,
    }
    package.loaded["bbtools"] = stub
    return stub
end

return M
