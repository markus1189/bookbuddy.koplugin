-- The conversation loop, driven by scripted SSE through the real bbconversation
-- + bbanthropic. Ports the harness scenarios S1-S9 (request shape, pause_turn
-- resume, tool pairing, stop-during-tool, error recovery) plus the pure
-- _toolActionPhrase and stripMarkdown unit checks. Tools/memory are doubles;
-- real document tool execution is Tier 2.
local stubs = require("support.stubs")
local sse = require("support.sse")

describe("conversation", function()
    local Conversation, fake, captured, chatviewer, bbtools
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
        bbtools = stubs.install_bbtools_stub(h)
        fake = sse.new_fake_stream({})
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
        cfg.portkey_api_key = "k"
        cfg.model = "test"
        cfg.max_tokens = 1024
        cfg.max_turns = sc.max_turns or 20
        cfg.additional_system_prompt = ""
        cfg.enable_memory = false
        cfg.enable_thinking = false

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

    it("S7: an error on a plain follow-up still leaves resendable history", function()
        run({
            responses = {
                sse.buildTurnSSE({ blocks = { { type = "text", text = "First answer." } } }),
                {
                    "data: "
                        .. stubs.json.encode({ type = "error", error = { type = "overloaded_error", message = "boom" } }),
                },
                sse.buildTurnSSE({ blocks = { { type = "text", text = "Recovered answer." } } }),
            },
            followups = { "broken one", "recover with this" },
        })
        assert.is_not_nil((chatviewer.last_text or ""):find("Recovered answer.", 1, true))
    end)

    it("S8: an error after a client tool round drops the whole in-flight pair", function()
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
            followups = { "recover after tool error" },
        })
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
            local p = phrase("read", { from = "loc:4" })
            assert.is_true(type(p) == "string" and p ~= "" and p:lower():find("read") ~= nil)
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
