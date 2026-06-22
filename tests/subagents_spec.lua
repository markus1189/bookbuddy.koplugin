-- The subagent driver (bbsubagents) and the parent's delegate dispatch branch,
-- driven by scripted SSE through the real bbsubagents + bbconversation + bbanthropic.
-- Tools are a recording double so we can assert exactly what inputs reach the
-- executor (the spoiler scrub) and that a child grep's last_search is restored. The
-- child-tool-subset check loads the REAL bbtools to test the actual childSpecs filter.
local stubs = require("support.stubs")
local sse = require("support.sse")

describe("subagent child tool subset", function()
    it("includes the read tools and excludes mutators, web_search, and delegate", function()
        local Tools = stubs.load_tools()
        local names = {}
        for _, t in ipairs(Tools.childSpecs()) do
            names[t.name or t.type] = true
        end
        -- present: the five read-only book tools
        assert.is_true(names.grep)
        assert.is_true(names.read)
        assert.is_true(names.get_toc)
        assert.is_true(names.book_context)
        assert.is_true(names.get_highlights)
        -- absent: mutators, web_search, and delegate itself (so a child cannot recurse)
        assert.is_nil(names.navigate)
        assert.is_nil(names.create_highlight)
        assert.is_nil(names.edit_highlight_note)
        assert.is_nil(names.web_search)
        assert.is_nil(names.delegate)
    end)
end)

