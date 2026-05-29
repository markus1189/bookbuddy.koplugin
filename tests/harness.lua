-- Headless test harness for BookBuddy's conversation logic.
--
-- It loads the real bbconversation.lua and bbanthropic.lua (the streaming parser
-- included) and stubs out every KOReader dependency, so we can drive the full
-- multi-turn tool loop without a device or network. Each turn's "API response" is
-- a scripted list of SSE lines fed to the real parser; the messages the loop would
-- POST on every turn are captured and checked against a validator that mirrors the
-- Vertex AI request rules (the pairing of server_tool_use with web_search_tool_result,
-- role alternation, and client tool_use/tool_result pairing).
--
-- Run it with: luajit tests/harness.lua   (from the plugin dir)
--          or: nix run nixpkgs#luajit -- tests/harness.lua

-- Resolve the plugin dir (parent of this tests/ dir) onto package.path.
local script = (arg and arg[0]) or "tests/harness.lua"
local dir = script:match("^(.*)/[^/]*$") or "."
package.path = dir .. "/../?.lua;" .. dir .. "/?.lua;" .. package.path

--------------------------------------------------------------------------------
-- Minimal JSON (encode/decode) so the harness has no external dependencies.
--------------------------------------------------------------------------------
local json = {}

local function utf8char(cp)
    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
    else
        return string.char(0xE0 + math.floor(cp / 0x1000),
            0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
    end
end

local enc_escapes = {
    ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b',
    ['\f'] = '\\f', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
}
local function encodeString(s)
    return '"' .. s:gsub('[%z\1-\31\\"]', function(c)
        return enc_escapes[c] or string.format("\\u%04x", c:byte())
    end) .. '"'
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
        for _ in pairs(v) do n = n + 1 end
        local is_array = v.__array or (n > 0 and #v == n)
        if is_array then
            local parts = {}
            for i = 1, #v do parts[i] = json.encode(v[i]) end
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
            if c == "" then error("unterminated string") end
            if c == '"' then pos = pos + 1; break end
            if c == "\\" then
                local n = str:sub(pos + 1, pos + 1)
                local map = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/',
                    b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' }
                if map[n] then
                    buf[#buf + 1] = map[n]; pos = pos + 2
                elseif n == 'u' then
                    buf[#buf + 1] = utf8char(tonumber(str:sub(pos + 2, pos + 5), 16))
                    pos = pos + 6
                else
                    error("bad escape \\" .. n)
                end
            else
                buf[#buf + 1] = c; pos = pos + 1
            end
        end
        return table.concat(buf)
    end
    parseValue = function()
        skipws()
        local c = str:sub(pos, pos)
        if c == "{" then
            pos = pos + 1; skipws()
            local obj = {}
            if str:sub(pos, pos) == "}" then pos = pos + 1; return obj end
            while true do
                skipws()
                local key = parseString()
                skipws()
                pos = pos + 1 -- skip ':'
                obj[key] = parseValue()
                skipws()
                local ch = str:sub(pos, pos)
                pos = pos + 1
                if ch == "}" then break elseif ch ~= "," then error("expected , or }") end
            end
            return obj
        elseif c == "[" then
            pos = pos + 1; skipws()
            local arr = { __array = true }
            if str:sub(pos, pos) == "]" then pos = pos + 1; return arr end
            while true do
                arr[#arr + 1] = parseValue()
                skipws()
                local ch = str:sub(pos, pos)
                pos = pos + 1
                if ch == "]" then break elseif ch ~= "," then error("expected , or ]") end
            end
            return arr
        elseif c == '"' then
            return parseString()
        elseif c == "t" then
            pos = pos + 4; return true
        elseif c == "f" then
            pos = pos + 5; return false
        elseif c == "n" then
            pos = pos + 4; return nil
        else
            local s, e = str:find("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", pos)
            if not s then error("unexpected char '" .. c .. "' at " .. pos) end
            local num = tonumber(str:sub(s, e))
            pos = e + 1
            return num
        end
    end
    return parseValue()
end

--------------------------------------------------------------------------------
-- Stub KOReader + plugin dependencies before requiring the code under test.
--------------------------------------------------------------------------------
local function noop() end

package.loaded["rapidjson"] = {
    encode = json.encode,
    decode = function(s)
        local ok, r = pcall(json.decode, s)
        if ok then return r end
        return nil
    end,
    object = function(t) return t or {} end,
}
package.loaded["logger"] = { dbg = noop, warn = noop, info = noop, error = noop }
package.loaded["gettext"] = function(s) return s end
package.loaded["ffi/util"] = {
    template = function(fmt, ...)
        local args = { ... }
        return (fmt:gsub("%%(%d+)", function(n) return tostring(args[tonumber(n)] or "") end))
    end,
}
-- The loop yields once per round at its UI boundary, scheduling a nextTick that
-- resumes it (so a real device dispatches a buffered Stop tap there). Headlessly
-- we model the event loop: nextTick queues the callback, and Trapper:wrap pumps
-- the queue after each yield, resuming the coroutine until it finishes.
local tick_queue = {}
package.loaded["ui/uimanager"] = {
    scheduleIn = noop, unschedule = noop, show = noop, close = noop,
    nextTick = function(_, fn) tick_queue[#tick_queue + 1] = fn end,
}
-- Run the conversation inside a coroutine so the loop can coroutine.yield() at
-- its UI boundary, matching Trapper:wrap on a device (LuaJIT can't yield from the
-- main thread). After each yield, drain the nextTick queue (each entry resumes us).
package.loaded["ui/trapper"] = { wrap = function(_, fn)
    tick_queue = {}
    local co = coroutine.create(fn)
    local ok, err = coroutine.resume(co)
    if not ok then error(err) end
    while coroutine.status(co) == "suspended" do
        local cb = table.remove(tick_queue, 1)
        if not cb then break end
        cb()
    end
end }
package.loaded["ui/network/manager"] = { willRerunWhenOnline = function() return false end }
package.loaded["ui/widget/infomessage"] = { new = function(_, o) return o or {} end }
package.loaded["ui/widget/inputdialog"] = { new = function(_, o) return o or {} end }

local ChatViewerStub = {}
ChatViewerStub.last_text = nil
ChatViewerStub.last_on_stop = nil
ChatViewerStub.build = function(o)
    ChatViewerStub.last_text = o and o.text
    if o and o.on_stop then ChatViewerStub.last_on_stop = o.on_stop end
    return { _stub = true }
end
ChatViewerStub.updateText = function(_, text) ChatViewerStub.last_text = text end
package.loaded["bbchatviewer"] = ChatViewerStub
package.loaded["bbmemory"] = {
    baseDirForBook = function() return nil end,
    new = function() return {} end,
    spec = function() return {} end,
    summaryText = function() return "" end,
    clear = noop,
}
-- A scenario sets stop_during_tool to simulate the reader tapping Stop *while a
-- synchronous tool runs* (the real gap: no live stream, _cancel is nil). The
-- bbtools.execute stub fires the captured on_stop closure mid-execution; the loop
-- must then abort at its next UI boundary without issuing another request.
local stop_during_tool = false
package.loaded["bbtools"] = {
    getSpecs = function()
        return {
            { name = "search_book", description = "", input_schema = { type = "object" } },
            { type = "web_search_20250305", name = "web_search", max_uses = 5 },
        }
    end,
    execute = function(name)
        if name == "book_context" then
            return "Title: Test Book\nAuthor: Tester\nCurrent page: 10 of 200", "page 10 of 200"
        end
        if stop_during_tool and ChatViewerStub.last_on_stop then
            stop_during_tool = false
            ChatViewerStub.last_on_stop()
        end
        return "TOOL_RESULT(" .. tostring(name) .. ")", "ok"
    end,
}

-- Fake transport: each Stream.run pops the next scripted SSE response and feeds
-- its lines to the real parser via on_line.
local FakeStream = { responses = {}, idx = 0 }
function FakeStream.reset(responses)
    FakeStream.responses = responses or {}
    FakeStream.idx = 0
end
function FakeStream.run(opts)
    FakeStream.idx = FakeStream.idx + 1
    local resp = FakeStream.responses[FakeStream.idx]
    if opts.register_cancel then opts.register_cancel(noop) end
    if not resp then
        if opts.register_cancel then opts.register_cancel(nil) end
        return { completed = false, cancelled = false, read_error = true }
    end
    for _, line in ipairs(resp) do
        if opts.on_line then opts.on_line(line) end
    end
    if opts.register_cancel then opts.register_cancel(nil) end
    return { completed = true, cancelled = false, read_error = false }
end
package.loaded["bbstream"] = FakeStream

-- Real modules under test.
local Anthropic = require("bbanthropic")
local Conversation = require("bbconversation")

-- Capture the messages array on each outgoing request by wrapping buildBody.
local captured = {}
local function deepcopy(v)
    if type(v) ~= "table" then return v end
    local t = {}
    for k, val in pairs(v) do t[k] = deepcopy(val) end
    return t
end
Anthropic.buildBody = function(messages, tools)
    captured[#captured + 1] = { messages = deepcopy(messages), tools = tools and #tools or 0 }
    return "" -- body is unused by FakeStream
end

--------------------------------------------------------------------------------
-- SSE scripting helpers: build the event lines the real parser consumes.
--------------------------------------------------------------------------------
local function ev(obj) return "data: " .. json.encode(obj) end

local function buildTurnSSE(spec)
    local lines = {}
    lines[#lines + 1] = ev{
        type = "message_start",
        message = { usage = { input_tokens = 10, output_tokens = 0,
            cache_read_input_tokens = 0, cache_creation_input_tokens = 0 } },
    }
    for i, b in ipairs(spec.blocks) do
        local idx = i - 1
        if b.type == "text" then
            lines[#lines + 1] = ev{ type = "content_block_start", index = idx,
                content_block = { type = "text", text = "" } }
            lines[#lines + 1] = ev{ type = "content_block_delta", index = idx,
                delta = { type = "text_delta", text = b.text or "" } }
            lines[#lines + 1] = ev{ type = "content_block_stop", index = idx }
        elseif b.type == "thinking" then
            lines[#lines + 1] = ev{ type = "content_block_start", index = idx,
                content_block = { type = "thinking", thinking = "" } }
            lines[#lines + 1] = ev{ type = "content_block_delta", index = idx,
                delta = { type = "thinking_delta", thinking = b.thinking or "" } }
            lines[#lines + 1] = ev{ type = "content_block_delta", index = idx,
                delta = { type = "signature_delta", signature = b.signature or "sig" } }
            lines[#lines + 1] = ev{ type = "content_block_stop", index = idx }
        elseif b.type == "server_tool_use" then
            lines[#lines + 1] = ev{ type = "content_block_start", index = idx,
                content_block = { type = "server_tool_use", id = b.id, name = b.name or "web_search" } }
            lines[#lines + 1] = ev{ type = "content_block_delta", index = idx,
                delta = { type = "input_json_delta", partial_json = json.encode(b.input or { query = "" }) } }
            lines[#lines + 1] = ev{ type = "content_block_stop", index = idx }
        elseif b.type == "tool_use" then
            lines[#lines + 1] = ev{ type = "content_block_start", index = idx,
                content_block = { type = "tool_use", id = b.id, name = b.name } }
            lines[#lines + 1] = ev{ type = "content_block_delta", index = idx,
                delta = { type = "input_json_delta", partial_json = json.encode(b.input or {}) } }
            lines[#lines + 1] = ev{ type = "content_block_stop", index = idx }
        elseif b.type == "web_search_tool_result" then
            lines[#lines + 1] = ev{ type = "content_block_start", index = idx,
                content_block = { type = "web_search_tool_result", tool_use_id = b.tool_use_id, content = b.content } }
            lines[#lines + 1] = ev{ type = "content_block_stop", index = idx }
        else
            error("unknown block type " .. tostring(b.type))
        end
    end
    lines[#lines + 1] = ev{ type = "message_delta",
        delta = { stop_reason = spec.stop_reason or "end_turn" },
        usage = { output_tokens = 20 } }
    lines[#lines + 1] = ev{ type = "message_stop" }
    return lines
end

local function webResults(n)
    local arr = { __array = true }
    for i = 1, n do
        arr[i] = { type = "web_search_result", url = "https://example.com/" .. i,
            title = "Result " .. i, encrypted_content = "enc" .. i, page_age = "2025" }
    end
    return arr
end

--------------------------------------------------------------------------------
-- Validator: mirror the Vertex AI request rules.
--------------------------------------------------------------------------------
local function validateMessages(messages)
    local errs = {}
    if messages[1] and messages[1].role ~= "user" then
        errs[#errs + 1] = "messages.0: first message must have role user"
    end
    -- Role alternation: two consecutive same-role messages are rejected.
    for i = 2, #messages do
        if messages[i].role == messages[i - 1].role then
            errs[#errs + 1] = string.format(
                "messages.%d: roles must alternate (this and messages.%d are both '%s')",
                i - 1, i - 2, messages[i].role)
        end
    end
    for i = 1, #messages do
        local m = messages[i]
        local mi = i - 1
        if m.role == "assistant" and type(m.content) == "table" then
            local results, servertools = {}, {}
            for _, b in ipairs(m.content) do
                if b.type == "web_search_tool_result" and b.tool_use_id then results[b.tool_use_id] = true end
                if b.type == "server_tool_use" and b.id then servertools[b.id] = true end
            end
            for _, b in ipairs(m.content) do
                if b.type == "server_tool_use" and b.name == "web_search" and not results[b.id] then
                    errs[#errs + 1] = string.format(
                        "messages.%d: `web_search` tool use with id `%s` was found without a corresponding `web_search_tool_result` block",
                        mi, tostring(b.id))
                end
                if b.type == "web_search_tool_result" and not servertools[b.tool_use_id] then
                    errs[#errs + 1] = string.format(
                        "messages.%d: `web_search_tool_result` with tool_use_id `%s` has no corresponding `server_tool_use` block",
                        mi, tostring(b.tool_use_id))
                end
            end
        end
        -- Client tool_use must be answered by tool_result in the next user message.
        if m.role == "assistant" and type(m.content) == "table" then
            local pending = {}
            for _, b in ipairs(m.content) do
                if b.type == "tool_use" then pending[b.id] = true end
            end
            if next(pending) then
                local answered = {}
                local nxt = messages[i + 1]
                if nxt and nxt.role == "user" and type(nxt.content) == "table" then
                    for _, b in ipairs(nxt.content) do
                        if b.type == "tool_result" and b.tool_use_id then answered[b.tool_use_id] = true end
                    end
                end
                for id in pairs(pending) do
                    if not answered[id] then
                        errs[#errs + 1] = string.format(
                            "messages.%d: tool_use `%s` has no tool_result in the following user message", mi, id)
                    end
                end
            end
        end
    end
    return errs
end

--------------------------------------------------------------------------------
-- Scenario runner.
--------------------------------------------------------------------------------
local cfg = {
    base_url = "https://example", portkey_api_key = "k", model = "test",
    max_tokens = 1024, max_turns = 20,
    system_prompt = "sys", enable_memory = false, enable_thinking = false,
}
local stubSettings = { getConfig = function() return cfg end }

local function describeBlocks(content)
    if type(content) ~= "table" then return "<text:" .. tostring(content):sub(1, 20) .. ">" end
    local parts = {}
    for _, b in ipairs(content) do
        if b.type == "server_tool_use" then
            parts[#parts + 1] = "srv_tool_use(" .. tostring(b.id) .. ")"
        elseif b.type == "web_search_tool_result" then
            local kind = (type(b.content) == "table" and b.content.type == "web_search_tool_result_error")
                and "err" or "ok"
            parts[#parts + 1] = "ws_result(" .. tostring(b.tool_use_id) .. ":" .. kind .. ")"
        elseif b.type == "tool_use" then
            parts[#parts + 1] = "tool_use(" .. tostring(b.id) .. ")"
        elseif b.type == "tool_result" then
            parts[#parts + 1] = "tool_result(" .. tostring(b.tool_use_id) .. ")"
        else
            parts[#parts + 1] = b.type
        end
    end
    return "[" .. table.concat(parts, ", ") .. "]"
end

local total_pass, total_fail = 0, 0

local function runScenario(sc)
    captured = {}
    FakeStream.reset(sc.responses)
    ChatViewerStub.last_on_stop = nil
    stop_during_tool = sc.stop_during_tool or false
    -- Per-scenario max_turns override, restored after the run (the shared cfg is
    -- otherwise max_turns = 20). Used to exercise the substantive-turn budget edge.
    local saved_max_turns = cfg.max_turns
    if sc.max_turns then cfg.max_turns = sc.max_turns end
    local conv = Conversation:new{ ui = {}, settings = stubSettings, selected_text = "the passage" }
    conv:ask(sc.first_question or "What does this mean?")
    for _, fq in ipairs(sc.followups or {}) do conv:ask(fq) end
    cfg.max_turns = saved_max_turns
    local final_messages = conv.messages

    print("\n=== " .. sc.name .. " ===")
    local scenario_ok = true
    for n, req in ipairs(captured) do
        local errs = validateMessages(req.messages)
        local status = (#errs == 0) and "PASS" or "FAIL"
        if #errs > 0 then scenario_ok = false end
        print(string.format("  request %d (%d msgs): %s", n, #req.messages, status))
        for _, m in ipairs(req.messages) do
            print(string.format("      %-9s %s", m.role, describeBlocks(m.content)))
        end
        for _, e in ipairs(errs) do
            print("      ! " .. e)
        end
    end
    if FakeStream.idx > #FakeStream.responses then
        print(string.format("  NOTE: loop requested %d responses but only %d were scripted",
            FakeStream.idx, #FakeStream.responses))
        scenario_ok = false
    end

    -- Validity alone won't catch a silently-missing final answer (a turn budget
    -- exhausted by pauses), so optionally assert the rendered transcript contains
    -- the expected answer text.
    if sc.expect_text then
        local rendered = ChatViewerStub.last_text or ""
        if rendered:find(sc.expect_text, 1, true) then
            print(string.format("  text check: found %q (PASS)", sc.expect_text))
        else
            print(string.format("  text check: missing %q (FAIL)", sc.expect_text))
            scenario_ok = false
        end
    end

    -- Assert how many requests the loop issued: a Stop honored at the loop boundary
    -- must abort *before* forking the next request, so the index must not advance
    -- past the tool turn (here: exactly one request, no wasted follow-up).
    if sc.expect_requests then
        if FakeStream.idx == sc.expect_requests then
            print(string.format("  request count: %d as expected (PASS)", FakeStream.idx))
        else
            print(string.format("  request count: got %d, want %d (FAIL)", FakeStream.idx, sc.expect_requests))
            scenario_ok = false
        end
    end

    -- After a Stop honored at the loop boundary, the stored history must stay
    -- resendable: the in-flight tool round left assistant(tool_use) + user(tool_result)
    -- balanced, with no dangling tool_use, so a later ask() can POST it. Also assert
    -- the tool actually ran (the stop hook fired), so the check isn't vacuous, and
    -- that the history really ends on the tool_result pair (not just the seed).
    if sc.expect_final_valid then
        local ferrs = validateMessages(final_messages)
        local last = final_messages[#final_messages]
        local ends_with_tool_result = last and last.role == "user"
            and type(last.content) == "table" and last.content[1]
            and last.content[1].type == "tool_result"
        if #ferrs == 0 and not stop_during_tool and ends_with_tool_result then
            print("  final history: tool round stored, balanced/resendable (PASS)")
        else
            scenario_ok = false
            print("  final history: NOT resendable (FAIL)")
            if stop_during_tool then print("      ! stop hook never fired (tool did not run)") end
            if not ends_with_tool_result then print("      ! history does not end on a tool_result") end
            for _, e in ipairs(ferrs) do print("      ! " .. e) end
        end
    end

    if sc.show_transcript then
        print("  --- final transcript ---")
        for line in (ChatViewerStub.last_text or ""):gmatch("[^\n]*") do
            print("  | " .. line)
        end
    end

    local expect_ok = (sc.expect_ok ~= false)
    if scenario_ok == expect_ok then
        total_pass = total_pass + 1
        print("  -> scenario " .. (expect_ok and "valid as expected" or "failed as expected") .. " (PASS)")
    else
        total_fail = total_fail + 1
        print("  -> UNEXPECTED: scenario " .. (scenario_ok and "valid" or "invalid")
            .. " but expected " .. (expect_ok and "valid" or "invalid") .. " (FAIL)")
    end
end

--------------------------------------------------------------------------------
-- Scenarios.
--------------------------------------------------------------------------------
runScenario{
    name = "S1: web search completes, then a follow-up",
    responses = {
        buildTurnSSE{ blocks = {
            { type = "text", text = "Let me check the web." },
            { type = "server_tool_use", id = "srvtoolu_A", input = { query = "claude shannon" } },
            { type = "web_search_tool_result", tool_use_id = "srvtoolu_A", content = webResults(2) },
            { type = "text", text = "Shannon was born in 1916." },
        }, stop_reason = "end_turn" },
        buildTurnSSE{ blocks = { { type = "text", text = "Here is more detail." } }, stop_reason = "end_turn" },
    },
    followups = { "Tell me more." },
}

runScenario{
    name = "S2: pause_turn dangling web search, resume, then a follow-up",
    responses = {
        buildTurnSSE{ blocks = {
            { type = "text", text = "Searching the web..." },
            { type = "server_tool_use", id = "srvtoolu_B", input = { query = "a long search" } },
        }, stop_reason = "pause_turn" },
        buildTurnSSE{ blocks = {
            { type = "text", text = "Based on what I found, the answer is X." },
        }, stop_reason = "end_turn" },
        buildTurnSSE{ blocks = { { type = "text", text = "Follow-up answer." } }, stop_reason = "end_turn" },
    },
    followups = { "And what about Y?" },
}

runScenario{
    name = "S3: two consecutive pause_turns, then a text answer, then a follow-up",
    responses = {
        buildTurnSSE{ blocks = {
            { type = "text", text = "Searching (1)..." },
            { type = "server_tool_use", id = "srvtoolu_C", input = { query = "q1" } },
        }, stop_reason = "pause_turn" },
        buildTurnSSE{ blocks = {
            { type = "text", text = "Still searching..." },
            { type = "server_tool_use", id = "srvtoolu_D", input = { query = "q2" } },
        }, stop_reason = "pause_turn" },
        buildTurnSSE{ blocks = {
            { type = "text", text = "Here is my best answer." },
        }, stop_reason = "end_turn" },
        buildTurnSSE{ blocks = { { type = "text", text = "Sure." } }, stop_reason = "end_turn" },
    },
    followups = { "Anything else?" },
}

runScenario{
    name = "S4: pause_turn, resume, then a client tool call",
    responses = {
        buildTurnSSE{ blocks = {
            { type = "text", text = "Let me look outside the book." },
            { type = "server_tool_use", id = "srvtoolu_W", input = { query = "author bio" } },
        }, stop_reason = "pause_turn" },
        buildTurnSSE{ blocks = {
            { type = "text", text = "Now let me check the book itself." },
            { type = "tool_use", id = "toolu_Z", name = "search_book", input = { query = "whales" } },
        }, stop_reason = "tool_use" },
        buildTurnSSE{ blocks = { { type = "text", text = "Here is what I found." } }, stop_reason = "end_turn" },
    },
}

runScenario{
    -- Three pause_turns then an answer, under a 2-turn budget. Pauses are not
    -- substantive turns, so they must not spend the budget: the loop has to resume
    -- through all of them and still reach the text answer. (Under the old
    -- accounting each pause burned a turn, so the budget ran out mid-search and the
    -- answer was never produced.)
    name = "S6: pauses do not consume the substantive turn budget",
    max_turns = 2,
    expect_text = "Finally, the answer is 42.",
    responses = {
        buildTurnSSE{ blocks = {
            { type = "text", text = "Searching (1)..." },
            { type = "server_tool_use", id = "srvtoolu_P1", input = { query = "q1" } },
        }, stop_reason = "pause_turn" },
        buildTurnSSE{ blocks = {
            { type = "text", text = "Searching (2)..." },
            { type = "server_tool_use", id = "srvtoolu_P2", input = { query = "q2" } },
        }, stop_reason = "pause_turn" },
        buildTurnSSE{ blocks = {
            { type = "text", text = "Searching (3)..." },
            { type = "server_tool_use", id = "srvtoolu_P3", input = { query = "q3" } },
        }, stop_reason = "pause_turn" },
        buildTurnSSE{ blocks = {
            { type = "text", text = "Finally, the answer is 42." },
        }, stop_reason = "end_turn" },
    },
}

runScenario{
    name = "S5: thinking + completed web search in one turn",
    show_transcript = true,
    responses = {
        buildTurnSSE{ blocks = {
            { type = "thinking", thinking = "The reader asks about the author; I should look it up." },
            { type = "text", text = "Let me look that up." },
            { type = "server_tool_use", id = "srvtoolu_E", input = { query = "Max Gladstone biography" } },
            { type = "web_search_tool_result", tool_use_id = "srvtoolu_E", content = webResults(3) },
            { type = "text", text = "The author is Max Gladstone, born 1984." },
        }, stop_reason = "end_turn" },
    },
}

--------------------------------------------------------------------------------
-- Unit checks for tool-call phrasing.
--------------------------------------------------------------------------------
local function checkPhrase(label, got, want)
    if got == want then
        total_pass = total_pass + 1
        print(string.format("  ok:   %-24s -> %s", label, got))
    else
        total_fail = total_fail + 1
        print(string.format("  FAIL: %-24s -> got %q, want %q", label, got, want))
    end
end

print("\n=== Unit: memory tool phrases ===")
do
    local conv = Conversation:new{ ui = {}, settings = stubSettings, selected_text = "x" }
    local function phrase(input) return conv:_toolActionPhrase({ name = "memory", input = input }) end
    checkPhrase("view root", phrase{ command = "view", path = "/memories" },
        "  → Reviewed saved memory")
    checkPhrase("view file", phrase{ command = "view", path = "/memories/characters.md" },
        "  → Read memory note characters.md")
    checkPhrase("create", phrase{ command = "create", path = "/memories/themes.md" },
        "  → Saved memory note themes.md")
    checkPhrase("str_replace", phrase{ command = "str_replace", path = "/memories/themes.md" },
        "  → Updated memory note themes.md")
    checkPhrase("delete", phrase{ command = "delete", path = "/memories/old.md" },
        "  → Deleted memory note old.md")
    checkPhrase("rename", phrase{ command = "rename", old_path = "/memories/a.md", new_path = "/memories/b.md" },
        "  → Renamed memory note a.md to b.md")
end

print("\n=== Unit: navigate tool phrases ===")
do
    local conv = Conversation:new{ ui = {}, settings = stubSettings, selected_text = "x" }
    local function phrase(input) return conv:_toolActionPhrase({ name = "navigate", input = input }) end
    checkPhrase("nav page", phrase{ page = 88 }, "  → Went to page 88")
    checkPhrase("nav percent", phrase{ percent = 50 }, "  → Went to 50%")
    checkPhrase("nav chapter", phrase{ chapter_index = 3 }, "  → Went to chapter 3")
    checkPhrase("nav back", phrase{ back = true }, "  → Went back")
end

-- Exercise the real navigate executor (the bbtools stub above is only for the
-- conversation loop). Load the real module fresh with ui/event stubbed so
-- Event:new records dispatched events, and drive it with a fake ui.
print("\n=== Unit: navigate tool executor ===")
do
    package.loaded["ui/event"] = {
        new = function(_, handler, a, b) return { handler = handler, args = { a, b } } end,
    }
    local RealTools = dofile(dir .. "/../bbtools.lua")

    local function makeUI(o)
        o = o or {}
        local rec = { events = {}, pushes = 0, backs = 0 }
        local page = o.page or 10
        local ui = {
            rolling = o.rolling, -- nil => paging engine
            view = { state = { page = page } },
            document = {
                getCurrentPage = function() return page end,
                getPageCount = function() return o.page_count or 200 end,
                getToc = function() return o.toc or {} end,
            },
            toc = { getTocTitleOfCurrentPage = function() return o.chapter or "" end },
            link = {
                location_stack = o.location_stack or {},
                addCurrentLocationToStack = function() rec.pushes = rec.pushes + 1 end,
                onGoBackLink = function() rec.backs = rec.backs + 1 end,
            },
            handleEvent = function(_, ev) rec.events[#rec.events + 1] = ev end,
        }
        return ui, rec
    end

    local function check(label, cond)
        if cond then
            total_pass = total_pass + 1
            print("  ok:   " .. label)
        else
            total_fail = total_fail + 1
            print("  FAIL: " .. label)
        end
    end

    do -- page jump (paging engine)
        local ui, rec = makeUI{ page = 10, chapter = "Chapter 1" }
        local result, summary = RealTools.execute("navigate", { page = 88 }, ui)
        check("page: pushed to history once", rec.pushes == 1)
        check("page: one GotoPage event to 88",
            #rec.events == 1 and rec.events[1].handler == "GotoPage" and rec.events[1].args[1] == 88)
        check("page: result reports prior page 10", result:find("page 10") ~= nil)
        check("page: summary set", summary ~= nil and summary ~= "")
    end

    do -- percent jump
        local ui, rec = makeUI{ page = 10 }
        RealTools.execute("navigate", { percent = 50 }, ui)
        check("percent: pushed once", rec.pushes == 1)
        check("percent: GotoPercent 50",
            rec.events[1] and rec.events[1].handler == "GotoPercent" and rec.events[1].args[1] == 50)
    end

    do -- chapter jump, rolling engine with xpointer
        local ui, rec = makeUI{ rolling = true, page = 5,
            toc = { { title = "One", page = 1, xpointer = "xp1" },
                    { title = "Two", page = 40, xpointer = "xp40" } } }
        RealTools.execute("navigate", { chapter_index = 2 }, ui)
        check("chapter(rolling): pushed once", rec.pushes == 1)
        check("chapter(rolling): GotoXPointer xp40",
            rec.events[1] and rec.events[1].handler == "GotoXPointer" and rec.events[1].args[1] == "xp40")
    end

    do -- chapter jump, paging engine without xpointer
        local ui, rec = makeUI{ page = 5,
            toc = { { title = "One", page = 1 }, { title = "Two", page = 40 } } }
        RealTools.execute("navigate", { chapter_index = 2 }, ui)
        check("chapter(paging): GotoPage 40",
            rec.events[1] and rec.events[1].handler == "GotoPage" and rec.events[1].args[1] == 40)
    end

    do -- back with a non-empty history stack
        local ui, rec = makeUI{ page = 88, location_stack = { { page = 10 } } }
        RealTools.execute("navigate", { back = true }, ui)
        check("back: called onGoBackLink", rec.backs == 1)
        check("back: did not push to stack", rec.pushes == 0)
    end

    do -- back with an empty history stack
        local ui, rec = makeUI{ page = 88, location_stack = {} }
        local result = RealTools.execute("navigate", { back = true }, ui)
        check("back(empty): did not call onGoBackLink", rec.backs == 0)
        check("back(empty): explains there is nothing to go back to",
            result:find("no previous location") ~= nil)
    end

    do -- no target / multiple targets
        local ui = makeUI{}
        check("no target: errors", RealTools.execute("navigate", {}, ui):find("exactly one") ~= nil)
        check("multi target: errors",
            RealTools.execute("navigate", { page = 5, percent = 50 }, ui):find("only one") ~= nil)
    end
end

print(string.format("\n==== %d check(s) passed, %d failed ====", total_pass, total_fail))
os.exit(total_fail == 0 and 0 or 1)
