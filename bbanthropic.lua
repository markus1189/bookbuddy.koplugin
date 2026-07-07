-- Anthropic Messages API client (streaming) against a configurable endpoint.
-- buildBody/decode run in the main process (rapidjson keeps the object/array
-- distinction across decode→encode so tool_use inputs round-trip correctly).
-- streamChildFn() returns a closure meant to run inside a forked subprocess: it
-- touches no UI or document state and pumps the raw SSE bytes to a pipe.
-- newStreamParser() runs in the parent and reassembles those bytes into the same
-- shape decode() would have produced for a non-streaming reply, so the tool loop
-- in bbconversation does not care that the response arrived incrementally.

local Prompts = require("bbprompts")

local ANTHROPIC_VERSION = "2023-06-01"

-- Sentinels the child writes to the pipe after the request finishes, so the
-- parent can tell a streamed 200 apart from a transport/HTTP failure.
local NON_200_MARKER = "X-BB-NON-200:"
local NETWORK_ERROR_MARKER = "X-BB-NETWORK-ERROR:"

local Anthropic = {}

function Anthropic.buildBody(messages, tool_specs, cfg)
    local rapidjson = require("rapidjson")
    -- BookBuddy's built-in prompt is the base; the memory protocol and the
    -- reader's optional additional prompt are appended to it, in that order.
    local system_text = Prompts.SYSTEM_PROMPT
    if cfg.enable_memory then
        system_text = system_text .. "\n\n" .. Prompts.MEMORY_PROTOCOL
    end
    -- Only tell the parent about delegating when the feature is on -- the delegate
    -- tool is otherwise stripped from the specs (Conversation:new), so mentioning it
    -- would advertise a tool that isn't there.
    if cfg.enable_subagents then
        system_text = system_text .. "\n\n" .. Prompts.DELEGATE_NOTE
    end
    -- Tell the model about ask_user only when the tool is actually advertised. The tool
    -- is on by default, so a nil (never-set) flag must read as enabled, matching the
    -- enable_clarifying_questions resolution in bbsettings:getConfig and the spec strip
    -- in Conversation:new (only an explicit false removes it).
    if cfg.enable_clarifying_questions ~= false then
        system_text = system_text .. "\n\n" .. Prompts.ASK_USER_NOTE
    end
    local extra = cfg.additional_system_prompt
    if extra and extra ~= "" then
        system_text = system_text .. "\n\n<additional_system_prompt>\n" .. extra .. "\n</additional_system_prompt>"
    end
    local body = {
        model = cfg.model,
        max_tokens = cfg.max_tokens,
        stream = true,
        system = {
            {
                type = "text",
                text = system_text,
                cache_control = { type = "ephemeral" },
            },
        },
        messages = messages,
    }
    if tool_specs and #tool_specs > 0 then
        body.tools = tool_specs
    end
    -- Adaptive thinking is the only supported mode on Opus 4.8 (a fixed
    -- budget_tokens 400s there), and it interleaves thinking between tool calls
    -- on its own. display="summarized" is required to get any thinking text:
    -- the default omits it, which would leave the live "Thinking" view empty.
    if cfg.enable_thinking then
        body.thinking = { type = "adaptive", display = "summarized" }
    end
    -- Rolling prompt-cache breakpoint: mark the last block of the last message
    -- as ephemeral so prior history is served as cache_read, not full input on
    -- the next turn. Clear any stale message-block breakpoints first so the count
    -- stays bounded (the system block carries the only other breakpoint).
    if messages and #messages > 0 then
        for _, msg in ipairs(messages) do
            if type(msg.content) == "table" then
                for _, block in ipairs(msg.content) do
                    if type(block) == "table" then
                        block.cache_control = nil
                    end
                end
            end
        end

        local last_msg = messages[#messages]
        local content = last_msg.content
        if type(content) == "string" then
            content = { { type = "text", text = content } }
            last_msg.content = content
        end
        if type(content) == "table" and #content > 0 then
            content[#content].cache_control = { type = "ephemeral" }
        end
    end

    return rapidjson.encode(body)
end

function Anthropic.decode(body)
    if not body or body == "" then
        return nil
    end
    local rapidjson = require("rapidjson")
    local ok, result = pcall(rapidjson.decode, body)
    if ok and type(result) == "table" then
        return result
    end
    return nil
end

-- Returns a function(pid, child_write_fd) to run via ffiutil.runInSubProcess.
-- It performs the POST and streams the response body straight to the pipe; the
-- parent parses the SSE. On a non-200 the gateway returns a plain JSON error body
-- (not SSE), which still streams through; we then append a marker carrying the
-- HTTP status because http.request only reports the code once the body is done.
function Anthropic.streamChildFn(body_json, cfg)
    return function(_pid, child_write_fd)
        local http = require("socket.http")
        local ltn12 = require("ltn12")
        local socket = require("socket")
        local socketutil = require("socketutil")
        local ffi = require("ffi")
        local ffiutil = require("ffi/util")

        -- ltn12 sink that forwards each chunk to the pipe. close is a no-op: we
        -- keep the fd open to append a status marker, then close it by hand.
        local pipe = {
            write = function(self, chunk)
                if chunk then
                    ffiutil.writeToFD(child_write_fd, chunk)
                end
                return self
            end,
            close = function()
                return true
            end,
        }

        local headers = {
            ["content-type"] = "application/json",
            ["accept"] = "text/event-stream",
            ["anthropic-version"] = ANTHROPIC_VERSION,
            -- Send the key both ways so any Claude-compatible endpoint authenticates:
            -- gateways (OpenRouter, Requesty) read Authorization: Bearer and ignore the
            -- extra x-api-key; native api.anthropic.com requires x-api-key and rejects a
            -- Bearer token. All three return 200 with both present. The key never leaves cfg.
            ["x-api-key"] = cfg.api_key,
            ["authorization"] = "Bearer " .. (cfg.api_key or ""),
            ["content-length"] = tostring(#body_json),
        }

        -- Block (between-chunk) timeout only; no total cap, since a long reply can
        -- legitimately stream for minutes. The user cancels via the Stop button.
        socketutil:set_timeout(120, -1)
        local code, resp_headers = socket.skip(
            1,
            http.request({
                url = cfg.base_url .. "/v1/messages",
                method = "POST",
                headers = headers,
                source = ltn12.source.string(body_json),
                sink = ltn12.sink.file(pipe),
            })
        )
        socketutil:reset_timeout()

        if resp_headers == nil then
            ffiutil.writeToFD(child_write_fd, "\n" .. NETWORK_ERROR_MARKER .. "\n")
        elseif code ~= 200 then
            ffiutil.writeToFD(child_write_fd, string.format("\n%s %s\n", NON_200_MARKER, tostring(code)))
        end
        ffi.C.close(child_write_fd)
    end
end

local Parser = {}
Parser.__index = Parser

-- o.on_text(delta): optional, called with each text fragment as it arrives.
-- o.on_thinking(delta): optional, called with each summarized-thinking fragment.
function Anthropic.newStreamParser(o)
    o = o or {}
    return setmetatable({
        on_text = o.on_text,
        on_thinking = o.on_thinking,
        blocks = {}, -- index (0-based) -> content block table
        json_accum = {}, -- index -> accumulated tool_use input JSON string
        max_index = -1,
        stop_reason = nil,
        -- Anthropic-shaped so bbconversation's existing accumulation works as-is.
        usage = {
            input_tokens = 0,
            output_tokens = 0,
            cache_read_input_tokens = 0,
            cache_creation_input_tokens = 0,
        },
        error = nil, -- mid-stream error event { type, message }
        non200 = false,
        network_error = false,
        code = nil,
        error_body = {}, -- buffered raw JSON lines of a non-200 body
        -- Set when a tool_use/server_tool_use input JSON failed to decode in
        -- content_block_stop. Distinct from done==false (a stream that ended
        -- without message_stop): both mean "do not trust the partial blocks".
        incomplete = false,
        done = false,
    }, Parser)
end

-- Coerce a usage field to a number. A non-Anthropic endpoint may send a token
-- count as JSON null, which rapidjson decodes to a userdata sentinel (truthy, so
-- `x or 0` keeps it); arithmetic on it later then throws. Anything that is not a
-- Lua number — null sentinel, missing, string — becomes 0.
local function numOr0(v)
    return type(v) == "number" and v or 0
end

local function data_payload(line)
    if line:sub(1, 5) ~= "data:" then
        return nil
    end
    return (line:sub(6):gsub("^%s+", ""))
end

-- Merge a usage object into the running totals, keeping the max numeric value
-- per field. Where the authoritative counts live depends on the backend: native
-- Anthropic puts input/cache in message_start and the output total in
-- message_delta, while gateways (OpenRouter, Requesty — both observed routing via
-- Bedrock) send a stub-zero (OpenRouter: null) usage in message_start and the real
-- input/cache/output only in message_delta. Reading just one event drops the real
-- numbers on one side or the other. These counts are monotonic for a single call
-- (stub 0 → real value), and a field absent from one event coerces to 0, so the
-- per-field max coalesces both shapes without having to know which backend we hit.
function Parser:_mergeUsage(u)
    if type(u) ~= "table" then
        return
    end
    local fields = { "input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens" }
    for _, f in ipairs(fields) do
        local v = numOr0(u[f])
        if v > self.usage[f] then
            self.usage[f] = v
        end
    end
end

-- luacheck: push
-- luacheck: max cyclomatic complexity 37 (grandfathered; see .luacheckrc)
function Parser:_event(event)
    local t = event.type
    if t == "message_start" then
        self:_mergeUsage(event.message and event.message.usage)
    elseif t == "content_block_start" then
        local idx = event.index
        self.blocks[idx] = event.content_block
        if idx > self.max_index then
            self.max_index = idx
        end
        local bt = event.content_block and event.content_block.type
        if bt == "tool_use" or bt == "server_tool_use" then
            self.json_accum[idx] = ""
        end
    elseif t == "content_block_delta" then
        local idx = event.index
        local d = event.delta
        if d then
            if d.type == "text_delta" and d.text then
                local b = self.blocks[idx]
                if b then
                    b.text = (b.text or "") .. d.text
                end
                if self.on_text then
                    self.on_text(d.text)
                end
            elseif d.type == "thinking_delta" and d.thinking then
                local b = self.blocks[idx]
                if b then
                    b.thinking = (b.thinking or "") .. d.thinking
                end
                if self.on_thinking then
                    self.on_thinking(d.thinking)
                end
            elseif d.type == "signature_delta" and d.signature then
                -- Accumulate onto the thinking block; the API requires the
                -- signature back verbatim when the turn's thinking is resent
                -- alongside tool_use, so it must survive in self.blocks[idx].
                local b = self.blocks[idx]
                if b then
                    b.signature = (b.signature or "") .. d.signature
                end
            elseif d.type == "input_json_delta" and d.partial_json then
                self.json_accum[idx] = (self.json_accum[idx] or "") .. d.partial_json
            end
        end
    elseif t == "content_block_stop" then
        local idx = event.index
        local accum = self.json_accum[idx]
        if accum and #accum > 0 then
            local decoded = Anthropic.decode(accum)
            if decoded and self.blocks[idx] then
                self.blocks[idx].input = decoded
            else
                -- A tool_use / server_tool_use whose input JSON we accumulated but
                -- could not decode is truncated or corrupt: storing the block with
                -- no .input would resend a malformed tool call (the API 400s, and a
                -- client tool here would execute with nil args). Flag the whole
                -- result incomplete so result() reports a retryable failure instead
                -- of handing back a half-formed block as if the turn succeeded.
                self.incomplete = true
            end
        end
    elseif t == "message_delta" then
        if event.delta and event.delta.stop_reason then
            self.stop_reason = event.delta.stop_reason
        end
        self:_mergeUsage(event.usage)
    elseif t == "error" then
        self.error = event.error
    elseif t == "message_stop" then
        self.done = true
    end
end
-- luacheck: pop

function Parser:feed(line)
    if self.done then
        return
    end
    local payload = data_payload(line)
    if payload then
        if payload == "[DONE]" then
            self.done = true
            return
        end
        local event = Anthropic.decode(payload)
        if event and event.type then
            self:_event(event)
        end
        return
    end
    if line:sub(1, 6) == "event:" or line:sub(1, 1) == ":" then
        return -- SSE event-name / comment line
    end
    if line:sub(1, #NON_200_MARKER) == NON_200_MARKER then
        self.non200 = true
        self.code = tonumber((line:sub(#NON_200_MARKER + 1):gsub("%s", "")))
        return
    end
    if line:sub(1, #NETWORK_ERROR_MARKER) == NETWORK_ERROR_MARKER then
        self.network_error = true
        return
    end
    -- Anything else with content is part of a non-200 JSON error body.
    if line:gsub("%s", "") ~= "" then
        self.error_body[#self.error_body + 1] = line
    end
end

-- Returns the reassembled reply, shaped like a decoded non-streaming response:
--   success: { ok=true, content=<blocks>, stop_reason, usage }
--   failure: { ok=false, network_error?, code?, error_message?, error_body? }
function Parser:result()
    if self.network_error then
        return { ok = false, network_error = true, code = self.code }
    end
    if self.non200 then
        local raw = table.concat(self.error_body)
        local data = Anthropic.decode(raw)
        local msg = data and data.error and data.error.message
        -- Gateways routinely bury the actionable validation detail in a nested
        -- field (e.g. OpenRouter's error.metadata.raw names the offending
        -- tools.N.type) while error.message stays generic ("Invalid Anthropic
        -- Messages API request"). Keep the whole raw body so the log can show it.
        return { ok = false, code = self.code, error_message = msg, error_body = (raw ~= "" and raw) or nil }
    end
    if self.error then
        -- Keep the error type alongside the message: the conversation loop's retry
        -- classifier keys on it (overloaded_error/api_error/rate_limit_error retry,
        -- everything else is terminal).
        return { ok = false, error_message = self.error.message or self.error.type, error_type = self.error.type }
    end
    -- The transport delivered a clean 200 but the SSE never reached its terminal
    -- marker (message_stop / [DONE], which set self.done at _event/feed), or a tool
    -- input failed to decode (self.incomplete). Either way the accumulated blocks
    -- are a truncated turn: returning ok=true here would store a partial assistant
    -- message that the next request resends as if complete. Report incomplete so the
    -- caller's retry loop re-forks instead of committing the fragment. Ordered after
    -- the network/non200/error guards so a real failure keeps its specific shape.
    if not self.done or self.incomplete then
        return { ok = false, incomplete = true }
    end
    local content = {}
    for i = 0, self.max_index do
        if self.blocks[i] then
            content[#content + 1] = self.blocks[i]
        end
    end
    return {
        ok = true,
        content = content,
        stop_reason = self.stop_reason,
        usage = self.usage,
    }
end

return Anthropic
