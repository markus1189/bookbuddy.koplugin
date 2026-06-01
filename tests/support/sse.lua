-- SSE scripting + request-validation helpers for the busted suite.
--
-- `buildTurnSSE` / `webResults` script the event lines the real bbanthropic parser
-- consumes. `new_fake_stream` is a factory (per-test instance, not a module
-- singleton) that registers itself as the `bbstream` transport. `validateMessages`
-- mirrors the Vertex AI request rules. `capture_build_body` wraps Anthropic.buildBody
-- to record every outgoing request's messages.

local stubs = require("support.stubs")
local json = stubs.json
local noop = stubs.noop

local M = {}

local function deepcopy(v)
    if type(v) ~= "table" then
        return v
    end
    local t = {}
    for k, val in pairs(v) do
        t[k] = deepcopy(val)
    end
    return t
end
M.deepcopy = deepcopy

--------------------------------------------------------------------------------
-- SSE scripting helpers: build the event lines the real parser consumes.
--------------------------------------------------------------------------------
local function ev(obj)
    return "data: " .. json.encode(obj)
end

function M.buildTurnSSE(spec)
    local lines = {}
    lines[#lines + 1] = ev({
        type = "message_start",
        message = {
            usage = {
                input_tokens = 10,
                output_tokens = 0,
                cache_read_input_tokens = 0,
                cache_creation_input_tokens = 0,
            },
        },
    })
    for i, b in ipairs(spec.blocks) do
        local idx = i - 1
        if b.type == "text" then
            lines[#lines + 1] = ev({
                type = "content_block_start",
                index = idx,
                content_block = { type = "text", text = "" },
            })
            lines[#lines + 1] = ev({
                type = "content_block_delta",
                index = idx,
                delta = { type = "text_delta", text = b.text or "" },
            })
            lines[#lines + 1] = ev({ type = "content_block_stop", index = idx })
        elseif b.type == "thinking" then
            lines[#lines + 1] = ev({
                type = "content_block_start",
                index = idx,
                content_block = { type = "thinking", thinking = "" },
            })
            lines[#lines + 1] = ev({
                type = "content_block_delta",
                index = idx,
                delta = { type = "thinking_delta", thinking = b.thinking or "" },
            })
            lines[#lines + 1] = ev({
                type = "content_block_delta",
                index = idx,
                delta = { type = "signature_delta", signature = b.signature or "sig" },
            })
            lines[#lines + 1] = ev({ type = "content_block_stop", index = idx })
        elseif b.type == "server_tool_use" then
            lines[#lines + 1] = ev({
                type = "content_block_start",
                index = idx,
                content_block = { type = "server_tool_use", id = b.id, name = b.name or "web_search" },
            })
            lines[#lines + 1] = ev({
                type = "content_block_delta",
                index = idx,
                delta = { type = "input_json_delta", partial_json = json.encode(b.input or { query = "" }) },
            })
            lines[#lines + 1] = ev({ type = "content_block_stop", index = idx })
        elseif b.type == "tool_use" then
            lines[#lines + 1] = ev({
                type = "content_block_start",
                index = idx,
                content_block = { type = "tool_use", id = b.id, name = b.name },
            })
            lines[#lines + 1] = ev({
                type = "content_block_delta",
                index = idx,
                delta = { type = "input_json_delta", partial_json = json.encode(b.input or {}) },
            })
            lines[#lines + 1] = ev({ type = "content_block_stop", index = idx })
        elseif b.type == "web_search_tool_result" then
            lines[#lines + 1] = ev({
                type = "content_block_start",
                index = idx,
                content_block = { type = "web_search_tool_result", tool_use_id = b.tool_use_id, content = b.content },
            })
            lines[#lines + 1] = ev({ type = "content_block_stop", index = idx })
        else
            error("unknown block type " .. tostring(b.type))
        end
    end
    lines[#lines + 1] = ev({
        type = "message_delta",
        delta = { stop_reason = spec.stop_reason or "end_turn" },
        usage = { output_tokens = 20 },
    })
    lines[#lines + 1] = ev({ type = "message_stop" })
    return lines
end

function M.webResults(n)
    local arr = { __array = true }
    for i = 1, n do
        arr[i] = {
            type = "web_search_result",
            url = "https://example.com/" .. i,
            title = "Result " .. i,
            encrypted_content = "enc" .. i,
            page_age = "2025",
        }
    end
    return arr
end

--------------------------------------------------------------------------------
-- Fake transport: each run() pops the next scripted SSE response and feeds its
-- lines to the real parser via on_line. A factory, so each spec gets its own
-- instance; it registers itself as package.loaded["bbstream"]. Call :reset() in
-- before_each to load a fresh response list without re-requiring the loop.
--------------------------------------------------------------------------------
function M.new_fake_stream(responses)
    local fs = { responses = responses or {}, idx = 0 }
    function fs:reset(r)
        self.responses = r or {}
        self.idx = 0
    end
    -- bbconversation calls Stream.run(opts) (dot, single arg), so close over fs.
    fs.run = function(opts)
        fs.idx = fs.idx + 1
        local resp = fs.responses[fs.idx]
        if opts.register_cancel then
            opts.register_cancel(noop)
        end
        if not resp then
            if opts.register_cancel then
                opts.register_cancel(nil)
            end
            return { completed = false, cancelled = false, read_error = true }
        end
        for _, line in ipairs(resp) do
            if opts.on_line then
                opts.on_line(line)
            end
        end
        if opts.register_cancel then
            opts.register_cancel(nil)
        end
        return { completed = true, cancelled = false, read_error = false }
    end
    package.loaded["bbstream"] = fs
    return fs
end

--------------------------------------------------------------------------------
-- Capture the messages array on each outgoing request by wrapping buildBody.
-- Returns (captured, restore): `captured` is the live list appended on each call;
-- `restore()` puts the real buildBody back. Requires bbanthropic, so install the
-- stubs first.
--------------------------------------------------------------------------------
function M.capture_build_body()
    local Anthropic = require("bbanthropic")
    local captured = {}
    local real = Anthropic.buildBody
    Anthropic.buildBody = function(messages, tools)
        captured[#captured + 1] = { messages = deepcopy(messages), tools = tools and #tools or 0 }
        return "" -- body is unused by the fake stream
    end
    return captured, function()
        Anthropic.buildBody = real
    end
end

--------------------------------------------------------------------------------
-- Validator: mirror the Vertex AI request rules.
--------------------------------------------------------------------------------
function M.validateMessages(messages)
    local errs = {}
    if messages[1] and messages[1].role ~= "user" then
        errs[#errs + 1] = "messages.0: first message must have role user"
    end
    -- Role alternation: two consecutive same-role messages are rejected.
    for i = 2, #messages do
        if messages[i].role == messages[i - 1].role then
            errs[#errs + 1] = string.format(
                "messages.%d: roles must alternate (this and messages.%d are both '%s')",
                i - 1,
                i - 2,
                messages[i].role
            )
        end
    end
    for i = 1, #messages do
        local m = messages[i]
        local mi = i - 1
        if m.role == "assistant" and type(m.content) == "table" then
            local results, servertools = {}, {}
            for _, b in ipairs(m.content) do
                if b.type == "web_search_tool_result" and b.tool_use_id then
                    results[b.tool_use_id] = true
                end
                if b.type == "server_tool_use" and b.id then
                    servertools[b.id] = true
                end
            end
            for _, b in ipairs(m.content) do
                if b.type == "server_tool_use" and b.name == "web_search" and not results[b.id] then
                    errs[#errs + 1] = string.format(
                        "messages.%d: `web_search` tool use with id `%s` was found without a corresponding `web_search_tool_result` block",
                        mi,
                        tostring(b.id)
                    )
                end
                if b.type == "web_search_tool_result" and not servertools[b.tool_use_id] then
                    errs[#errs + 1] = string.format(
                        "messages.%d: `web_search_tool_result` with tool_use_id `%s` has no corresponding `server_tool_use` block",
                        mi,
                        tostring(b.tool_use_id)
                    )
                end
            end
        end
        -- Client tool_use must be answered by tool_result in the next user message.
        if m.role == "assistant" and type(m.content) == "table" then
            local pending = {}
            for _, b in ipairs(m.content) do
                if b.type == "tool_use" then
                    pending[b.id] = true
                end
            end
            if next(pending) then
                local answered = {}
                local nxt = messages[i + 1]
                if nxt and nxt.role == "user" and type(nxt.content) == "table" then
                    for _, b in ipairs(nxt.content) do
                        if b.type == "tool_result" and b.tool_use_id then
                            answered[b.tool_use_id] = true
                        end
                    end
                end
                for id in pairs(pending) do
                    if not answered[id] then
                        errs[#errs + 1] = string.format(
                            "messages.%d: tool_use `%s` has no tool_result in the following user message",
                            mi,
                            id
                        )
                    end
                end
            end
        end
    end
    return errs
end

return M
