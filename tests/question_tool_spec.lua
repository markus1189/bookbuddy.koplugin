-- The ask_user clarifying-question tool: the tool spec + childSpecs exclusion + the
-- Conversation:new gate (real bbtools), and the dispatch branch / _askUser pause-resume
-- behaviour driven by scripted SSE through the real bbconversation. The reader dialog is
-- a double that fires a scripted choice through the same nextTick pump Trapper:wrap drains,
-- so a whole ask-then-answer turn completes synchronously inside conv:ask().
local stubs = require("support.stubs")
local sse = require("support.sse")

describe("ask_user tool spec", function()
    it("getSpecs advertises ask_user with question required and options optional", function()
        local Tools = stubs.load_tools()
        local spec
        for _, t in ipairs(Tools.getSpecs()) do
            if t.name == "ask_user" then
                spec = t
            end
        end
        assert.is_not_nil(spec)
        local required = {}
        for _, k in ipairs(spec.input_schema.required) do
            required[k] = true
        end
        assert.is_true(required.question)
        assert.is_nil(required.options) -- options are optional
        assert.is_not_nil(spec.input_schema.properties.options)
    end)

    it("has no executor: ask_user is special-cased in bbconversation, not dispatched by bbtools", function()
        local Tools = stubs.load_tools()
        local r = Tools.execute("ask_user", { question = "x" }, {})
        assert.is_not_nil(tostring(r):find("unknown tool", 1, true))
    end)

    it("childSpecs excludes ask_user (a headless subagent has no reader to ask)", function()
        local Tools = stubs.load_tools()
        local names = {}
        for _, t in ipairs(Tools.childSpecs()) do
            names[t.name or t.type] = true
        end
        assert.is_nil(names.ask_user)
    end)
end)

describe("ask_user gate in Conversation:new", function()
    local Conversation
    local cfg = {}
    local stubSettings = {
        getConfig = function()
            return cfg
        end,
    }

    setup(function()
        stubs.load_tools() -- installs the KOReader doubles + the REAL bbtools
        stubs.install_bbmemory_stub()
        sse.new_fake_stream({}) -- registers the bbstream fake bbconversation requires
        package.loaded["bbconversation"] = nil
        Conversation = require("bbconversation")
    end)

    local function specNames(conv)
        local names = {}
        for _, t in ipairs(conv.tool_specs) do
            names[t.name or t.type] = true
        end
        return names
    end

    it("advertises ask_user by default when the flag is absent", function()
        cfg.enable_clarifying_questions = nil
        local conv = Conversation:new({ ui = {}, settings = stubSettings })
        assert.is_true(specNames(conv).ask_user)
    end)

    it("drops ask_user when clarifying questions are explicitly disabled", function()
        cfg.enable_clarifying_questions = false
        local conv = Conversation:new({ ui = {}, settings = stubSettings })
        assert.is_nil(specNames(conv).ask_user)
        cfg.enable_clarifying_questions = nil -- restore default for any later scenario
    end)
end)

