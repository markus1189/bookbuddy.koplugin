-- The conversation loop, driven by scripted SSE through the real bbconversation
-- + bbanthropic. Ports the harness scenarios S1-S9 (request shape, pause_turn
-- resume, tool pairing, stop-during-tool, error recovery) plus the pure
-- _toolActionPhrase and stripMarkdown unit checks. Tools/memory are doubles;
-- real document tool execution is Tier 2.
local stubs = require("support.stubs")
local sse = require("support.sse")

describe("conversation", function()
    local Conversation, fake, captured, chatviewer, bbtools, mem
    local cfg = {}
    local stubSettings = {
        getConfig = function()
            return cfg
        end,
    }

    setup(function()
        local h = stubs.install()
        chatviewer = h.chatviewer
        mem = stubs.install_bbmemory_stub()
        bbtools = stubs.install_bbtools_stub(h)
        fake = sse.new_fake_stream({}, chatviewer)
        captured = (sse.capture_build_body())
        Conversation = require("bbconversation")
    end)

    local function clear(t)
        for i = #t, 1, -1 do
            t[i] = nil
        end
    end

    -- Run a scenario, assert the universal invariants (every POSTed request
    -- validates; the loop never over-requests past the scripted responses), and
    -- return the live Conversation for scenario-specific assertions.
    local function run(sc)
        clear(captured)
        fake:reset(sc.responses)
        chatviewer.last_on_stop = nil
        chatviewer.last_text = nil
        bbtools.state.stop_during_tool = sc.stop_during_tool or false
        cfg.base_url = "https://example"
        cfg.api_key = "k"
        cfg.model = "test"
        cfg.max_tokens = 1024
        cfg.max_turns = sc.max_turns or 20
        cfg.additional_system_prompt = ""
        cfg.enable_memory = sc.enable_memory and true or false
        cfg.enable_thinking = sc.enable_thinking or false
        cfg.show_streaming_thinking = sc.show_streaming_thinking or false
        cfg.enable_web_search = true
        -- Reset the memory recorder per scenario; sc.memory_base opts the book into the
        -- store (Memory.baseDirForBook returns it), otherwise memory stays off.
        mem.rec.calls = {}
        mem.rec.base = sc.memory_base

        local selected_text
        if not sc.book_level then
            selected_text = "the passage"
        end
        local conv = Conversation:new({
            ui = {},
            settings = stubSettings,
            selected_text = selected_text,
            note = sc.note,
        })
        conv:ask(sc.first_question or "What does this mean?")
        for _, fq in ipairs(sc.followups or {}) do
            conv:ask(fq)
        end

        for n, req in ipairs(captured) do
            assert.are.equal(
                0,
                #sse.validateMessages(req.messages),
                "request " .. n .. " produced an invalid message array"
            )
        end
        assert.is_true(fake.idx <= #sc.responses, "loop requested more responses than were scripted")
        return conv
    end

    local function seed()
        return captured[1] and captured[1].messages[1] and captured[1].messages[1].content or ""
    end

    local function hasWebSearch(specs)
        for _, t in ipairs(specs) do
            if type(t) == "table" and t.type == "web_search_20250305" then
                return true
            end
        end
        return false
    end

    describe("web search toggle", function()
        it("keeps the web_search tool unless web search is explicitly disabled", function()
            cfg.enable_web_search = true
            local on = Conversation:new({ ui = {}, settings = stubSettings })
            assert.is_true(hasWebSearch(on.tool_specs))

            cfg.enable_web_search = nil -- absent flag keeps the default-on behaviour
            local dflt = Conversation:new({ ui = {}, settings = stubSettings })
            assert.is_true(hasWebSearch(dflt.tool_specs))
        end)

        it("drops the web_search tool when web search is disabled", function()
            cfg.enable_web_search = false
            local off = Conversation:new({ ui = {}, settings = stubSettings })
            assert.is_false(hasWebSearch(off.tool_specs))
            cfg.enable_web_search = true -- restore for any later scenario
        end)
    end)

    it("resets the shared per-conversation locator/search state on new()", function()
        -- _bookbuddy_locators/_loc_seq/_last_search live on the shared ui, which
        -- outlives a Conversation, so a new chat MUST clear them or it inherits stale
        -- locators -- a correctness and spoiler concern (a loc minted past the reader's
        -- page in a prior chat could be reused). A regression dropping the reset
        -- (bbconversation.lua:193-197) would otherwise fail nothing.
        local ui = {
            _bookbuddy_locators = { { kind = "point", xp = "x" } },
            _bookbuddy_loc_seq = 5,
            _bookbuddy_last_search = { query = "old", items = {} },
        }
        Conversation:new({ ui = ui, settings = stubSettings })
        assert.is_nil(ui._bookbuddy_locators)
        assert.is_nil(ui._bookbuddy_loc_seq)
        assert.is_nil(ui._bookbuddy_last_search)
    end)

    it("S1: completes a web search, then a follow-up", function()
        run({
            responses = {
                sse.buildTurnSSE({
                    blocks = {
                        { type = "text", text = "Let me check the web." },
                        { type = "server_tool_use", id = "srvtoolu_A", input = { query = "claude shannon" } },
                        { type = "web_search_tool_result", tool_use_id = "srvtoolu_A", content = sse.webResults(2) },
                        { type = "text", text = "Shannon was born in 1916." },
                    },
                }),
                sse.buildTurnSSE({ blocks = { { type = "text", text = "Here is more detail." } } }),
            },
            followups = { "Tell me more." },
        })
    end)

    it("S2: resumes a pause_turn with a dangling web search, then a follow-up", function()
        run({
            responses = {
                sse.buildTurnSSE({
                    blocks = {
                        { type = "text", text = "Searching the web..." },
                        { type = "server_tool_use", id = "srvtoolu_B", input = { query = "a long search" } },
                    },
                    stop_reason = "pause_turn",
                }),
                sse.buildTurnSSE({ blocks = { { type = "text", text = "Based on what I found, the answer is X." } } }),
                sse.buildTurnSSE({ blocks = { { type = "text", text = "Follow-up answer." } } }),
            },
            followups = { "And what about Y?" },
        })
    end)

    it("S2b: folds a reader note into the seed", function()
        run({
            note = "I think the narrator is unreliable here.",
            first_question = "Am I right about this?",
            responses = { sse.buildTurnSSE({ blocks = { { type = "text", text = "Good instinct." } } }) },
        })
        local s = seed()
        for _, want in ipairs({
            "<highlighted_passage>",
            "<reader_note>",
            "I think the narrator is unreliable here.",
            "<question>\nAm I right about this?\n</question>",
        }) do
            assert.is_not_nil(s:find(want, 1, true), "seed missing: " .. want)
        end
    end)

    it("S2c: keeps the original framing when there is no note", function()
        run({
            first_question = "What does this mean?",
            responses = { sse.buildTurnSSE({ blocks = { { type = "text", text = "It means X." } } }) },
        })
        local s = seed()
        assert.is_not_nil(s:find("<highlighted_passage>", 1, true))
        assert.is_not_nil(s:find("<question>\nWhat does this mean?\n</question>", 1, true))
    end)

    it("S2d: a book-level chat seeds context + question, no passage block", function()
        local conv = run({
            book_level = true,
            first_question = "Who are the main characters so far?",
            responses = { sse.buildTurnSSE({ blocks = { { type = "text", text = "The protagonist is Ada." } } }) },
        })
        assert.is_not_nil((chatviewer.last_text or ""):find("The protagonist is Ada.", 1, true))
        local s = seed()
        assert.is_not_nil(s:find("<book_context>", 1, true))
        assert.is_not_nil(s:find("<question>\nWho are the main characters so far?\n</question>", 1, true))
        assert.is_nil(s:find("<highlighted_passage>", 1, true))
        assert.is_not_nil(conv) -- silence luacheck on the returned value
    end)

    it("S3: resumes two consecutive pause_turns, then answers, then a follow-up", function()
        run({
            responses = {
                sse.buildTurnSSE({
                    blocks = {
                        { type = "text", text = "Searching (1)..." },
                        { type = "server_tool_use", id = "srvtoolu_C", input = { query = "q1" } },
                    },
                    stop_reason = "pause_turn",
                }),
                sse.buildTurnSSE({
                    blocks = {
                        { type = "text", text = "Still searching..." },
                        { type = "server_tool_use", id = "srvtoolu_D", input = { query = "q2" } },
                    },
                    stop_reason = "pause_turn",
                }),
                sse.buildTurnSSE({ blocks = { { type = "text", text = "Here is my best answer." } } }),
                sse.buildTurnSSE({ blocks = { { type = "text", text = "Sure." } } }),
            },
            followups = { "Anything else?" },
        })
    end)

    it("S4: resumes a pause_turn, then runs a client tool call", function()
        run({
            responses = {
                sse.buildTurnSSE({
                    blocks = {
                        { type = "text", text = "Let me look outside the book." },
                        { type = "server_tool_use", id = "srvtoolu_W", input = { query = "author bio" } },
                    },
                    stop_reason = "pause_turn",
                }),
                sse.buildTurnSSE({
                    blocks = {
                        { type = "text", text = "Now let me check the book itself." },
                        { type = "tool_use", id = "toolu_Z", name = "grep", input = { query = "whales" } },
                    },
                    stop_reason = "tool_use",
                }),
                sse.buildTurnSSE({ blocks = { { type = "text", text = "Here is what I found." } } }),
            },
        })
    end)

    it("S4b: runs a create_highlight tool round and renders the action phrase", function()
        run({
            responses = {
                sse.buildTurnSSE({
                    blocks = {
                        { type = "text", text = "I'll mark that passage." },
                        {
                            type = "tool_use",
                            id = "toolu_HL",
                            name = "create_highlight",
                            input = { text = "the important bit", note = "remember this" },
                        },
                    },
                    stop_reason = "tool_use",
                }),
                sse.buildTurnSSE({ blocks = { { type = "text", text = "Done -- highlighted on page 12." } } }),
            },
        })
        assert.is_not_nil((chatviewer.last_text or ""):find("Created a highlight", 1, true))
    end)

    it("S4c: routes a memory tool_use to the store's execute, not Tools.execute", function()
        -- enable_memory + a resolvable base makes Conversation:new build the store and
        -- advertise the memory tool; the loop must route tool_use{name="memory"} to
        -- self.memory:execute, NOT Tools.execute (which would answer "unknown tool
        -- memory"). Previously only the display-only phrasing was covered.
        local conv = run({
            enable_memory = true,
            memory_base = "/tmp/bookbuddy-memory",
            responses = {
                sse.buildTurnSSE({
                    blocks = {
                        { type = "text", text = "Let me check my notes." },
                        {
                            type = "tool_use",
                            id = "toolu_M",
                            name = "memory",
                            input = { command = "view", path = "/memories" },
                        },
                    },
                    stop_reason = "tool_use",
                }),
                sse.buildTurnSSE({ blocks = { { type = "text", text = "Here is what I remembered." } } }),
            },
        })
        -- The store executed the call...
        assert.are.equal(1, #mem.rec.calls)
        assert.are.equal("view", mem.rec.calls[1].command)
        -- ...and its output is what got committed as the tool_result (not TOOL_RESULT).
        local tr
        for _, m in ipairs(conv.messages) do
            if
                m.role == "user"
                and type(m.content) == "table"
                and m.content[1]
                and m.content[1].type == "tool_result"
            then
                tr = m.content[1]
            end
        end
        assert.is_not_nil(tr)
        assert.are.equal("MEMORY_RESULT(view)", tr.content)
        assert.are.equal(0, #sse.validateMessages(conv.messages))
    end)

    it("U1: usage sums across calls while context_size tracks only the latest call", function()
        -- Two API calls (a tool round): each scripted turn reports input 10 / output 20.
        -- The cumulative billed usage doubles; the live context size does not -- it is
        -- the latest call's full prompt (input + cache) plus its output.
        local conv = run({
            responses = {
                sse.buildTurnSSE({
                    blocks = {
                        { type = "text", text = "I'll mark that passage." },
                        {
                            type = "tool_use",
                            id = "toolu_HL2",
                            name = "create_highlight",
                            input = { text = "a passage", note = "n" },
                        },
                    },
                    stop_reason = "tool_use",
                }),
                sse.buildTurnSSE({ blocks = { { type = "text", text = "Done." } } }),
            },
        })
        assert.are.equal(20, conv.usage.input)
        assert.are.equal(40, conv.usage.output)
        assert.are.equal(30, conv.context_size)
        assert.is_not_nil(conv:_usageText():find("[context — 30]", 1, true))
    end)

    it("U2: the footer abbreviates thousands as k and flags a context over 250k", function()
        local conv = run({
            responses = { sse.buildTurnSSE({ blocks = { { type = "text", text = "Hi." } } }) },
        })
        conv.usage.input = 156888
        conv.context_size = 156888
        local text = conv:_usageText()
        assert.is_not_nil(text:find("input 157k", 1, true))
        assert.is_not_nil(text:find("[context — 157k]", 1, true))
        -- context line is its own line, distinct from the cumulative token line.
        assert.is_not_nil(text:find("]\n[", 1, true))
        assert.is_nil(text:find("🔥", 1, true))

        conv.context_size = 251000
        text = conv:_usageText()
        assert.is_not_nil(text:find("[context — 251k] 🔥", 1, true))
    end)

    it("S6: pauses do not consume the substantive turn budget", function()
        run({
            max_turns = 2,
            responses = {
                sse.buildTurnSSE({
                    blocks = {
                        { type = "text", text = "Searching (1)..." },
                        { type = "server_tool_use", id = "srvtoolu_P1", input = { query = "q1" } },
                    },
                    stop_reason = "pause_turn",
                }),
                sse.buildTurnSSE({
                    blocks = {
                        { type = "text", text = "Searching (2)..." },
                        { type = "server_tool_use", id = "srvtoolu_P2", input = { query = "q2" } },
                    },
                    stop_reason = "pause_turn",
                }),
                sse.buildTurnSSE({
                    blocks = {
                        { type = "text", text = "Searching (3)..." },
                        { type = "server_tool_use", id = "srvtoolu_P3", input = { query = "q3" } },
                    },
                    stop_reason = "pause_turn",
                }),
                sse.buildTurnSSE({ blocks = { { type = "text", text = "Finally, the answer is 42." } } }),
            },
        })
        assert.is_not_nil((chatviewer.last_text or ""):find("Finally, the answer is 42.", 1, true))
    end)

    it("S5: handles thinking + a completed web search in one turn", function()
        run({
            responses = {
                sse.buildTurnSSE({
                    blocks = {
                        { type = "thinking", thinking = "The reader asks about the author; I should look it up." },
                        { type = "text", text = "Let me look that up." },
                        { type = "server_tool_use", id = "srvtoolu_E", input = { query = "Max Gladstone biography" } },
                        { type = "web_search_tool_result", tool_use_id = "srvtoolu_E", content = sse.webResults(3) },
                        { type = "text", text = "The author is Max Gladstone, born 1984." },
                    },
                }),
            },
        })
    end)

    it("S6: surfaces the thinking text in the transcript when show_streaming_thinking is on", function()
        run({
            enable_thinking = true,
            show_streaming_thinking = true,
            responses = {
                sse.buildTurnSSE({
                    blocks = {
                        { type = "thinking", thinking = "The reader is on chapter 2; the butler did it." },
                        { type = "text", text = "Here is a hint." },
                    },
                }),
            },
        })
        assert.is_not_nil((chatviewer.last_text or ""):find("the butler did it", 1, true))
    end)

    it("S6b: hides the thinking text by default, keeping only the indicator", function()
        run({
            enable_thinking = true,
            show_streaming_thinking = false,
            responses = {
                sse.buildTurnSSE({
                    blocks = {
                        { type = "thinking", thinking = "The reader is on chapter 2; the butler did it." },
                        { type = "text", text = "Here is a hint." },
                    },
                }),
            },
        })
        assert.is_nil((chatviewer.last_text or ""):find("the butler did it", 1, true))
        assert.is_not_nil((chatviewer.last_text or ""):find("Thinking", 1, true))
    end)

    it("S7: a retryable mid-stream error on a follow-up auto-recovers via retry", function()
        -- Under R1 an overloaded_error is RETRYABLE: the follow-up's first attempt
        -- errors, the loop re-forks (no extra ask()), and the next scripted response
        -- answers. History stays resendable throughout (run() validates every POST).
        run({
            responses = {
                sse.buildTurnSSE({ blocks = { { type = "text", text = "First answer." } } }),
                {
                    "data: "
                        .. stubs.json.encode({ type = "error", error = { type = "overloaded_error", message = "boom" } }),
                },
                sse.buildTurnSSE({ blocks = { { type = "text", text = "Recovered answer." } } }),
            },
            followups = { "broken one" },
        })
        -- Three forks: the good first answer, the errored attempt, the retry.
        assert.are.equal(3, fake.idx)
        assert.is_not_nil((chatviewer.last_text or ""):find("Recovered answer.", 1, true))
    end)

    it("S8: a retryable error after a client tool round auto-recovers via retry", function()
        -- The tool round commits (assistant tool_use + user tool_result), the post-tool
        -- request errors (retryable), and the retry re-forks from the committed state
        -- to deliver the answer -- all within a single ask().
        run({
            responses = {
                sse.buildTurnSSE({
                    blocks = {
                        { type = "text", text = "Let me check the book." },
                        { type = "tool_use", id = "toolu_Q", name = "grep", input = { query = "whales" } },
                    },
                    stop_reason = "tool_use",
                }),
                {
                    "data: "
                        .. stubs.json.encode({ type = "error", error = { type = "overloaded_error", message = "boom" } }),
                },
                sse.buildTurnSSE({ blocks = { { type = "text", text = "Answer after recovery." } } }),
            },
        })
        assert.are.equal(3, fake.idx)
        assert.is_not_nil((chatviewer.last_text or ""):find("Answer after recovery.", 1, true))
    end)

    it("S9: Stop during a synchronous tool aborts at the next loop boundary", function()
        local conv = run({
            stop_during_tool = true,
            responses = {
                sse.buildTurnSSE({
                    blocks = {
                        { type = "text", text = "Let me check the book." },
                        { type = "tool_use", id = "toolu_S", name = "grep", input = { query = "whales" } },
                    },
                    stop_reason = "tool_use",
                }),
            },
        })
        -- Aborted before forking the next request: exactly one request issued.
        assert.are.equal(1, fake.idx)
        -- The stop hook fired (tool ran) and the stored history is balanced/resendable,
        -- ending on the tool_result pair.
        assert.is_false(bbtools.state.stop_during_tool)
        assert.are.equal(0, #sse.validateMessages(conv.messages))
        local last = conv.messages[#conv.messages]
        assert.are.equal("user", last.role)
        assert.are.equal("table", type(last.content))
        assert.are.equal("tool_result", last.content[1].type)
    end)

    -- A mid-stream Anthropic error event (one SSE line). type drives the retry
    -- classifier: overloaded_error/api_error/rate_limit_error retry, the rest terminal.
    local function errorSSE(error_type)
        return {
            "data: " .. stubs.json.encode({
                type = "error",
                error = { type = error_type, message = "boom" },
            }),
        }
    end

    -- A non-200 HTTP failure as the child would stream it: a JSON error body line
    -- followed by the X-BB-NON-200 status marker the child appends.
    local function non200SSE(code, etype)
        return {
            stubs.json.encode({ error = { type = etype or "invalid_request_error", message = "bad" } }),
            "X-BB-NON-200: " .. tostring(code),
        }
    end

    it("C1: an unpaired server_tool_use under a non-pause stop_reason is paired and resends cleanly", function()
        -- A turn can carry an orphan web search (server_tool_use with no
        -- web_search_tool_result) under ANY stop_reason, not just pause_turn -- here
        -- end_turn. Left unpaired the Vertex validator 400s on every resend. The
        -- unconditional pairDanglingWebSearch must synthesise an error result so the
        -- stored history validates and a SECOND ask() does not wedge.
        local conv = run({
            responses = {
                sse.buildTurnSSE({
                    blocks = {
                        { type = "text", text = "Let me look that up." },
                        { type = "server_tool_use", id = "srvtoolu_ORPH", input = { query = "orphan" } },
                        { type = "text", text = "Here is the answer." },
                    },
                    stop_reason = "end_turn", -- NOT pause_turn
                }),
                sse.buildTurnSSE({ blocks = { { type = "text", text = "Second answer." } } }),
            },
            followups = { "and more?" },
        })
        -- run() already validated every POST; assert the orphan was healed in place.
        local assistant
        for _, m in ipairs(conv.messages) do
            if m.role == "assistant" and type(m.content) == "table" then
                for _, b in ipairs(m.content) do
                    if b.type == "server_tool_use" and b.id == "srvtoolu_ORPH" then
                        assistant = m
                    end
                end
            end
        end
        assert.is_not_nil(assistant, "the orphan server_tool_use turn should be in history")
        local paired = false
        for _, b in ipairs(assistant.content) do
            if b.type == "web_search_tool_result" and b.tool_use_id == "srvtoolu_ORPH" then
                paired = true
            end
        end
        assert.is_true(paired, "the orphan must be paired with a synthetic result")
        assert.are.equal(0, #sse.validateMessages(conv.messages))
        assert.is_not_nil((chatviewer.last_text or ""):find("Second answer.", 1, true))
    end)

    it("C1b: a pre-persisted orphan server_tool_use is self-healed by _dropDanglingTail", function()
        -- An older session may have persisted an assistant turn whose server_tool_use
        -- has no paired result (the pairing fix postdates it). _dropDanglingTail's
        -- dangling test now treats such an orphan as dangling and walks it off, so the
        -- stored history is resendable again.
        local conv = Conversation:new({ ui = {}, settings = stubSettings, selected_text = "x" })
        conv.messages = {
            { role = "user", content = "earlier question" },
            { role = "assistant", content = { { type = "text", text = "a clean earlier answer" } } },
            { role = "user", content = "later question" },
            {
                role = "assistant",
                content = {
                    { type = "text", text = "older partial" },
                    { type = "server_tool_use", id = "srvtoolu_OLD", name = "web_search", input = { query = "q" } },
                },
            },
        }
        -- Sanity: this history is currently INVALID (orphan present).
        assert.is_true(#sse.validateMessages(conv.messages) > 0)
        conv:_dropDanglingTail()
        -- The orphan assistant turn (and the now-dangling user turn before it) are
        -- walked off, back to the last clean assistant reply.
        assert.are.equal(2, #conv.messages)
        local last = conv.messages[#conv.messages]
        assert.are.equal("assistant", last.role)
        assert.are.equal("a clean earlier answer", last.content[1].text)
        assert.are.equal(0, #sse.validateMessages(conv.messages))
    end)

    it("L1: a mid-round failure + recovery leaves no rolled-back partials in the transcript", function()
        -- First attempt streams a partial assistant line then drops (read_error);
        -- the retry delivers the real answer. The transcript must show ONLY the
        -- recovered answer -- not the abandoned partial from the failed attempt.
        local conv = run({
            responses = {
                { outcome = "read_error" },
                sse.buildTurnSSE({ blocks = { { type = "text", text = "The clean recovered answer." } } }),
            },
        })
        local text = chatviewer.last_text or ""
        assert.is_not_nil(text:find("The clean recovered answer.", 1, true))
        -- Absence: the failed attempt produced no committed assistant entry, and the
        -- retry status line is transient (never stored), so the final render is clean.
        assert.is_nil(text:find("Retrying", 1, true), "final render must not keep the retry status")
        -- History holds exactly one assistant turn (the recovered one), no partials.
        local n_assistant = 0
        for _, m in ipairs(conv.messages) do
            if m.role == "assistant" then
                n_assistant = n_assistant + 1
            end
        end
        assert.are.equal(1, n_assistant)
        assert.are.equal(0, #sse.validateMessages(conv.messages))
    end)

    it("L1b: a partial text attempt that then errors leaves no orphaned assistant line", function()
        -- The failed attempt streams a real text delta into the live transcript before
        -- the stream errors. _trimTranscript (between attempts) must drop that partial
        -- so the recovered turn's content is the only assistant text rendered. Attempt 1
        -- is a started-but-truncated stream (incomplete, retryable) that carries a
        -- partial assistant line the viewer rendered live.
        run({
            responses = {
                sse.incompleteTurnSSE({ blocks = { { type = "text", text = "ABANDONED partial text" } } }),
                sse.buildTurnSSE({ blocks = { { type = "text", text = "Final good answer." } } }),
            },
        })
        local text = chatviewer.last_text or ""
        assert.is_not_nil(text:find("Final good answer.", 1, true))
        assert.is_nil(text:find("ABANDONED partial text", 1, true), "rolled-back partial must not survive")
    end)

    it("L1c: a multi-round rollback drops a PRIOR committed round's transcript entries", function()
        -- Round 1 commits a grep tool round (assistant tool_use + user tool_result),
        -- rendering a lead-in line and a "→ Searched book..." action line. Round 2's
        -- post-tool request then fails persistently (3 read_errors -> exhausted), so
        -- _dropDanglingTail walks the WHOLE in-flight chain off the wire -- including
        -- round 1's committed pair, back to empty. The transcript must follow: with
        -- the per-round checkpoint it stranded round 1's lead-in + action line; the
        -- chain-start checkpoint trims them too.
        local conv = run({
            responses = {
                sse.buildTurnSSE({
                    blocks = {
                        { type = "text", text = "ROUND1 lead-in text" },
                        { type = "tool_use", id = "toolu_R1", name = "grep", input = { query = "whales" } },
                    },
                    stop_reason = "tool_use",
                }),
                { outcome = "read_error" },
                { outcome = "read_error" },
                { outcome = "read_error" },
            },
        })
        -- Wire history rolled all the way back to empty: no assistant turn survives.
        for _, m in ipairs(conv.messages) do
            assert.are_not.equal("assistant", m.role)
        end
        assert.are.equal(0, #sse.validateMessages(conv.messages))
        -- And the transcript holds no entry whose backing message was dropped: neither
        -- round 1's lead-in nor its tool-action line may survive the rollback. Assert
        -- on the transcript data structure (the error exit closes the viewer without a
        -- final re-render, so last_text is stale) -- _transcriptText renders the
        -- post-rollback state the next ask() would re-show.
        local text = conv:_transcriptText()
        assert.is_nil(text:find("ROUND1 lead-in text", 1, true), "prior round's lead-in must be trimmed")
        assert.is_nil(text:find("Searched book", 1, true), "prior round's tool action must be trimmed")
    end)

    it("L2: a pause_turn whose resume fails keeps the pause turn in BOTH wire and transcript", function()
        -- A successful pause round commits a NON-dangling assistant turn (its
        -- server_tool_use is paired with a synthetic result). If the following resume
        -- then fails persistently, _dropDanglingTail STOPS at that paired turn (keeping
        -- it in the wire), so _trimTranscript must stop there too. Otherwise the human
        -- log loses the pause lead-in that the wire still resends -- desyncing the two
        -- and producing two consecutive "You:" turns after a follow-up.
        local conv = run({
            responses = {
                sse.buildTurnSSE({
                    blocks = {
                        { type = "text", text = "PAUSE leadin text" },
                        { type = "server_tool_use", id = "srvtoolu_PZ", input = { query = "q" } },
                    },
                    stop_reason = "pause_turn",
                }),
                -- The resume round drops three times -> retries exhausted -> give up.
                { outcome = "read_error" },
                { outcome = "read_error" },
                { outcome = "read_error" },
                -- The follow-up answers on top of the kept pause turn.
                sse.buildTurnSSE({ blocks = { { type = "text", text = "Follow-up answer." } } }),
            },
            followups = { "are you there?" },
        })
        -- The committed pause turn's lead-in survives in the human log (not trimmed)...
        local text = conv:_transcriptText()
        assert.is_not_nil(text:find("PAUSE leadin text", 1, true), "pause lead-in must survive the failed resume")
        -- ...and the transcript never shows two consecutive reader turns.
        for i = 2, #conv.transcript do
            assert.is_false(
                conv.transcript[i].role == "user" and conv.transcript[i - 1].role == "user",
                "no two consecutive You: turns"
            )
        end
        -- Wire stays resendable, and the follow-up landed after the kept pause turn.
        assert.are.equal(0, #sse.validateMessages(conv.messages))
        assert.is_not_nil((chatviewer.last_text or ""):find("Follow-up answer.", 1, true))
    end)

    it("R1: a transient read_error is retried and yields the answer in one turn", function()
        local conv = run({
            responses = {
                { outcome = "read_error" }, -- attempt 1 drops
                sse.buildTurnSSE({ blocks = { { type = "text", text = "Recovered after a transient drop." } } }),
            },
        })
        assert.are.equal(2, fake.idx) -- one failed attempt + one good attempt
        assert.is_not_nil((chatviewer.last_text or ""):find("Recovered after a transient drop.", 1, true))
        assert.are.equal(0, #sse.validateMessages(conv.messages))
    end)

    it("R1f: a child-side network_error is retried and yields the answer", function()
        -- The child wrote X-BB-NETWORK-ERROR then closed cleanly, so the parent sees no
        -- read_error -- :result() reports { ok=false, network_error=true }. This is the
        -- same transient transport class as read_error (a WiFi blip / gateway reset) and
        -- must re-fork, not end the turn.
        local conv = run({
            responses = {
                { outcome = "network_error" }, -- attempt 1: transport drop, child-side
                sse.buildTurnSSE({ blocks = { { type = "text", text = "Recovered after a network drop." } } }),
            },
        })
        assert.are.equal(2, fake.idx) -- the loop re-forked once
        assert.is_not_nil((chatviewer.last_text or ""):find("Recovered after a network drop.", 1, true))
        assert.are.equal(0, #sse.validateMessages(conv.messages))
    end)

    it("R1b: a persistent retryable failure exhausts the cap and surfaces the error", function()
        -- Three read_errors in a row exhaust MAX_STREAM_ATTEMPTS (3). The loop gives
        -- up, rolls back the dangling tail, and shows the streaming-connection error.
        -- Nothing was committed, so history stays resendable (empty here).
        local conv = run({
            responses = {
                { outcome = "read_error" },
                { outcome = "read_error" },
                { outcome = "read_error" },
            },
        })
        assert.are.equal(3, fake.idx) -- exactly the cap, never more
        -- No assistant turn was stored; the seeded user turn was rolled back, so the
        -- next ask() can re-seed cleanly.
        for _, m in ipairs(conv.messages) do
            assert.are_not.equal("assistant", m.role)
        end
        assert.are.equal(0, #sse.validateMessages(conv.messages))
    end)

    it("R1e: a retryable 503 is retried and yields the answer", function()
        -- A 503 is in RETRYABLE_HTTP: the gateway is transiently overloaded, so the loop
        -- re-forks rather than surfacing the error. Pins the whole RETRYABLE_HTTP table
        -- (the only other HTTP-code spec, R1c, drives a TERMINAL 400).
        local conv = run({
            responses = {
                non200SSE(503, "overloaded"),
                sse.buildTurnSSE({ blocks = { { type = "text", text = "Recovered after 503." } } }),
            },
        })
        assert.are.equal(2, fake.idx)
        assert.is_not_nil((chatviewer.last_text or ""):find("Recovered after 503.", 1, true))
        assert.are.equal(0, #sse.validateMessages(conv.messages))
    end)

    it("R1g: three retryable 503s exhaust the cap and surface the gateway error", function()
        -- The exhausted-retryable-HTTP path: unlike read_error (R1b, generic
        -- connection message), an exhausted retryable HTTP code routes through
        -- _showError(res), which surfaces the gateway's HTTP code/body. This pins both
        -- RETRYABLE_HTTP exhaustion and the _showError branch (line ~454).
        local shown
        local InfoMessage = require("ui/widget/infomessage")
        local real_new = InfoMessage.new
        InfoMessage.new = function(self_, o)
            shown = o and o.text
            return real_new(self_, o)
        end
        local ok, conv = pcall(run, {
            responses = {
                non200SSE(503, "overloaded"),
                non200SSE(503, "overloaded"),
                non200SSE(503, "overloaded"),
            },
        })
        InfoMessage.new = real_new
        assert.is_true(ok)
        assert.are.equal(3, fake.idx) -- exactly the cap
        -- _showError surfaced the HTTP code, not the generic "connection failed" text.
        assert.is_not_nil(shown)
        assert.is_not_nil(tostring(shown):find("503", 1, true), "the gateway HTTP code must be surfaced")
        -- No assistant turn committed; history stays resendable.
        for _, m in ipairs(conv.messages) do
            assert.are_not.equal("assistant", m.role)
        end
        assert.are.equal(0, #sse.validateMessages(conv.messages))
    end)

    it("R1c: a terminal 400 is NOT retried", function()
        local conv = run({
            responses = {
                non200SSE(400, "invalid_request_error"),
                -- A second response is scripted but must never be consumed.
                sse.buildTurnSSE({ blocks = { { type = "text", text = "should never be reached" } } }),
            },
        })
        assert.are.equal(1, fake.idx) -- terminal: a single attempt, no retry
        assert.is_nil((chatviewer.last_text or ""):find("should never be reached", 1, true))
        assert.are.equal(0, #sse.validateMessages(conv.messages))
    end)

    it("R1d: a non-retryable mid-stream error type is NOT retried", function()
        -- authentication_error is terminal: the gateway will reject identically on
        -- every resend, so retrying only burns quota.
        local conv = run({
            responses = {
                errorSSE("authentication_error"),
                sse.buildTurnSSE({ blocks = { { type = "text", text = "should never be reached" } } }),
            },
        })
        assert.are.equal(1, fake.idx)
        assert.is_nil((chatviewer.last_text or ""):find("should never be reached", 1, true))
        assert.are.equal(0, #sse.validateMessages(conv.messages))
    end)

    it("R2: a transient empty-200 is retried; a persistent one falls back to (no response)", function()
        -- First: a transient empty reply (200, no content blocks) is retryable, so the
        -- loop re-forks and the good response answers.
        local conv = run({
            responses = {
                sse.buildTurnSSE({ blocks = {} }), -- empty-200
                sse.buildTurnSSE({ blocks = { { type = "text", text = "A real answer this time." } } }),
            },
        })
        assert.are.equal(2, fake.idx)
        assert.is_not_nil((chatviewer.last_text or ""):find("A real answer this time.", 1, true))
        assert.are.equal(0, #sse.validateMessages(conv.messages))

        -- Persistent: three empty-200s exhaust the cap and the placeholder stands in.
        conv = run({
            responses = {
                sse.buildTurnSSE({ blocks = {} }),
                sse.buildTurnSSE({ blocks = {} }),
                sse.buildTurnSSE({ blocks = {} }),
            },
        })
        assert.are.equal(3, fake.idx)
        assert.is_not_nil((chatviewer.last_text or ""):find("(no response)", 1, true))
        -- The placeholder is a valid content block, so history stays resendable.
        assert.are.equal(0, #sse.validateMessages(conv.messages))
        local last = conv.messages[#conv.messages]
        assert.are.equal("assistant", last.role)
        assert.are.equal("text", last.content[1].type)
    end)

    it("R3: an incomplete stream (missing message_stop) is retried in the loop", function()
        -- The parser reports ok=false/incomplete for a truncated 200; the loop
        -- classifies that as retryable and re-forks to the good response.
        local conv = run({
            responses = {
                sse.incompleteTurnSSE({ blocks = { { type = "text", text = "truncated..." } } }),
                sse.buildTurnSSE({ blocks = { { type = "text", text = "Complete answer." } } }),
            },
        })
        assert.are.equal(2, fake.idx)
        assert.is_not_nil((chatviewer.last_text or ""):find("Complete answer.", 1, true))
        assert.is_nil((chatviewer.last_text or ""):find("truncated...", 1, true))
        assert.are.equal(0, #sse.validateMessages(conv.messages))
    end)

    it("S6b: a server that pause_turns past max_resumes stops and renders the partial reply", function()
        -- max_resumes is 16: build 17 consecutive pause_turns (no terminal answer).
        -- The resume cap must stop the loop and render the last partial reply rather
        -- than burning the whole turn budget or looping forever.
        local responses = {}
        for i = 1, 17 do
            responses[i] = sse.buildTurnSSE({
                blocks = {
                    { type = "text", text = "Still searching #" .. i .. "..." },
                    { type = "server_tool_use", id = "srvtoolu_R" .. i, input = { query = "q" .. i } },
                },
                stop_reason = "pause_turn",
            })
        end
        local conv = run({ responses = responses })
        -- 1 substantive turn + 16 resumes = 17 forks; the 17th pause trips the cap.
        assert.are.equal(17, fake.idx)
        -- The partial reply from the last paused turn is rendered.
        assert.is_not_nil((chatviewer.last_text or ""):find("Still searching #17", 1, true))
        assert.are.equal(0, #sse.validateMessages(conv.messages))
    end)

    it("S12: Stop during a LIVE stream cancels without retry", function()
        -- Distinct from S9 (Stop during a synchronous tool): here the Stop lands on the
        -- live stream itself, so Stream.run returns cancelled. A cancel is terminal and
        -- first in the classifier -- it must never be retried.
        local conv = run({
            responses = {
                {
                    outcome = "cancelled",
                    lines = sse.buildTurnSSE({
                        blocks = { { type = "text", text = "partial before stop" } },
                    }),
                },
                -- Scripted but must never be consumed (no retry after a cancel).
                sse.buildTurnSSE({ blocks = { { type = "text", text = "never reached" } } }),
            },
        })
        assert.are.equal(1, fake.idx)
        assert.is_true(conv.stop_requested)
        -- Cancel rolls back the in-flight turn; history is resendable (empty here).
        for _, m in ipairs(conv.messages) do
            assert.are_not.equal("assistant", m.role)
        end
        assert.are.equal(0, #sse.validateMessages(conv.messages))
    end)

    it("S13: Stop pressed DURING backoff aborts without consuming a retry", function()
        -- Distinct from S12 (Stop on the LIVE stream, which Stream.run reports as
        -- cancelled BEFORE any backoff). Here attempt 1 is a read_error -> the loop
        -- classifies retry and backs off; the Stop lands during that backoff window
        -- (no live stream to _cancel), so it is recorded on stop_requested and the
        -- post-backoff guard aborts. The second scripted response must never be
        -- consumed -- a Stop must never silently burn a retry.
        local conv = run({
            responses = {
                { outcome = "read_error", stop_after = true },
                -- Scripted but must never be reached: the Stop aborts before attempt 2.
                sse.buildTurnSSE({ blocks = { { type = "text", text = "never reached" } } }),
            },
        })
        assert.are.equal(1, fake.idx) -- no retry consumed after the Stop
        assert.is_true(conv.stop_requested)
        assert.is_nil((chatviewer.last_text or ""):find("never reached", 1, true))
        -- Nothing committed; the rolled-back history is resendable (empty here).
        for _, m in ipairs(conv.messages) do
            assert.are_not.equal("assistant", m.role)
        end
        assert.are.equal(0, #sse.validateMessages(conv.messages))
    end)

    describe("_toolActionPhrase", function()
        local conv
        setup(function()
            conv = Conversation:new({ ui = {}, settings = stubSettings, selected_text = "x" })
        end)
        local function phrase(name, input)
            return conv:_toolActionPhrase({ name = name, input = input })
        end

        it("phrases memory commands", function()
            assert.are.equal("  → Reviewed saved memory", phrase("memory", { command = "view", path = "/memories" }))
            assert.are.equal(
                "  → Read memory note characters.md",
                phrase("memory", { command = "view", path = "/memories/characters.md" })
            )
            assert.are.equal(
                "  → Saved memory note themes.md",
                phrase("memory", { command = "create", path = "/memories/themes.md" })
            )
            assert.are.equal(
                "  → Updated memory note themes.md",
                phrase("memory", { command = "str_replace", path = "/memories/themes.md" })
            )
            assert.are.equal(
                "  → Deleted memory note old.md",
                phrase("memory", { command = "delete", path = "/memories/old.md" })
            )
            assert.are.equal(
                "  → Renamed memory note a.md to b.md",
                phrase("memory", { command = "rename", old_path = "/memories/a.md", new_path = "/memories/b.md" })
            )
        end)

        it("phrases the grep search tool", function()
            -- The tool is named grep; the phrase branch must match that name, not
            -- the old search_book, or the transcript falls back to "Used grep".
            assert.are.equal('  → Searched book for "whales"', phrase("grep", { query = "whales" }))
        end)

        it("phrases navigate commands", function()
            assert.are.equal("  → Went to page 88", phrase("navigate", { page = 88 }))
            assert.are.equal("  → Went to 50%", phrase("navigate", { percent = 50 }))
            assert.are.equal("  → Went to chapter 3", phrase("navigate", { chapter_index = 3 }))
            assert.are.equal("  → Went back", phrase("navigate", { back = true }))
        end)

        it("phrases edit_highlight_note and read", function()
            assert.are.equal(
                "  → Updated the note on highlight 3",
                phrase("edit_highlight_note", { highlight_index = 3 })
            )
            -- Exact match like every sibling branch: a loose substring check would pass
            -- even if the locator were dropped or %1 mis-templated.
            assert.are.equal("  → Reading from loc:4", phrase("read", { from = "loc:4" }))
            assert.are.equal("  → Reading from your current page", phrase("read", {}))
        end)
    end)

    describe("stripMarkdown (via _transcriptText)", function()
        local function rendered(text)
            local conv = Conversation:new({ ui = {}, settings = stubSettings, selected_text = "x" })
            conv.transcript = { { role = "assistant", text = text } }
            return conv:_transcriptText()
        end

        it("strips markup but preserves snake_case and URLs", function()
            assert.are.equal("BookBuddy: bold", rendered("**bold**"))
            assert.are.equal("BookBuddy: italic", rendered("*italic*"))
            assert.are.equal("BookBuddy: a i b", rendered("a *i* b"))
            assert.are.equal("BookBuddy: gone", rendered("~~gone~~"))
            assert.are.equal("BookBuddy: code", rendered("`code`"))
            assert.are.equal("BookBuddy: docs (http://x)", rendered("[docs](http://x)"))
            assert.are.equal("BookBuddy: Title", rendered("# Title"))
            assert.are.equal("BookBuddy: see get_toc now", rendered("see get_toc now"))
            assert.are.equal("BookBuddy: go to https://example.com/a", rendered("go to https://example.com/a"))
        end)
    end)
end)
