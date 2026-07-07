-- The ask_user clarifying-question tool: the tool spec + childSpecs exclusion + the
-- Conversation:new gate (real bbtools), and the dispatch branch / _askUser pause-resume
-- behaviour driven by scripted SSE through the real bbconversation. The reader dialog is
-- a double that fires a scripted choice through the same nextTick pump Trapper:wrap drains,
-- so a whole ask-then-answer turn completes synchronously inside conv:ask().
local stubs = require("support.stubs")
local sse = require("support.sse")

describe("ask_user tool spec", function()
    it("getSpecs advertises ask_user with questions[] required and {label,description} options", function()
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
        assert.is_true(required.questions)
        local qitems = spec.input_schema.properties.questions.items
        assert.is_not_nil(qitems.properties.question)
        assert.is_not_nil(qitems.properties.multiSelect)
        assert.is_not_nil(qitems.properties.options)
        -- Options are {label, description} objects now, not bare strings; label required.
        local oitems = qitems.properties.options.items
        assert.are.equal("object", oitems.type)
        assert.is_not_nil(oitems.properties.label)
        assert.is_not_nil(oitems.properties.description)
        assert.are.equal("label", oitems.required[1])
    end)

    it("has no executor: ask_user is special-cased in bbconversation, not dispatched by bbtools", function()
        local Tools = stubs.load_tools()
        local r = Tools.execute("ask_user", { questions = { { question = "x" } } }, {})
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
        stubs.install_bbchats_stub()
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
        stubs.install_bbchats_stub()
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
                -- Multi-select hosts its CheckButtons on the InputDialog via addWidget;
                -- record them on o so a test's autofire can flip o._added[i].checked.
                o._added = {}
                o.addWidget = function(self_o, w)
                    self_o._added[#self_o._added + 1] = w
                end
                scheduleAuto(o, true)
                return o
            end,
        }
        -- CheckButton double: real init needs the widget stack, so stub it to a bare
        -- selection cell. A real tap toggles .checked; here the test sets it directly.
        package.loaded["ui/widget/checkbutton"] = {
            new = function(_, o)
                o = o or {}
                o.checked = o.checked or false
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

    -- Build a one-question ask_user input from a question string and a list of option
    -- LABELS (the new schema wants {label, description} objects; description is optional).
    local function one(question, labels)
        local q = { question = question }
        if labels then
            q.options = {}
            for _, l in ipairs(labels) do
                q.options[#q.options + 1] = { label = l }
            end
        end
        return { questions = { q } }
    end

    -- A one-question multi-select input from a question string and option LABELS.
    local function multi(question, labels)
        local opts = {}
        for _, l in ipairs(labels) do
            opts[#opts + 1] = { label = l }
        end
        return { questions = { { question = question, multiSelect = true, options = opts } } }
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

    local function has(s, sub)
        return tostring(s):find(sub, 1, true) ~= nil
    end

    -- Reaching the second request proves the loop RESUMED past the paused question (a
    -- hang would leave the coroutine parked with only the first request sent).
    local function resumed()
        return fake.idx == 2
    end

    it("returns the chosen option in a serialized Q/A block and continues the turn", function()
        local conv = run(one("Which character?", { "Tom", "Sid" }), function(o, is_input)
            assert.is_false(is_input)
            o.buttons[1][1].callback() -- tap the first option, "Tom"
        end)
        assert.is_true(resumed())
        local ans = answerOf(conv)
        assert.is_true(has(ans, "Q1. Which character?"))
        assert.is_true(has(ans, "A1. Tom"))
        -- The question is folded into the "Asked: …" transcript line, with the outcome.
        assert.is_true(has(chatviewer.last_text, "Asked: Which character?"))
        assert.is_true(has(chatviewer.last_text, "answered 1 of 1"))
        assert.are.equal(0, #sse.validateMessages(conv.messages))
    end)

    it("returns free-text the reader typed when no options are offered", function()
        local conv = run(one("What did you mean?"), function(o, is_input)
            assert.is_true(is_input) -- no options -> straight to the free-text dialog
            o.buttons[1][2].callback() -- Send
        end, "the second chapter")
        assert.is_true(resumed())
        assert.is_true(has(answerOf(conv), "A1. the second chapter"))
    end)

    it("routes 'Type my own…' to the free-text dialog and returns the typed answer", function()
        local conv = run(one("Which one?", { "A", "B" }), function(o, is_input)
            if not is_input then
                o.buttons[#o.buttons][1].callback() -- "Type my own…" (last row, first col)
            else
                o.buttons[1][2].callback() -- Send on the free-text dialog
            end
        end, "neither, I meant C")
        assert.is_true(resumed())
        assert.is_true(has(answerOf(conv), "A1. neither, I meant C"))
    end)

    it("returns a recoverable note when the reader skips, and still answers the tool_use", function()
        local conv = run(one("Which character?", { "Tom", "Sid" }), function(o)
            o.buttons[#o.buttons][2].callback() -- "Skip" (last row, second col)
        end)
        assert.is_true(resumed())
        local note = answerOf(conv)
        assert.is_not_nil(note)
        assert.is_true(has(note, "without answering"))
        assert.is_true(has(chatviewer.last_text, "skipped"))
        assert.are.equal(0, #sse.validateMessages(conv.messages))
    end)

    it("does NOT hang when the dialog is dismissed without a button (no-hang invariant)", function()
        local conv = run(one("Which character?", { "Tom", "Sid" }), function(o)
            o.onCloseWidget(o) -- a tap-outside / Back dismissal, no button callback
        end)
        assert.is_true(resumed(), "the loop must resume after a bare dismissal, not park forever")
        assert.is_true(has(answerOf(conv), "without answering"))
    end)

    it("treats an empty free-text Send as a skip", function()
        local conv = run(one("What did you mean?"), function(o)
            o.buttons[1][2].callback() -- Send with empty input
        end, "")
        assert.is_true(resumed())
        assert.is_true(has(answerOf(conv), "without answering"))
    end)

    it("multi-select: returns the checked options comma-joined on Next", function()
        local conv = run(multi("Which themes?", { "Loyalty", "Fate", "Honour" }), function(o, is_input)
            assert.is_true(is_input) -- multi-select is hosted on the InputDialog
            o._added[1].checked = true -- Loyalty
            o._added[3].checked = true -- Honour
            o.buttons[1][2].callback() -- "Next →" (row 1, col 2)
        end)
        assert.is_true(resumed())
        assert.is_true(has(answerOf(conv), "A1. Loyalty, Honour"))
        assert.is_true(has(chatviewer.last_text, "answered 1 of 1"))
    end)

    it("multi-select: folds a typed answer in alongside the checked options", function()
        local conv = run(multi("Which themes?", { "Loyalty", "Fate" }), function(o)
            o._added[2].checked = true -- Fate
            o.buttons[1][2].callback() -- Next, with typed text below
        end, "and grief")
        assert.is_true(resumed())
        assert.is_true(has(answerOf(conv), "A1. Fate, and grief"))
    end)

    it("multi-select: nothing checked and nothing typed is a skip", function()
        local conv = run(multi("Which themes?", { "Loyalty", "Fate" }), function(o)
            o.buttons[1][2].callback() -- Next with no selection
        end)
        assert.is_true(resumed())
        assert.is_true(has(answerOf(conv), "without answering"))
    end)

    it("multi-select: does NOT hang when dismissed without a button (no-hang invariant)", function()
        local conv = run(multi("Which themes?", { "Loyalty", "Fate" }), function(o)
            o.onCloseWidget(o) -- tap-outside / Back
        end)
        assert.is_true(resumed(), "the loop must resume after a bare multi-select dismissal")
        assert.is_true(has(answerOf(conv), "without answering"))
    end)
end)
