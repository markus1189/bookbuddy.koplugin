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

-- A null sentinel mirroring rapidjson's: rapidjson decodes a JSON null to a
-- (truthy, non-number) userdata value, NOT Lua nil. Use real userdata via
-- newproxy so arithmetic on it throws exactly as it does in production — this is
-- what lets the suite catch "x or 0" / "if x then" guards that fail to coerce a
-- null token. json.encode emits "null" for it and json.decode returns it for the
-- "null" token, and the rapidjson stub exposes it as rapidjson.null.
json.null = newproxy and newproxy(false)
    or setmetatable({}, {
        __tostring = function()
            return "null"
        end,
    })

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
    if v == nil or v == json.null then
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
        -- An explicit __array marker (set by our decoder) or a rapidjson-style
        -- __jsontype='array' metatable (set by the rapidjson stub's array(), the
        -- production idiom for empty arrays) wins; otherwise treat a pure 1..#v
        -- sequence as an array and anything else as an object.
        local n = 0
        for _ in pairs(v) do
            n = n + 1
        end
        local mt = getmetatable(v)
        local is_array = v.__array or (mt and mt.__jsontype == "array") or (n > 0 and #v == n)
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
            return json.null
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
        -- Mirrors lua-rapidjson: tag a table so an EMPTY one still encodes as [].
        array = function(t)
            return setmetatable(t or {}, { __jsontype = "array" })
        end,
        null = json.null,
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
        -- scheduleIn models a delayed callback. Headlessly we don't honor the delay;
        -- we enqueue onto the same nextTick pump Trapper:wrap drains, so a
        -- coroutine-friendly backoff (bbretry's backoff) resumes synchronously
        -- instead of suspending forever. Ignore the delay arg, take the callback.
        scheduleIn = function(_, _delay, fn)
            handle.tick_queue[#handle.tick_queue + 1] = fn
        end,
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
    -- ButtonDialog backs the ask_user clarifying-question tool (one button per option).
    -- The default double just echoes the construction table; the question-tool spec
    -- overrides it with one that fires a scripted choice through the nextTick pump.
    package.loaded["ui/widget/buttondialog"] = {
        new = function(_, o)
            return o or {}
        end,
    }
    -- bbpresets.inputLines() reads Font:getFace(name).size to size the input box.
    package.loaded["ui/font"] = {
        getFace = function(_, _name)
            return { size = 20 }
        end,
    }

    local chatviewer = {
        last_text = nil,
        last_on_stop = nil,
        last_status = nil,
        last_on_close = nil,
    }
    chatviewer.build = function(o)
        chatviewer.last_text = o and o.text
        if o and o.on_stop then
            chatviewer.last_on_stop = o.on_stop
        end
        chatviewer.last_status = o and o.status_text
        chatviewer.last_on_close = o and o.on_close
        return { _stub = true }
    end
    chatviewer.updateText = function(_, text)
        chatviewer.last_text = text
    end
    chatviewer.updateStatus = function(_, text)
        chatviewer.last_status = text
    end
    package.loaded["bbchatviewer"] = chatviewer
    handle.chatviewer = chatviewer

    -- Recording double for bbstatusbar. The REAL module must never run under the
    -- Trapper pump above: its ticker re-arms itself via scheduleIn, and the
    -- `while suspended` drain pops-and-runs until the queue empties -- a
    -- self-rearming callback keeps the queue non-empty forever whenever the
    -- conversation coroutine parks (backoff, ask_user dialog), spinning the pump.
    -- The real ticker is exercised in statusbar_spec.lua, which pops
    -- handle.tick_queue by hand instead. Here we just record lifecycle events so
    -- conversation specs can assert the wiring (start/state/freeze/stop order).
    local statusbar = { events = {}, instances = 0 }
    statusbar.new = function()
        statusbar.instances = statusbar.instances + 1
        local function rec(e)
            statusbar.events[#statusbar.events + 1] = e
        end
        return {
            start = function()
                rec("start")
            end,
            setState = function(_, state, detail)
                rec("state:" .. state .. (detail ~= nil and (":" .. tostring(detail)) or ""))
            end,
            freeze = function()
                rec("freeze")
                return "FROZEN"
            end,
            stop = function()
                rec("stop")
            end,
            text = function()
                return "STATUS0"
            end,
        }
    end
    package.loaded["bbstatusbar"] = statusbar
    handle.statusbar = statusbar

    return handle
end

-- bbtools requires "ui/event" (not part of install()): a recording Event double
-- whose .handler/.args let a spec assert exactly what a tool dispatched.
function M.install_event()
    package.loaded["ui/event"] = {
        new = function(_, handler, a, b)
            return { handler = handler, args = { a, b } }
        end,
    }
end

-- Load a fresh real bbtools with all its load-time deps stubbed (the shared
-- KOReader doubles plus the recording Event double). Used by the pure per-tool
-- executor specs (navigate/read/grep/get_toc/create_highlight/edit_highlight_note).
function M.load_tools()
    M.install()
    M.install_event()
    package.loaded["bbtools"] = nil
    return require("bbtools")
end

-- A bbmemory double for the conversation-loop specs. By default baseDirForBook
-- returns nil, so Conversation:new skips memory entirely (every pre-existing scenario).
-- A spec opts a book into memory by setting stub.rec.base to a path: new() then hands
-- back a recorder whose execute() logs each call onto stub.rec.calls, so the loop's
-- name=="memory" dispatch branch (route to the store, not Tools.execute) is assertable.
function M.install_bbmemory_stub()
    local rec = { base = nil, calls = {} }
    local stub = {
        rec = rec,
        baseDirForBook = function()
            return rec.base
        end,
        new = function()
            return {
                execute = function(_, input)
                    rec.calls[#rec.calls + 1] = input
                    return "MEMORY_RESULT(" .. tostring(input and input.command) .. ")"
                end,
            }
        end,
        spec = function()
            return { name = "memory", description = "", input_schema = { type = "object" } }
        end,
        summaryText = function()
            return ""
        end,
        clear = noop,
    }
    package.loaded["bbmemory"] = stub
    return stub
end

-- A bbchats double for the conversation-loop specs, mirroring the bbmemory
-- double's shape: baseDirForBook returns nil by default, so Conversation:_persist
-- skips persistence in every pre-existing scenario. A spec opts in by setting
-- stub.rec.base; save() then records a SNAPSHOT of each saved state (round-tripped
-- through the JSON codec, which doubles as a serializability assertion — a
-- function or userdata smuggled into the state would blow up here just like it
-- would under real rapidjson) plus the max_chats cap the caller threaded through.
function M.install_bbchats_stub()
    local rec = { base = nil, saved = {}, next_id = 0 }
    local stub = {
        rec = rec,
        DEFAULT_MAX = 20,
        baseDirForBook = function()
            return rec.base
        end,
        save = function(_ui, state, max_chats)
            if not rec.base then
                return nil
            end
            rec.next_id = rec.next_id + 1
            state.id = state.id or ("chat-" .. rec.next_id)
            state.ts_created = state.ts_created or rec.next_id
            state.ts_updated = rec.next_id
            rec.saved[#rec.saved + 1] = {
                id = state.id,
                max_chats = max_chats,
                state = json.decode(json.encode(state)),
            }
            return state.id
        end,
        list = function()
            return {}
        end,
        load = noop,
        delete = noop,
        clear = noop,
        prune = noop,
        title = function()
            return ""
        end,
        relativeTime = function()
            return ""
        end,
    }
    package.loaded["bbchats"] = stub
    return stub
end

-- A bbtools double for the conversation-loop specs. Set `stub.state.stop_during_tool`
-- to simulate the reader tapping Stop *while a synchronous tool runs* (the real gap:
-- no live stream, _cancel is nil). When set, execute() fires the chat-viewer's captured
-- on_stop closure mid-execution; the loop must then abort at its next UI boundary
-- without issuing another request. Pass the handle from install() so the double can
-- reach the chat-viewer's on_stop. Every execute() (except the loop's own seed
-- book_context) is recorded onto stub.state.calls as {name=, input=}, so a spec can
-- assert exactly which tools ran and with what inputs (the spoiler gate's denial
-- path asserts a tool did NOT run).
function M.install_bbtools_stub(handle)
    local state = { stop_during_tool = false, calls = {} }
    local stub = {
        state = state,
        getSpecs = function()
            return {
                { name = "grep", description = "", input_schema = { type = "object" } },
                { type = "web_search_20250305", name = "web_search", max_uses = 5 },
            }
        end,
        execute = function(name, input)
            if name == "book_context" then
                return "Title: Test Book\nAuthor: Tester\nCurrent page: 10 of 200", "page 10 of 200"
            end
            state.calls[#state.calls + 1] = { name = name, input = input }
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
