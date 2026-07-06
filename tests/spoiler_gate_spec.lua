-- The spoiler confirmation gate: a client tool call that asks to look past the
-- reader's current position (grep/read spoiler=true, delegate allow_spoiler=true)
-- must be approved by the READER before it runs (bbconversation._confirmSpoiler).
-- Driven through the real bbconversation with scripted SSE, like the ask_user spec:
-- the ButtonDialog double fires a scripted choice through the same nextTick pump
-- Trapper:wrap drains, so a whole confirm-then-answer turn completes synchronously
-- inside conv:ask().
local stubs = require("support.stubs")
local sse = require("support.sse")

describe("spoiler confirmation gate", function()
    local Conversation, fake, captured, chatviewer, tools, subrec
    -- Per-test dialog script: autofire(o) is called on the next tick after a spoiler
    -- dialog is shown, simulating the reader's tap. dialog_count tracks how many
    -- confirmation dialogs were actually shown (ButtonDialog backs only this gate and
    -- ask_user, and these scenarios never emit ask_user).
    local autofire
    local dialog_count = { n = 0 }

    local cfg = {}
    local stubSettings = {
        getConfig = function()
            return cfg
        end,
    }

    setup(function()
        local h = stubs.install()
        chatviewer = h.chatviewer
        stubs.install_bbmemory_stub()
        -- bbconversation now requires bbchats (chat persistence), whose real module
        -- pulls in KOReader's docsettings. Swap in the recording double so the real
        -- module never loads; this spec asserts nothing about persistence.
        stubs.install_bbchats_stub()
        tools = stubs.install_bbtools_stub(h)

        -- A bbsubagents double for the delegate scenarios: records the driver opts so
        -- the spec can assert whether (and with what allow_spoiler) the child ran.
        subrec = { calls = {} }
        package.loaded["bbsubagents"] = {
            runSubagent = function(o)
                subrec.calls[#subrec.calls + 1] = o
                return "CHILD_ANSWER", nil
            end,
        }

        -- Dialog double that drives _confirmSpoiler to completion through the nextTick
        -- pump (same idiom as the ask_user spec): construction schedules the scripted
        -- tap, which runs while Trapper:wrap is still draining.
        local UIManager = package.loaded["ui/uimanager"]
        package.loaded["ui/widget/buttondialog"] = {
            new = function(_, o)
                o = o or {}
                dialog_count.n = dialog_count.n + 1
                UIManager:nextTick(function()
                    if autofire then
                        autofire(o)
                    end
                end)
                return o
            end,
        }

        fake = sse.new_fake_stream({}, chatviewer)
        captured = (sse.capture_build_body())
        -- Fresh load so bbconversation captures the counting dialog double above, not
        -- a copy cached by another spec (whose plain echo stub would never resolve the
        -- dialog and park the loop forever).
        package.loaded["bbconversation"] = nil
        Conversation = require("bbconversation")
    end)

    local function clear(t)
        for i = #t, 1, -1 do
            t[i] = nil
        end
    end

    -- Buttons in _confirmSpoiler's dialog: one per row, in this order.
    local ALLOW_ONCE, ALLOW_CHAT, DENY = 1, 2, 3
    local function tap(row)
        return function(o)
            o.buttons[row][1].callback()
        end
    end

    -- Run one scenario over scripted SSE responses. Asserts the universal invariants
    -- (every request validates; the loop never over-requests) like conversation_spec.
    local function run(opts)
        autofire = opts.fire
        clear(captured)
        clear(tools.state.calls)
        subrec.calls = {}
        dialog_count.n = 0
        chatviewer.last_text = nil
        cfg.base_url, cfg.api_key, cfg.model, cfg.max_tokens = "https://example", "k", "test", 1024
        cfg.max_turns = 20
        cfg.additional_system_prompt = ""
        cfg.enable_memory, cfg.enable_thinking, cfg.show_streaming_thinking = false, false, false
        cfg.enable_web_search = true
        -- The resolved config always carries an explicit boolean (bbsettings coalesces
        -- nil to true); mirror that here so the gate sees what production sees.
        cfg.confirm_spoilers = opts.confirm_spoilers ~= false

        fake:reset(opts.responses)
        local conv = Conversation:new({ ui = {}, settings = stubSettings, selected_text = "the passage" })
        conv:ask("What happens to him later?")

        for n, req in ipairs(captured) do
            assert.are.equal(0, #sse.validateMessages(req.messages), "request " .. n .. " was invalid")
        end
        assert.is_true(fake.idx <= #opts.responses, "loop requested more responses than were scripted")
        return conv
    end

    -- The tool_result content the loop committed for the given tool_use id.
    local function resultOf(conv, id)
        for _, m in ipairs(conv.messages) do
            if m.role == "user" and type(m.content) == "table" then
                for _, b in ipairs(m.content) do
                    if b.type == "tool_result" and b.tool_use_id == id then
                        return b.content
                    end
                end
            end
        end
    end

    -- One spoiler read round then a final text turn.
    local function spoilerReadTurns()
        return {
            sse.buildTurnSSE({
                blocks = {
                    { type = "tool_use", id = "toolu_S1", name = "read", input = { from = 150, spoiler = true } },
                },
                stop_reason = "tool_use",
            }),
            sse.buildTurnSSE({ blocks = { { type = "text", text = "Here is what happens." } } }),
        }
    end

    it("runs the tool with spoilers intact when the reader taps Allow once", function()
        local conv = run({ responses = spoilerReadTurns(), fire = tap(ALLOW_ONCE) })
        assert.are.equal(1, dialog_count.n)
        assert.are.equal(1, #tools.state.calls)
        assert.are.equal("read", tools.state.calls[1].name)
        assert.is_true(tools.state.calls[1].input.spoiler) -- the input is NOT clamped on approval
        assert.are.equal("TOOL_RESULT(read)", resultOf(conv, "toolu_S1"))
        assert.is_false(conv.spoiler_approved) -- once is once: no chat-wide latch
    end)

    it("asks again on the next spoiler request after an Allow once", function()
        run({
            responses = {
                sse.buildTurnSSE({
                    blocks = {
                        { type = "tool_use", id = "toolu_S1", name = "read", input = { from = 150, spoiler = true } },
                    },
                    stop_reason = "tool_use",
                }),
                sse.buildTurnSSE({
                    blocks = {
                        { type = "tool_use", id = "toolu_S2", name = "grep", input = { query = "x", spoiler = true } },
                    },
                    stop_reason = "tool_use",
                }),
                sse.buildTurnSSE({ blocks = { { type = "text", text = "Done." } } }),
            },
            fire = tap(ALLOW_ONCE),
        })
        assert.are.equal(2, dialog_count.n)
        assert.are.equal(2, #tools.state.calls)
    end)

    it("latches approval for the whole conversation on Allow for this conversation", function()
        local conv = run({
            responses = {
                sse.buildTurnSSE({
                    blocks = {
                        { type = "tool_use", id = "toolu_S1", name = "read", input = { from = 150, spoiler = true } },
                    },
                    stop_reason = "tool_use",
                }),
                sse.buildTurnSSE({
                    blocks = {
                        { type = "tool_use", id = "toolu_S2", name = "grep", input = { query = "x", spoiler = true } },
                    },
                    stop_reason = "tool_use",
                }),
                sse.buildTurnSSE({ blocks = { { type = "text", text = "Done." } } }),
            },
            fire = tap(ALLOW_CHAT),
        })
        assert.are.equal(1, dialog_count.n) -- the second spoiler round passed silently
        assert.are.equal(2, #tools.state.calls)
        assert.is_true(conv.spoiler_approved)
    end)

    it("refuses the tool and hands the model a recoverable note when the reader denies", function()
        local conv = run({ responses = spoilerReadTurns(), fire = tap(DENY) })
        assert.are.equal(1, dialog_count.n)
        assert.are.equal(0, #tools.state.calls) -- the read never ran
        local note = resultOf(conv, "toolu_S1")
        assert.is_not_nil(tostring(note):find("declined", 1, true))
        assert.are.equal(2, fake.idx, "the loop must continue to the final turn after a denial")
        -- The reader sees the refusal folded into the tool line.
        assert.is_not_nil((chatviewer.last_text or ""):find("not allowed", 1, true))
        assert.are.equal(0, #sse.validateMessages(conv.messages))
    end)

    it("treats a bare dismissal as a denial and does NOT hang (no-hang invariant)", function()
        local conv = run({
            responses = spoilerReadTurns(),
            fire = function(o)
                o.onCloseWidget(o) -- tap-outside / Back, no button callback
            end,
        })
        assert.are.equal(2, fake.idx, "the loop must resume after a bare dismissal, not park forever")
        assert.are.equal(0, #tools.state.calls)
        assert.is_not_nil(tostring(resultOf(conv, "toolu_S1")):find("declined", 1, true))
    end)

    it("does not prompt at all when Confirm spoilers is off in settings", function()
        run({ responses = spoilerReadTurns(), fire = tap(DENY), confirm_spoilers = false })
        assert.are.equal(0, dialog_count.n)
        assert.are.equal(1, #tools.state.calls)
        assert.is_true(tools.state.calls[1].input.spoiler)
    end)

    it("never prompts for a tool call that stays spoiler-safe", function()
        run({
            responses = {
                sse.buildTurnSSE({
                    blocks = {
                        { type = "tool_use", id = "toolu_S1", name = "grep", input = { query = "whales" } },
                    },
                    stop_reason = "tool_use",
                }),
                sse.buildTurnSSE({ blocks = { { type = "text", text = "Found it." } } }),
            },
            fire = tap(DENY), -- would deny if a dialog ever appeared
        })
        assert.are.equal(0, dialog_count.n)
        assert.are.equal(1, #tools.state.calls)
    end)

    it("gates delegate allow_spoiler: denial never starts the child", function()
        local conv = run({
            responses = {
                sse.buildTurnSSE({
                    blocks = {
                        {
                            type = "tool_use",
                            id = "toolu_D1",
                            name = "delegate",
                            input = { task = "trace him", allow_spoiler = true },
                        },
                    },
                    stop_reason = "tool_use",
                }),
                sse.buildTurnSSE({ blocks = { { type = "text", text = "Staying spoiler-free then." } } }),
            },
            fire = tap(DENY),
        })
        assert.are.equal(1, dialog_count.n)
        assert.are.equal(0, #subrec.calls)
        assert.is_not_nil(tostring(resultOf(conv, "toolu_D1")):find("declined", 1, true))
    end)

    it("gates delegate allow_spoiler: approval runs the child with the clamp relaxed", function()
        local conv = run({
            responses = {
                sse.buildTurnSSE({
                    blocks = {
                        {
                            type = "tool_use",
                            id = "toolu_D1",
                            name = "delegate",
                            input = { task = "trace him", allow_spoiler = true },
                        },
                    },
                    stop_reason = "tool_use",
                }),
                sse.buildTurnSSE({ blocks = { { type = "text", text = "Here is his arc." } } }),
            },
            fire = tap(ALLOW_ONCE),
        })
        assert.are.equal(1, #subrec.calls)
        assert.is_true(subrec.calls[1].allow_spoiler)
        assert.are.equal("CHILD_ANSWER", resultOf(conv, "toolu_D1"))
    end)

    it("a delegate WITHOUT allow_spoiler never prompts", function()
        run({
            responses = {
                sse.buildTurnSSE({
                    blocks = {
                        { type = "tool_use", id = "toolu_D1", name = "delegate", input = { task = "trace him" } },
                    },
                    stop_reason = "tool_use",
                }),
                sse.buildTurnSSE({ blocks = { { type = "text", text = "Done." } } }),
            },
            fire = tap(DENY),
        })
        assert.are.equal(0, dialog_count.n)
        assert.are.equal(1, #subrec.calls)
    end)
end)