describe("ask_user dispatch + pause/resume", function()
    local Conversation, fake, captured, chatviewer, mem
    -- Per-test dialog script: autofire(o, is_input) is called on the next tick after a
    -- dialog is shown, simulating the reader's tap; inputText feeds getInputText.
    local autofire, inputText

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
        stubs.install_bbtools_stub(h) -- registers the loop's tool double (book_context etc.)

        -- Dialog doubles that drive _askUser to completion through the nextTick pump: on
        -- construction they schedule the scripted choice, which runs while Trapper:wrap is
        -- still draining, so the whole ask-then-answer turn finishes inside conv:ask().
        local UIManager = package.loaded["ui/uimanager"]
        local function scheduleAuto(o, is_input)
            UIManager:nextTick(function()
                if autofire then
                    autofire(o, is_input)
                end
            end)
        end
        package.loaded["ui/widget/buttondialog"] = {
            new = function(_, o)
                o = o or {}
                scheduleAuto(o, false)
                return o
            end,
        }
        package.loaded["ui/widget/inputdialog"] = {
            new = function(_, o)
                o = o or {}
                o.onShowKeyboard = function() end
                o.getInputText = function()
                    return inputText
                end
                scheduleAuto(o, true)
                return o
            end,
        }

        fake = sse.new_fake_stream({}, chatviewer)
        captured = (sse.capture_build_body())
        -- Force a fresh load so bbconversation captures the autofire dialog doubles above,
        -- not a copy cached by an earlier describe block (which holds the plain echo stubs
        -- and would never resolve the dialog -> the loop would park forever).
        package.loaded["bbconversation"] = nil
        Conversation = require("bbconversation")
    end)

    local function clear(t)
        for i = #t, 1, -1 do
            t[i] = nil
        end
    end

    -- Run one scenario: a first round whose assistant emits an ask_user tool_use, then a
    -- final text round. Returns the live Conversation. Asserts the universal invariants
    -- (every request validates; the loop never over-requests) like conversation_spec.
    local function run(ask_input, fire, typed)
        autofire = fire
        inputText = typed
        clear(captured)
        chatviewer.last_text = nil
        cfg.base_url, cfg.api_key, cfg.model, cfg.max_tokens = "https://example", "k", "test", 1024
        cfg.max_turns = 20
        cfg.additional_system_prompt = ""
        cfg.enable_memory, cfg.enable_thinking, cfg.show_streaming_thinking = false, false, false
        cfg.enable_web_search = true
        mem.rec.calls = {}
        mem.rec.base = nil

        fake:reset({
            sse.buildTurnSSE({
                blocks = {
                    { type = "text", text = "Let me make sure I understand." },
                    { type = "tool_use", id = "toolu_Q", name = "ask_user", input = ask_input },
                },
                stop_reason = "tool_use",
            }),
            sse.buildTurnSSE({ blocks = { { type = "text", text = "Thanks, got it." } } }),
        })

        local conv = Conversation:new({ ui = {}, settings = stubSettings, selected_text = "the passage" })
        conv:ask("Who is he?")

        for n, req in ipairs(captured) do
            assert.are.equal(0, #sse.validateMessages(req.messages), "request " .. n .. " was invalid")
        end
        assert.is_true(fake.idx <= 2, "loop requested more responses than were scripted")
        return conv
    end

    -- The tool_result content the loop committed for the ask_user tool_use.
    local function answerOf(conv)
        for _, m in ipairs(conv.messages) do
            if m.role == "user" and type(m.content) == "table" then
                for _, b in ipairs(m.content) do
                    if b.type == "tool_result" and b.tool_use_id == "toolu_Q" then
                        return b.content
                    end
                end
            end
        end
    end

    -- Reaching the second request proves the loop RESUMED past the paused question (a
    -- hang would leave the coroutine parked with only the first request sent).
    local function resumed()
        return fake.idx == 2
    end

    it("returns the chosen option as the tool_result and continues the turn", function()
        local conv = run({ question = "Which character?", options = { "Tom", "Sid" } }, function(o, is_input)
            assert.is_false(is_input)
            o.buttons[1][1].callback() -- tap the first option, "Tom"
        end)
        assert.is_true(resumed())
        assert.are.equal("Tom", answerOf(conv))
        -- The question and the answer are folded into one transcript line.
        assert.is_not_nil((chatviewer.last_text or ""):find("Asked: Which character?", 1, true))
        assert.is_not_nil((chatviewer.last_text or ""):find("Tom", 1, true))
        assert.are.equal(0, #sse.validateMessages(conv.messages))
    end)

    it("returns free-text the reader typed when no options are offered", function()
        local conv = run({ question = "What did you mean?" }, function(o, is_input)
            assert.is_true(is_input) -- no options -> straight to the free-text dialog
            o.buttons[1][2].callback() -- Send
        end, "the second chapter")
        assert.is_true(resumed())
        assert.are.equal("the second chapter", answerOf(conv))
    end)

    it("routes 'Type my own…' to the free-text dialog and returns the typed answer", function()
        local conv = run({ question = "Which one?", options = { "A", "B" } }, function(o, is_input)
            if not is_input then
                o.buttons[#o.buttons][1].callback() -- "Type my own…" (last row, first col)
            else
                o.buttons[1][2].callback() -- Send on the free-text dialog
            end
        end, "neither, I meant C")
        assert.is_true(resumed())
        assert.are.equal("neither, I meant C", answerOf(conv))
    end)

    it("returns a recoverable note when the reader skips, and still answers the tool_use", function()
        local conv = run({ question = "Which character?", options = { "Tom", "Sid" } }, function(o)
            o.buttons[#o.buttons][2].callback() -- "Skip" (last row, second col)
        end)
        assert.is_true(resumed())
        local note = answerOf(conv)
        assert.is_not_nil(note)
        assert.is_not_nil(tostring(note):find("without answering", 1, true))
        assert.is_not_nil((chatviewer.last_text or ""):find("skipped", 1, true))
        assert.are.equal(0, #sse.validateMessages(conv.messages))
    end)

    it("does NOT hang when the dialog is dismissed without a button (no-hang invariant)", function()
        local conv = run({ question = "Which character?", options = { "Tom", "Sid" } }, function(o)
            o.onCloseWidget(o) -- a tap-outside / Back dismissal, no button callback
        end)
        assert.is_true(resumed(), "the loop must resume after a bare dismissal, not park forever")
        assert.is_not_nil(tostring(answerOf(conv)):find("without answering", 1, true))
    end)

    it("treats an empty free-text Send as a skip", function()
        local conv = run({ question = "What did you mean?" }, function(o)
            o.buttons[1][2].callback() -- Send with empty input
        end, "")
        assert.is_true(resumed())
        assert.is_not_nil(tostring(answerOf(conv)):find("without answering", 1, true))
    end)
end)
