-- luacheck: std +busted
-- luacheck: globals disable_plugins G_reader_settings
-- (disable_plugins / G_reader_settings are injected as globals by koreader's
--  commonrequire; the filename omits the _spec suffix on purpose — see .busted:
--  tests/integration/* is run by explicit path under `nix run .#test-real`.)
--
-- The ask_user clarifying-question tool against REAL KOReader widgets (Tier 2).
-- This is the timing tier-1 can only fake: Conversation:_askUser parks the turn-loop
-- coroutine on a coroutine.yield() while REAL ButtonDialog / InputDialog / CheckButton
-- widgets are up on the REAL UIManager, and every dialog close path -- plus every
-- mid-batch advance to the NEXT question -- must cross the real UIManager task queue.
-- tests/question_tool_spec.lua drives this through hand-written dialog doubles that merely
-- ASSUME KOReader fires onCloseWidget on a dismissal and runs nextTick callbacks; here the
-- real widgets and the real UIManager prove that assumption end to end, including the
-- batched multi-question stepping and the CheckButton-hosted multi-select step.
--
-- _askUser reads nothing off `self` beyond its own methods (it works through
-- coroutine.running(), the module-level widget requires, and its `input`), so we drive it
-- on a bare instance whose metatable indexes Conversation: faithful, and free of a full
-- Conversation:new + streaming stack.

local support = require("tests.integration.real.support")

describe("ask_user against real KOReader dialogs", function()
    local UIManager, Conversation, readerui
    local saved_flash_ui
    -- The recoverable note _askUser returns on every all-skipped/dismiss path; we match a
    -- stable substring rather than the whole sentence so a copy tweak doesn't brick the spec.
    local SKIP_MARK = "without answering"

    setup(function()
        -- Brings in commonrequire + disable_plugins and opens a real ReaderUI over
        -- juliet.epub, which is what makes the real UIManager and widget stack live.
        readerui = support.open_book()
        UIManager = require("ui/uimanager")
        Conversation = require("bbconversation")
        -- flash_ui off makes Button:onTapSelectButton / CheckButton:onTapCheckButton take
        -- their no-paint branch (straight to the callback + toggle), so a simulated tap
        -- doesn't drive the eInk refresh dance that is meaningless in a headless run. This
        -- is a real user setting, not a test hack.
        saved_flash_ui = G_reader_settings:readSetting("flash_ui")
        G_reader_settings:saveSetting("flash_ui", false)
    end)

    teardown(function()
        G_reader_settings:saveSetting("flash_ui", saved_flash_ui)
        support.close_book(readerui)
    end)

    -- The dialog currently on top of the real UIManager window stack.
    local function topWidget()
        local stack = UIManager._window_stack
        return stack[#stack] and stack[#stack].widget or nil
    end

    -- A real InputDialog shows a VirtualKeyboard, which gets pushed ABOVE the dialog on
    -- the window stack -- so topWidget() would hand back the keyboard, not the dialog.
    -- Identify the InputDialog by its setInputText method and scan from the top down.
    local function findInputDialog()
        local stack = UIManager._window_stack
        for i = #stack, 1, -1 do
            local w = stack[i].widget
            if type(w.setInputText) == "function" then
                return w
            end
        end
        return nil
    end

    -- Fire the real tap handler of the Button carrying `label` inside a dialog's real
    -- ButtonTable (ButtonDialog exposes `buttontable`, InputDialog `button_table`). The
    -- Button widgets are the ones KOReader built from the rows _askUser passed in, so
    -- this runs exactly the callback the tool wired -- through the real widget, not a stub.
    local function tapButton(widget, label)
        local bt = widget.buttontable or widget.button_table
        assert.is_not_nil(bt, "dialog has no button table")
        for _, row in ipairs(bt.buttons_layout) do
            for _, btn in ipairs(row) do
                if btn.text == label then
                    btn:onTapSelectButton()
                    return true
                end
            end
        end
        return false
    end

    -- The real CheckButtons a multi-select step added to its InputDialog, in option order.
    -- addWidget wraps each in a CenterContainer stored on _added_widgets; the CheckButton
    -- is that container's positional child. Tapping one runs the real toggle (flash_ui off).
    local function checkBoxes(input_dialog)
        local out = {}
        for _, wrapped in ipairs(input_dialog._added_widgets or {}) do
            out[#out + 1] = wrapped[1]
        end
        return out
    end

    -- Drain the real UIManager task queue -- where _askUser's finish() parks the coroutine
    -- resume via UIManager:nextTick -- until the asked coroutine finishes. Bounded, so a
    -- genuine hang fails the assertion instead of spinning forever.
    local function pumpUntilDead(co)
        for _ = 1, 100 do
            if coroutine.status(co) == "dead" then
                return true
            end
            UIManager:_checkTasks()
        end
        return coroutine.status(co) == "dead"
    end

    -- Start _askUser on a fresh coroutine; it builds and shows the first real dialog and
    -- parks at coroutine.yield(). Returns (co, answer) where answer() reads the string the
    -- method returned once the coroutine has been resumed to completion.
    local function park(input)
        local conv = setmetatable({}, { __index = Conversation })
        local result
        local co = coroutine.create(function()
            result = conv:_askUser(input)
        end)
        local ok, err = coroutine.resume(co)
        assert.is_true(ok, "askUser errored on first resume: " .. tostring(err))
        assert.are.equal("suspended", coroutine.status(co), "askUser did not park on the dialog")
        return co, function()
            return result
        end
    end

    -- Convenience: a one-question batch with single-select options.
    local function one(question, labels)
        local opts = {}
        for _, l in ipairs(labels or {}) do
            opts[#opts + 1] = { label = l }
        end
        return { questions = { { question = question, options = (labels and opts) or nil } } }
    end

    it("parks on a real ButtonDialog and returns the tapped option in a serialized block", function()
        local co, answer = park(one("Which character?", { "Tom", "Sid" }))
        assert.is_not_nil(topWidget())
        assert.is_true(tapButton(topWidget(), "Tom"))
        assert.is_true(pumpUntilDead(co), "the loop never resumed after a real option tap")
        assert.is_not_nil(tostring(answer()):find("A1. Tom", 1, true))
    end)

    it("does NOT hang when a real ButtonDialog is dismissed without a button (no-hang invariant)", function()
        local co, answer = park(one("Which character?", { "Tom", "Sid" }))
        -- onClose() is KOReader's real tap-outside / Back path: UIManager:close -> the
        -- CloseWidget event -> our onCloseWidget override -> dismiss(). Exactly the
        -- close-dispatch tier-1 can only emulate with a stub onCloseWidget.
        topWidget():onClose()
        assert.is_true(pumpUntilDead(co), "the loop parked forever on a bare dismissal")
        assert.is_not_nil(tostring(answer()):find(SKIP_MARK, 1, true))
    end)

    it("returns the recoverable skip note when the real Skip button is tapped", function()
        local co, answer = park(one("Which character?", { "Tom", "Sid" }))
        assert.is_true(tapButton(topWidget(), "Skip"))
        assert.is_true(pumpUntilDead(co))
        assert.is_not_nil(tostring(answer()):find(SKIP_MARK, 1, true))
    end)

    it("hands a real ButtonDialog off to a real free-text InputDialog and returns the typed answer", function()
        local co, answer = park(one("Which one?", { "A", "B" }))
        -- "Type my own…" closes the ButtonDialog WITHOUT resolving (closing guards the
        -- onCloseWidget fallback) and opens the InputDialog, which then owns the resume.
        assert.is_true(tapButton(topWidget(), "Type my own…"))
        local input = findInputDialog()
        assert.is_not_nil(input)
        input:setInputText("neither, I meant C")
        assert.is_true(tapButton(input, "Send"))
        assert.is_true(pumpUntilDead(co), "the loop never resumed after the free-text Send")
        assert.is_not_nil(tostring(answer()):find("A1. neither, I meant C", 1, true))
    end)

    it("goes straight to a real InputDialog with no options and treats an empty Send as skip", function()
        local co, answer = park(one("What did you mean?"))
        local input = findInputDialog()
        assert.is_not_nil(input)
        -- leave the field empty: an empty Send resolves to the recoverable skip note
        assert.is_true(tapButton(input, "Send"))
        assert.is_true(pumpUntilDead(co))
        assert.is_not_nil(tostring(answer()):find(SKIP_MARK, 1, true))
    end)

    it("hosts real CheckButtons for a multi-select step and returns the checked labels", function()
        local co, answer = park({
            questions = {
                {
                    question = "Which themes?",
                    multiSelect = true,
                    options = { { label = "Loyalty" }, { label = "Fate" }, { label = "Honour" } },
                },
            },
        })
        local input = findInputDialog()
        assert.is_not_nil(input)
        local boxes = checkBoxes(input)
        assert.are.equal(3, #boxes)
        boxes[1]:onTapCheckButton() -- Loyalty
        boxes[3]:onTapCheckButton() -- Honour
        assert.is_true(tapButton(input, "Next →"))
        assert.is_true(pumpUntilDead(co), "the loop never resumed after the multi-select Next")
        assert.is_not_nil(tostring(answer()):find("A1. Loyalty, Honour", 1, true))
    end)

    it("steps a real multi-question batch forward and resumes exactly once at the end", function()
        local co, answer = park({
            questions = {
                { question = "Which character?", options = { { label = "Tom" }, { label = "Sid" } } },
                { question = "How far back?", options = { { label = "This chapter" }, { label = "The book" } } },
            },
        })
        -- First step: a real ButtonDialog. Tapping an option advances to the SECOND
        -- question on the UI loop WITHOUT resuming the parked coroutine.
        assert.is_true(tapButton(topWidget(), "Tom"))
        assert.are.equal("suspended", coroutine.status(co), "resumed early -- the batch did not advance")
        assert.is_true(tapButton(topWidget(), "The book"))
        assert.is_true(pumpUntilDead(co), "the loop never resumed after the last question")
        local a = tostring(answer())
        assert.is_not_nil(a:find("A1. Tom", 1, true))
        assert.is_not_nil(a:find("A2. The book", 1, true))
    end)
end)
