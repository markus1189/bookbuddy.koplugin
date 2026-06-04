-- Meta-tests for the request validator. Every conversation scenario trusts
-- sse.validateMessages to catch 400-worthy message arrays; without these, a
-- validator that silently degraded to `return {}` would let the whole suite
-- keep reporting green while the safety net had a hole in it.
local sse = require("support.sse")

local function errs(messages)
    return sse.validateMessages(messages)
end

describe("request validator", function()
    it("accepts a clean, fully-paired exchange (no false positives)", function()
        assert.are.equal(0, #errs({
            { role = "user", content = "hi" },
            {
                role = "assistant",
                content = {
                    { type = "text", text = "let me look" },
                    { type = "server_tool_use", id = "s1", name = "web_search" },
                    { type = "web_search_tool_result", tool_use_id = "s1", content = {} },
                    { type = "tool_use", id = "t1", name = "grep" },
                },
            },
            {
                role = "user",
                content = {
                    { type = "tool_result", tool_use_id = "t1", content = "ok" },
                },
            },
        }))
    end)

    it("rejects a first message that is not user", function()
        assert.is_true(#errs({ { role = "assistant", content = "x" } }) > 0)
    end)

    it("rejects two user messages in a row", function()
        assert.is_true(#errs({
            { role = "user", content = "a" },
            { role = "user", content = "b" },
        }) > 0)
    end)

    it("rejects a server_tool_use with no web_search_tool_result", function()
        assert.is_true(#errs({
            { role = "user", content = "hi" },
            {
                role = "assistant",
                content = { { type = "server_tool_use", id = "s1", name = "web_search" } },
            },
        }) > 0)
    end)

    it("rejects an orphan server_tool_use regardless of its name", function()
        -- The source's dangling check (pairDanglingWebSearch / _dropDanglingTail) keys on
        -- type+id, not name, so the validator must flag any unpaired server_tool_use.
        assert.is_true(#errs({
            { role = "user", content = "hi" },
            {
                role = "assistant",
                content = { { type = "server_tool_use", id = "s9", name = "code_execution" } },
            },
        }) > 0)
    end)

    it("rejects a web_search_tool_result with no server_tool_use", function()
        assert.is_true(#errs({
            { role = "user", content = "hi" },
            {
                role = "assistant",
                content = { { type = "web_search_tool_result", tool_use_id = "ghost", content = {} } },
            },
        }) > 0)
    end)

    it("rejects a client tool_use with no following tool_result", function()
        assert.is_true(#errs({
            { role = "user", content = "hi" },
            { role = "assistant", content = { { type = "tool_use", id = "t1", name = "grep" } } },
        }) > 0)
    end)
end)