describe("subagent driver", function()
    local Conversation, Subagents, fake, chatviewer, rec
    local cfg = {}
    local stubSettings = {
        getConfig = function()
            return cfg
        end,
    }

    -- A recording bbtools double: book_context returns a canned line (and is NOT
    -- recorded, so rec.calls holds only the child's real tool calls); every other
    -- call is recorded with the exact (sanitized) input the driver passed. A grep
    -- writes ui._bookbuddy_last_search so the snapshot/restore can be asserted.
    local function install_tools_stub()
        rec = { calls = {}, current_page = 10 }
        local function spec(name)
            return { name = name, description = "", input_schema = { type = "object" } }
        end
        local stub = {
            getSpecs = function()
                return {
                    spec("grep"),
                    {
                        name = "delegate",
                        description = "",
                        input_schema = { type = "object", properties = { task = { type = "string" } } },
                    },
                    { type = "web_search_20250305", name = "web_search", max_uses = 5 },
                }
            end,
            childSpecs = function()
                return { spec("grep"), spec("read"), spec("get_toc"), spec("book_context"), spec("get_highlights") }
            end,
            currentPage = function()
                return rec.current_page
            end,
            execute = function(name, input, ui)
                if name == "book_context" then
                    return "Title: Test Book\nAuthor: Tester\nCurrent page: 10 of 200", "page 10 of 200"
                end
                rec.calls[#rec.calls + 1] = { name = name, input = input }
                if name == "grep" and ui then
                    ui._bookbuddy_last_search = "CHILD_SEARCH"
                end
                return "TOOL_RESULT(" .. tostring(name) .. ")", "ok"
            end,
        }
        package.loaded["bbtools"] = stub
        return stub
    end

    setup(function()
        local h = stubs.install()
        chatviewer = h.chatviewer
        stubs.install_bbmemory_stub()
        install_tools_stub()
        fake = sse.new_fake_stream({}, chatviewer)
        Conversation = require("bbconversation")
        Subagents = require("bbsubagents")
    end)

    before_each(function()
        rec.calls = {}
        rec.current_page = 10
        fake:reset({})
        chatviewer.last_on_stop = nil
        chatviewer.last_text = nil
        cfg.base_url = "https://example"
        cfg.api_key = "k"
        cfg.model = "test"
        cfg.max_tokens = 1024
        cfg.max_turns = 20
        cfg.additional_system_prompt = ""
        cfg.enable_memory = false
        cfg.enable_thinking = false
        cfg.show_streaming_thinking = false
        cfg.enable_web_search = true
        cfg.enable_subagents = true
        cfg.subagent_max_turns = 6
    end)

    -- A child turn whose grep demands ahead-reading (spoiler=true, a huge max_page),
    -- followed by a turn that answers in text.
    local function aheadReadingThenAnswer()
        return {
            sse.buildTurnSSE({
                blocks = { { type = "tool_use", id = "g1", name = "grep", input = {
                    query = "x",
                    spoiler = true,
                    max_page = 9999,
                } } },
                stop_reason = "tool_use",
            }),
            sse.buildTurnSSE({
                blocks = { { type = "text", text = "Found it on page 5." } },
                stop_reason = "end_turn",
            }),
        }
    end

    describe("spoiler scrub", function()
        it("forces spoiler=false and clamps max_page to the current page by default", function()
            fake:reset(aheadReadingThenAnswer())
            local text = Subagents.runSubagent({ ui = {}, settings = stubSettings, cfg = cfg, task = "trace", depth = 1 })
            assert.are.equal("Found it on page 5.", text)
            -- rec.calls[1] is the child's grep (book_context is not recorded).
            assert.are.equal("grep", rec.calls[1].name)
            assert.are.equal(false, rec.calls[1].input.spoiler)
            assert.is_true(rec.calls[1].input.max_page <= 10)
        end)

        it("passes inputs through unchanged when allow_spoiler is true", function()
            fake:reset(aheadReadingThenAnswer())
            local text = Subagents.runSubagent({
                ui = {},
                settings = stubSettings,
                cfg = cfg,
                task = "trace",
                allow_spoiler = true,
                depth = 1,
            })
            assert.are.equal("Found it on page 5.", text)
            assert.are.equal(true, rec.calls[1].input.spoiler)
            assert.are.equal(9999, rec.calls[1].input.max_page)
        end)
    end)

    it("restores the parent's last_search after a child search", function()
        local ui = { _bookbuddy_last_search = "PARENT" }
        fake:reset(aheadReadingThenAnswer())
        Subagents.runSubagent({ ui = ui, settings = stubSettings, cfg = cfg, task = "trace", depth = 1 })
        -- The child grep set it to CHILD_SEARCH mid-run; it must be back to PARENT.
        assert.are.equal("PARENT", ui._bookbuddy_last_search)
    end)

    it("refuses to start past the allowed depth and forks no stream", function()
        fake:reset({})
        local text, err = Subagents.runSubagent({ ui = {}, settings = stubSettings, cfg = cfg, task = "t", depth = 2 })
        assert.is_nil(text)
        assert.is_truthy(err)
        assert.are.equal(0, fake.idx, "depth-refused delegation must not fork a stream")
    end)

    it("refuses a blank task and forks no stream", function()
        fake:reset({})
        -- A whitespace-only task is treated as empty: trimmed, then refused before any
        -- stream is forked (the gateway may not enforce the schema's required `task`).
        local text, err = Subagents.runSubagent({ ui = {}, settings = stubSettings, cfg = cfg, task = "   ", depth = 1 })
        assert.is_nil(text)
        assert.is_truthy(err)
        assert.are.equal(0, fake.idx, "an empty-task delegation must not fork a stream")
        assert.are.equal(0, #rec.calls, "an empty-task delegation must not run any tools")
    end)

    it("stops at the turn limit and returns the best text so far", function()
        cfg.subagent_max_turns = 1
        -- With a 1-round budget the only round drops the tools, so the child answers
        -- in text immediately; that text is the result.
        fake:reset({
            sse.buildTurnSSE({ blocks = { { type = "text", text = "Partial finding." } }, stop_reason = "end_turn" }),
        })
        local text = Subagents.runSubagent({ ui = {}, settings = stubSettings, cfg = cfg, task = "t", depth = 1 })
        assert.are.equal("Partial finding.", text)
        assert.are.equal(0, #rec.calls, "the last round must not be allowed to call tools")
    end)

    describe("parent delegate branch", function()
        local function newConv()
            return Conversation:new({ ui = {}, settings = stubSettings, selected_text = "the passage" })
        end

        -- Scan every parent wire message for a tool_use of the given name.
        local function hasToolUse(messages, name)
            for _, m in ipairs(messages) do
                if type(m.content) == "table" then
                    for _, b in ipairs(m.content) do
                        if b.type == "tool_use" and b.name == name then
                            return true
                        end
                    end
                end
            end
            return false
        end

        it("isolates the child's tool churn from the parent's resent history", function()
            fake:reset({
                -- parent delegates
                sse.buildTurnSSE({
                    blocks = { { type = "tool_use", id = "d1", name = "delegate", input = { task = "trace the locket" } } },
                    stop_reason = "tool_use",
                }),
                -- child round 1: a grep (intermediate churn)
                sse.buildTurnSSE({
                    blocks = { { type = "tool_use", id = "g1", name = "grep", input = { query = "locket" } } },
                    stop_reason = "tool_use",
                }),
                -- child round 2: the condensed answer
                sse.buildTurnSSE({
                    blocks = { { type = "text", text = "The locket appears on pages 3 and 7." } },
                    stop_reason = "end_turn",
                }),
                -- parent's final answer using the child's result
                sse.buildTurnSSE({
                    blocks = { { type = "text", text = "Here is what I found about the locket." } },
                    stop_reason = "end_turn",
                }),
            })
            local conv = newConv()
            conv:ask("Trace the locket.")

            assert.are.equal(0, #sse.validateMessages(conv.messages), "parent history must stay valid")
            -- the delegate tool_use is in the parent history...
            assert.is_true(hasToolUse(conv.messages, "delegate"))
            -- ...but the child's grep churn is NOT.
            assert.is_false(hasToolUse(conv.messages, "grep"))
            -- and only the condensed result entered the parent as the tool_result.
            local found
            for _, m in ipairs(conv.messages) do
                if type(m.content) == "table" then
                    for _, b in ipairs(m.content) do
                        if b.type == "tool_result" then
                            found = b.content
                        end
                    end
                end
            end
            assert.are.equal("The locket appears on pages 3 and 7.", found)
        end)

        it("surfaces a live step counter on the Researching line while the child runs", function()
            -- Capture every viewer repaint (the stub only keeps the latest) so we can
            -- assert the in-flight "(step N/…)" feedback was actually painted, then cleared.
            local painted = {}
            local orig_update = chatviewer.updateText
            chatviewer.updateText = function(v, text)
                painted[#painted + 1] = text
                return orig_update(v, text)
            end
            finally(function()
                chatviewer.updateText = orig_update
            end)

            fake:reset({
                -- parent delegates
                sse.buildTurnSSE({
                    blocks = { { type = "tool_use", id = "d1", name = "delegate", input = { task = "trace the locket" } } },
                    stop_reason = "tool_use",
                }),
                -- child round 1: a grep (intermediate churn)
                sse.buildTurnSSE({
                    blocks = { { type = "tool_use", id = "g1", name = "grep", input = { query = "locket" } } },
                    stop_reason = "tool_use",
                }),
                -- child round 2: the condensed answer
                sse.buildTurnSSE({
                    blocks = { { type = "text", text = "The locket appears on pages 3 and 7." } },
                    stop_reason = "end_turn",
                }),
                -- parent's final answer
                sse.buildTurnSSE({
                    blocks = { { type = "text", text = "Here is what I found." } },
                    stop_reason = "end_turn",
                }),
            })
            local conv = newConv()
            conv:ask("Trace the locket.")

            -- At least one mid-run repaint showed a step counter against the max budget...
            local saw_step = false
            for _, text in ipairs(painted) do
                if text:find("%(step %d+/6%)") then
                    saw_step = true
                    break
                end
            end
            assert.is_true(saw_step, "a live (step N/6) counter must reach the viewer during delegation")
            -- ...and the counter is gone from the settled transcript: the Researching line
            -- is restored to its base phrase plus the clean "done" summary.
            assert.is_nil(conv:_transcriptText():find("%(step"), "the step counter must not linger after the child finishes")
        end)

        it("turns a failed child into a recoverable tool_result the parent continues from", function()
            fake:reset({
                -- parent delegates
                sse.buildTurnSSE({
                    blocks = { { type = "tool_use", id = "d1", name = "delegate", input = { task = "trace" } } },
                    stop_reason = "tool_use",
                }),
                -- child stream fails terminally (HTTP 400) -> runSubagent returns an error
                { '{"error":{"message":"bad request"}}', "X-BB-NON-200: 400" },
                -- parent recovers and answers anyway
                sse.buildTurnSSE({
                    blocks = { { type = "text", text = "I could not research that, but here is my take." } },
                    stop_reason = "end_turn",
                }),
            })
            local conv = newConv()
            conv:ask("Trace it.")

            assert.are.equal(0, #sse.validateMessages(conv.messages), "parent history must stay valid")
            assert.is_false(conv.stop_requested, "a child error must not look like a reader Stop")
            -- the tool_result carries the recoverable error note, and the parent's
            -- final answer is present (it continued past the failure).
            local result_text, final_text
            for _, m in ipairs(conv.messages) do
                if type(m.content) == "table" then
                    for _, b in ipairs(m.content) do
                        if b.type == "tool_result" then
                            result_text = b.content
                        elseif b.type == "text" then
                            final_text = b.text
                        end
                    end
                end
            end
            assert.is_truthy(result_text and result_text:find("did not complete"))
            assert.are.equal("I could not research that, but here is my take.", final_text)
        end)
    end)
end)
