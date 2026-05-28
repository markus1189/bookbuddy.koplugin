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
        local n = 0
        for _ in pairs(v) do n = n + 1 end
        if #v == n and (n > 0 or v.__array) then
            local parts = {}
            for i = 1, #v do parts[i] = json.encode(v[i]) end
            return "[" .. table.concat(parts, ",") .. "]"
        elseif n == 0 then
            return v.__array and "[]" or "{}"
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
package.loaded["ui/uimanager"] = { scheduleIn = noop, unschedule = noop, show = noop, close = noop }
package.loaded["ui/trapper"] = { wrap = function(_, fn) return fn() end }
package.loaded["ui/network/manager"] = { willRerunWhenOnline = function() return false end }
package.loaded["ui/widget/infomessage"] = { new = function(_, o) return o or {} end }
package.loaded["ui/widget/inputdialog"] = { new = function(_, o) return o or {} end }

package.loaded["bbchatviewer"] = {
    build = function() return { _stub = true } end,
    updateText = noop,
}
package.loaded["bbmemory"] = {
    baseDirForBook = function() return nil end,
    new = function() return {} end,
    spec = function() return {} end,
    summaryText = function() return "" end,
    clear = noop,
}
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
    local conv = Conversation:new{ ui = {}, settings = stubSettings, selected_text = "the passage" }
    conv:ask(sc.first_question or "What does this mean?")
    for _, fq in ipairs(sc.followups or {}) do conv:ask(fq) end

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

print(string.format("\n==== %d scenario(s) passed, %d failed ====", total_pass, total_fail))
os.exit(total_fail == 0 and 0 or 1)
