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

-- An R3 "incomplete" stream: a clean-looking 200 whose SSE is truncated before its
-- terminal message_stop / [DONE], so the parser never sets self.done and result()
-- reports { ok=false, incomplete=true }. Built by dropping the trailing message_stop
-- line buildTurnSSE appends (it is always last), leaving message_start + blocks +
-- message_delta. The conversation loop classifies this as retryable (R3).
function M.incompleteTurnSSE(spec)
    local lines = M.buildTurnSSE(spec)
    -- buildTurnSSE always appends message_stop last; drop it to truncate the stream.
    lines[#lines] = nil
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
--
-- A scripted response is normally a list of SSE lines (an array). To script the
-- per-attempt transport OUTCOMES the R1 retry loop classifies, a response may
-- instead be a control descriptor table (recognised by its `outcome` field):
--   { outcome = "read_error" }  -> Stream.run returns read_error=true (retryable,
--                                  R4's stall watchdog / a transport drop). on_line
--                                  is never called, mirroring a real fork that died
--                                  before any line arrived.
--   { outcome = "network_error" } -> the child wrote the X-BB-NETWORK-ERROR marker
--                                  then closed cleanly (connection refused/reset, DNS/
--                                  TLS failure, block-timeout). Stream.run completes
--                                  (no read_error); the parser :result() reports
--                                  { ok=false, network_error=true }. Retryable, same
--                                  transient class as read_error.
--   { outcome = "read_error", stop_after = true } -> a read_error (retryable) that
--                                  ALSO fires the chat-viewer's captured on_stop just
--                                  before returning, modelling a Stop tapped while the
--                                  loop is backing off between attempts. on_stop sets
--                                  stop_requested (no live stream to _cancel during a
--                                  backoff), which the loop's post-backoff guard picks
--                                  up to abort instead of consuming the retry.
--   { outcome = "cancelled" }   -> a user Stop landed on the LIVE stream: the fake
--                                  invokes the registered cancel closure (so the
--                                  conversation's on_stop runs, setting stop_requested
--                                  + _cancel) and returns cancelled=true, exactly as
--                                  Stream.run does when its cancel resume fires. An
--                                  optional `lines` array is fed first, modelling a
--                                  Stop part-way through a partially streamed reply.
-- This keeps every existing spec (plain line-arrays) untouched.
--------------------------------------------------------------------------------
-- `chatviewer` (optional): the stubs.install() chat-viewer double, needed only by
-- the `{ outcome = "cancelled" }` descriptor so it can fire the live Stop path.
function M.new_fake_stream(responses, chatviewer)
    local fs = { responses = responses or {}, idx = 0, _chatviewer = chatviewer }
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
        -- Out of scripted responses: behave like a fork that produced nothing
        -- (read_error). Real specs never reach here -- run()'s invariant asserts it.
        if not resp then
            if opts.register_cancel then
                opts.register_cancel(nil)
            end
            return { completed = false, cancelled = false, read_error = true }
        end
        -- Control descriptor: script a non-200/transport-level outcome instead of
        -- a clean streamed 200.
        if type(resp) == "table" and resp.outcome then
            if resp.outcome == "read_error" then
                -- Optionally fire a Stop just before the read_error returns: the loop
                -- will then classify retry and back off, and the buffered Stop (set
                -- here on stop_requested) aborts in the post-backoff guard rather than
                -- consuming another attempt. _cancel is still the no-op registered
                -- above, so on_stop calling it is harmless.
                if resp.stop_after then
                    local cv = fs._chatviewer
                    if cv and cv.last_on_stop then
                        cv.last_on_stop()
                    end
                end
                if opts.register_cancel then
                    opts.register_cancel(nil)
                end
                return { completed = false, cancelled = false, read_error = true }
            elseif resp.outcome == "network_error" then
                -- The child wrote the marker then closed cleanly: feed the marker line
                -- to the real parser (so :result() reports network_error) and return a
                -- completed run with NO read_error, exactly as Stream.run does on EOF.
                if opts.on_line then
                    opts.on_line("X-BB-NETWORK-ERROR:")
                end
                if opts.register_cancel then
                    opts.register_cancel(nil)
                end
                return { completed = true, cancelled = false, read_error = false }
            elseif resp.outcome == "cancelled" then
                -- Feed any partial lines the reader saw before Stopping.
                for _, line in ipairs(resp.lines or {}) do
                    if opts.on_line then
                        opts.on_line(line)
                    end
                end
                -- Model a Stop tapped DURING the live stream: fire the chat-viewer's
                -- captured on_stop (the real Stop-button path), which sets
                -- stop_requested and, because a stream is live, calls the conversation's
                -- _cancel. Then report cancelled exactly as Stream.run's cancel branch
                -- does. The viewer double is reachable via the handle passed to the
                -- factory; fall back to no-op if a spec didn't provide one.
                local cv = fs._chatviewer
                if cv and cv.last_on_stop then
                    cv.last_on_stop()
                end
                if opts.register_cancel then
                    opts.register_cancel(nil)
                end
                return { completed = false, cancelled = true, read_error = false }
            else
                error("unknown fake-stream outcome " .. tostring(resp.outcome))
            end
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
                -- Name-agnostic, mirroring the source: pairDanglingWebSearch and
                -- _dropDanglingTail key on type+id only, so ANY orphan server_tool_use is
                -- a 400 risk on Vertex, not just one named web_search.
                if b.type == "server_tool_use" and b.id and not results[b.id] then
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
