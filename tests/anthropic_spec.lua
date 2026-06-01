-- bbanthropic unit checks: request-body shaping (system-prompt assembly + the
-- rolling prompt-cache breakpoints) and the streaming parser's SSE reassembly.
-- Uses the real bbanthropic + bbprompts; only KOReader deps (rapidjson) are stubbed.
local stubs = require("support.stubs")
local sse = require("support.sse")
local json = stubs.json

local function cfg(over)
    local c = {
        model = "test",
        max_tokens = 100,
        additional_system_prompt = "",
        enable_memory = false,
        enable_thinking = false,
    }
    for k, v in pairs(over or {}) do
        c[k] = v
    end
    return c
end

describe("bbanthropic", function()
    local Anthropic

    setup(function()
        stubs.install()
        Anthropic = require("bbanthropic")
    end)

    describe("buildBody system prompt assembly", function()
        local BASE = "You are BookBuddy"
        local MEM = "persistent memory directory"
        local EXTRA = "Always answer in German."

        it("contains the built-in prompt and nothing optional by default", function()
            local body = Anthropic.buildBody({ { role = "user", content = "hi" } }, nil, cfg())
            assert.is_not_nil(body:find(BASE, 1, true))
            assert.is_nil(body:find(MEM, 1, true))
            assert.is_nil(body:find("German", 1, true))
        end)

        it("appends the memory protocol when memory is enabled", function()
            local body = Anthropic.buildBody({ { role = "user", content = "hi" } }, nil, cfg({ enable_memory = true }))
            assert.is_not_nil(body:find(MEM, 1, true))
        end)

        it("appends the additional prompt after the built-in prompt", function()
            local body = Anthropic.buildBody(
                { { role = "user", content = "hi" } },
                nil,
                cfg({ additional_system_prompt = EXTRA })
            )
            assert.is_not_nil(body:find(EXTRA, 1, true))
            assert.is_true((body:find(BASE, 1, true) or 0) < (body:find(EXTRA, 1, true) or math.huge))
        end)

        it("attaches tools only when non-empty", function()
            local none = json.decode(Anthropic.buildBody({ { role = "user", content = "hi" } }, {}, cfg()))
            assert.is_nil(none.tools)
            local some = json.decode(
                Anthropic.buildBody(
                    { { role = "user", content = "hi" } },
                    { { name = "grep", input_schema = { type = "object" } } },
                    cfg()
                )
            )
            assert.is_not_nil(some.tools)
        end)

        it("requests adaptive summarized thinking only when enabled", function()
            local off = json.decode(Anthropic.buildBody({ { role = "user", content = "hi" } }, nil, cfg()))
            assert.is_nil(off.thinking)
            local on = json.decode(
                Anthropic.buildBody({ { role = "user", content = "hi" } }, nil, cfg({ enable_thinking = true }))
            )
            assert.are.equal("adaptive", on.thinking.type)
            assert.are.equal("summarized", on.thinking.display)
        end)
    end)

    describe("rolling cache breakpoint", function()
        local function countBreakpoints(dec)
            local n = 0
            for _, b in ipairs(dec.system) do
                if b.cache_control then
                    n = n + 1
                end
            end
            for _, m in ipairs(dec.messages) do
                if type(m.content) == "table" then
                    for _, b in ipairs(m.content) do
                        if b.cache_control then
                            n = n + 1
                        end
                    end
                end
            end
            return n
        end

        it("normalizes string content and marks its last block, system stays cached", function()
            local msgs = { { role = "user", content = "hello world" } }
            local dec = json.decode(Anthropic.buildBody(msgs, nil, cfg()))
            local last = dec.messages[#dec.messages]
            assert.are.equal("table", type(last.content))
            assert.are.equal("table", type(msgs[1].content)) -- live msgs mutated in place
            local blk = last.content[#last.content]
            assert.are.equal("text", blk.type)
            assert.are.equal("hello world", blk.text)
            assert.are.equal("ephemeral", blk.cache_control.type)
            assert.are.equal("ephemeral", dec.system[1].cache_control.type)
        end)

        it("marks only the final block of a list-content last message", function()
            local msgs = {
                { role = "user", content = "hi" },
                { role = "assistant", content = { { type = "text", text = "a" }, { type = "text", text = "b" } } },
            }
            local dec = json.decode(Anthropic.buildBody(msgs, nil, cfg()))
            local last = dec.messages[#dec.messages]
            assert.are.equal("ephemeral", last.content[#last.content].cache_control.type)
            assert.is_nil(last.content[1].cache_control)
            assert.are.equal(2, countBreakpoints(dec)) -- system + last block only
        end)

        it("clears stale interior breakpoints so the count stays bounded at two", function()
            local msgs = {
                {
                    role = "user",
                    content = { { type = "text", text = "old", cache_control = { type = "ephemeral" } } },
                },
                { role = "assistant", content = { { type = "text", text = "answer" } } },
                { role = "user", content = "new question" },
            }
            local dec = json.decode(Anthropic.buildBody(msgs, nil, cfg()))
            assert.is_nil(dec.messages[1].content[1].cache_control)
            local finalContent = dec.messages[#dec.messages].content
            assert.are.equal("ephemeral", finalContent[#finalContent].cache_control.type)
            assert.are.equal(2, countBreakpoints(dec))
        end)
    end)

    describe("newStreamParser", function()
        local function parse(lines)
            local p = Anthropic.newStreamParser()
            for _, l in ipairs(lines) do
                p:feed(l)
            end
            return p:result()
        end

        it("reassembles text and reports end_turn", function()
            local res = parse(sse.buildTurnSSE({ blocks = { { type = "text", text = "Hello there." } } }))
            assert.is_true(res.ok)
            assert.are.equal("end_turn", res.stop_reason)
            assert.are.equal("text", res.content[1].type)
            assert.are.equal("Hello there.", res.content[1].text)
        end)

        it("accumulates thinking text and keeps the signature for resend", function()
            local res = parse(sse.buildTurnSSE({
                blocks = { { type = "thinking", thinking = "pondering", signature = "sig1" } },
            }))
            assert.are.equal("thinking", res.content[1].type)
            assert.are.equal("pondering", res.content[1].thinking)
            assert.are.equal("sig1", res.content[1].signature)
        end)

        it("decodes tool_use input JSON from input_json_delta", function()
            local res = parse(sse.buildTurnSSE({
                blocks = { { type = "tool_use", id = "t1", name = "grep", input = { query = "whales" } } },
                stop_reason = "tool_use",
            }))
            assert.are.equal("tool_use", res.stop_reason)
            local b = res.content[1]
            assert.are.equal("tool_use", b.type)
            assert.are.equal("grep", b.name)
            assert.are.equal("whales", b.input.query)
        end)

        it("pairs server_tool_use with its web_search_tool_result in block order", function()
            local res = parse(sse.buildTurnSSE({
                blocks = {
                    { type = "server_tool_use", id = "s1", input = { query = "q" } },
                    { type = "web_search_tool_result", tool_use_id = "s1", content = sse.webResults(2) },
                },
            }))
            assert.are.equal("server_tool_use", res.content[1].type)
            assert.are.equal("web_search_tool_result", res.content[2].type)
            assert.are.equal("s1", res.content[2].tool_use_id)
        end)

        it("extracts usage from message_start and overwrites output_tokens from message_delta", function()
            local res = parse(sse.buildTurnSSE({ blocks = { { type = "text", text = "x" } } }))
            assert.are.equal(10, res.usage.input_tokens)
            assert.are.equal(20, res.usage.output_tokens) -- message_delta running total wins
        end)

        it("surfaces a mid-stream error event as a failed result", function()
            local p = Anthropic.newStreamParser()
            p:feed("data: " .. json.encode({ type = "error", error = { type = "overloaded_error", message = "boom" } }))
            local res = p:result()
            assert.is_false(res.ok)
            assert.are.equal("boom", res.error_message)
        end)
    end)
end)
