-- Tier 3 headless eval driver (.plans/tier3-promptfoo.md): runs the GENUINE
-- bbconversation loop against a real model over a real crengine ReaderUI
-- (juliet.epub). This is the walking skeleton's core risk — the headless pump —
-- settled in one place so promptfoo can drive the real agent via an `exec:`
-- provider.
--
-- Run ONLY inside the koreader runtime assembled by `nix run .#eval-driver` (the
-- same env block as `.#test-real`: cwd=${ko}, LUA_PATH/CPATH, KO_HOME, SDL dummy)
-- plus the credentialed real-model call. It is NOT part of `.#check`.
--
-- Contract: read the task from arg[1], drive one bbconversation:_loop() to a
-- terminal branch, then emit ONE ProviderResponse JSON:
--   {"output": "<final text>", "metadata": {"trace":[...], "usage":{...}, "error":<opt>}}
-- Always include `output` (even "") so promptfoo never chokes.

-- 1. Bootstrap the koreader runtime exactly as the busted helper does, BEFORE
--    commonrequire (run inside open_book) writes into KO_HOME / loads FFI libs.
local lfs = require("libs/libkoreader-lfs")
lfs.mkdir(os.getenv("KO_HOME") or ".")
require("ffi/loadlib")

-- 1b. rapidjson (a standalone C module on LUA_CPATH, no commonrequire needed) is
--     loaded up front so the per-test context (promptfoo's argv[3] = JSON) can be
--     decoded BEFORE open_book — the resolved epub selects which book we open.
local rapidjson = require("rapidjson")

-- 1c. Parse the promptfoo context ONCE into ctx_vars. Both resolveEpub (below) and
--     resolveStartPage (further down) read it; env vars remain the global fallback
--     for the .#eval-driver isolation harness, which passes only arg[1].
local ctx_vars = {}
do
    local ctx_json = arg and arg[3]
    if ctx_json and ctx_json ~= "" then
        local ok, ctx = pcall(rapidjson.decode, ctx_json)
        if ok and type(ctx) == "table" and type(ctx.vars) == "table" then
            ctx_vars = ctx.vars
        end
    end
end

-- 1d. Resolve which epub to open. A per-test `epub` var wins: absolute paths are
--     used as-is; a bare name resolves against BB_EPUB_DIR (the flake's test-data
--     base). nil → open_book falls back to BB_SAMPLE_EPUB / the in-tree default.
local function resolveEpub()
    local e = ctx_vars.epub
    if type(e) == "string" and e ~= "" then
        if e:sub(1, 1) == "/" then
            return e
        end
        local base = os.getenv("BB_EPUB_DIR")
        return (base and base ~= "") and (base .. "/" .. e) or e
    end
    return nil
end
local resolved_epub = resolveEpub()

-- 1e. Resolve an optional fixture .sdr to pre-seed (highlights/notes + memory). A
--     per-test `seed_sdr` var wins; BB_SEED_SDR is the env fallback. A bare name
--     resolves against BB_FIXTURE_DIR (the flake exports it = tests/eval/fixtures);
--     an absolute path is used as-is. nil → no seeding (the empty-.sdr baseline).
local function resolveSeedSdr()
    local s = ctx_vars.seed_sdr
    if type(s) ~= "string" or s == "" then
        s = os.getenv("BB_SEED_SDR")
    end
    if type(s) ~= "string" or s == "" then
        return nil
    end
    if s:sub(1, 1) == "/" then
        return s
    end
    local base = os.getenv("BB_FIXTURE_DIR")
    return (base and base ~= "") and (base .. "/" .. s) or s
end
local seed_sdr = resolveSeedSdr()

-- 1f. Memory is offered to the model only when enabled (the memory gate in Conversation:new) AND a
--     writable sidecar exists. Off by default (cheaper, deterministic); a per-test
--     `enable_memory` var or BB_ENABLE_MEMORY turns it on for memory scenarios.
local function resolveEnableMemory()
    local m = ctx_vars.enable_memory
    if m == nil then
        return os.getenv("BB_ENABLE_MEMORY") == "1"
    end
    return m == true
end
local enable_memory = resolveEnableMemory()

-- 1g. Subagent delegation is feature-gated (default off, like memory): the `delegate`
--     tool is stripped from the parent's specs AND the DELEGATE_NOTE from the system
--     prompt unless enable_subagents is on (see Conversation:new + Anthropic.buildBody,
--     both keyed on cfg.enable_subagents). A per-test `enable_subagents` var wins;
--     BB_ENABLE_SUBAGENTS is the env fallback for the isolation harness. Off by default
--     keeps the non-delegation scenarios cheap and the tool out of their trace.
local function resolveEnableSubagents()
    local s = ctx_vars.enable_subagents
    if s == nil then
        return os.getenv("BB_ENABLE_SUBAGENTS") == "1"
    end
    return s == true
end
local enable_subagents = resolveEnableSubagents()

-- 1h. The clarifying-question tool (ask_user) ships ON by default -- unlike memory and
--     subagents, only an explicit enable_clarifying_questions=false strips it (see
--     Conversation:new + the ASK_USER_NOTE gate in Anthropic.buildBody, both keyed on
--     `~= false`). A per-test var can force it either way; absent, it follows the
--     production default (on). Scenarios that assert on an ask_user call set it true to
--     declare the dependency explicitly rather than leaning on the default. The headless
--     hang the tool would otherwise cause is handled at the seam in section 5 (_askUser
--     is stubbed to a skip), so enabling it here is safe.
local function resolveEnableClarifyingQuestions()
    local q = ctx_vars.enable_clarifying_questions
    if q == nil then
        local env = os.getenv("BB_ENABLE_CLARIFYING_QUESTIONS")
        if env == nil or env == "" then
            return true -- production default
        end
        return env == "1"
    end
    return q == true
end
local enable_clarifying_questions = resolveEnableClarifyingQuestions()

-- 2. Open a real ReaderUI over the resolved epub (runs commonrequire/disable_plugins,
--    which set up the require paths + globals the rest depends on). The test env uses
--    the "dir" sidecar location (centralized under KO_HOME/docsettings), so the
--    sidecar is writable even though the epub is in the read-only store — seeding a
--    fixture and memory both just need that, no epub copy. open_book seeds the
--    sidecar (if seed_sdr) before ReaderUI:new so the annotations load on open.
local support = require("tests.integration.real.support")
local readerui, Tools = support.open_book(resolved_epub, { seed_sdr = seed_sdr })

-- 3. Real loop + helpers, pulled in only after commonrequire prepared the runtime.
local Conversation = require("bbconversation")
local UIManager = require("ui/uimanager")
local Trapper = require("ui/trapper")
local T = require("ffi/util").template

-- Emit exactly ONE ProviderResponse JSON: a clean copy to BB_EVAL_OUT (if set) and
-- the same to stdout for promptfoo's exec provider. Flush so a following os.exit
-- can't drop the buffered stdout.
local function emit(payload)
    local json = rapidjson.encode(payload)
    local out_path = os.getenv("BB_EVAL_OUT")
    if out_path and out_path ~= "" then
        local f = io.open(out_path, "w")
        if f then
            f:write(json)
            f:close()
        end
    end
    io.write(json, "\n")
    io.flush()
end

-- 4. Settings shim: getConfig() is the whole surface bbconversation/bbanthropic
--    touch. A cheaper eval model, thinking + memory OFF. max_turns mirrors the
--    production default (bbsettings DEFAULTS.max_turns = 20): a tighter budget (the
--    old 8) manufactured a forced no-tools last round on a ~7-call chapter recap,
--    where a still-mid-chapter model that the <completeness> block forbids from
--    concluding returned an empty reply -> "(no response)". The real reader budget
--    doesn't trip that, so the eval shouldn't either.
--    The API key flows in from the environment and is never logged or echoed.
local config = {
    base_url = os.getenv("BB_BASE_URL") or "https://openrouter.ai/api",
    api_key = os.getenv("BB_API_KEY"),
    model = os.getenv("BB_EVAL_MODEL") or "anthropic/claude-opus-4.8",
    max_tokens = tonumber(os.getenv("BB_MAX_TOKENS")) or 8000,
    max_turns = tonumber(os.getenv("BB_MAX_TURNS")) or 20,
    additional_system_prompt = "",
    enable_memory = enable_memory,
    enable_subagents = enable_subagents,
    enable_clarifying_questions = enable_clarifying_questions,
    enable_thinking = false,
    -- confirm_spoilers stays at the PRODUCTION default (on). The headless deadlock it
    -- would otherwise cause is fixed at the UI seam in section 5 (auto-approve), not by
    -- disabling the feature here -- so the eval runs the model against the same config a
    -- real reader ships with, and the spoiler-safety asserts still grade the model's own
    -- judgement (wickham_portrait_spoiler_free.js, no_fabricated_passage.js).
}
local settings = {
    getConfig = function()
        return config
    end,
}

local conv = Conversation:new({ ui = readerui, settings = settings })

-- 5. Neutralize the UI seams: no widgets exist headless, so the viewer / flush /
--    render methods become no-ops. Surfaced errors are captured, not shown.
local function noop() end
conv._ensureStreamingViewer = noop
conv._scheduleFlush = noop
conv._flushNow = noop
conv._render = noop
conv._closeViewer = noop
-- Reader-input dialogs: both _confirmSpoiler and _askUser PARK the turn's coroutine on
-- a ButtonDialog and only resume from a button callback (or the onCloseWidget net). No
-- reader exists here to tap one, so the resume never fires, _loop never returns, and the
-- forever-mode pump busy-spins UIManager:run() at 100% CPU indefinitely. Same seam as the
-- render/viewer no-ops above: neutralize the METHODS so the loop proceeds without a widget,
-- rather than disabling the features in config (which would run the model against a
-- non-production setup). _confirmSpoiler auto-APPROVES -- a cooperative reader who taps
-- "Allow" -- because several scenarios are designed for the model to read ahead (e.g. the
-- Verona hit sits past the reader); the spoiler-safety asserts still grade whether the
-- model LEAKS, which is the property under test. _askUser returns a SKIP-shaped answer so
-- the tool_use stays answered (an unanswered one would 400 on the next resend) and the
-- model proceeds on its own judgement; a scenario that means to test ask_user would need a
-- scripted reply here instead.
conv._confirmSpoiler = function()
    return true
end
conv._askUser = function()
    return "[No reader is available to answer in this environment; proceed using your best judgement and the text itself.]",
        "skipped"
end
local captured_error
conv._showError = function(_self, res)
    captured_error = res
end
-- The read-error / cancel branches call UIManager:show(InfoMessage) directly, so
-- intercept show() for the duration of the run to capture (not paint) them.
local orig_show = UIManager.show
UIManager.show = function(_self, widget)
    if widget and widget.text and not captured_error then
        captured_error = { error_message = tostring(widget.text) }
    end
end

-- 5b. Optional reader positioning, so spoiler gates have a real "current page"
--     boundary. A per-test var wins (promptfoo passes the context as argv[3] = JSON
--     → vars.start_page); BB_START_PAGE is the global fallback for the isolation
--     harness (.#eval-driver passes only the task as arg[1], no context). Navigation
--     uses the same GotoPage path the real navigate spec exercises, so the reader
--     truly lands there before the turn is seeded.
local function resolveStartPage()
    local p = tonumber(ctx_vars.start_page)
    if p then
        return p
    end
    return tonumber(os.getenv("BB_START_PAGE"))
end
local start_page = resolveStartPage()
if start_page and start_page > 0 then
    Tools.execute("navigate", { page = start_page }, readerui)
end

-- 6. Seed the first user turn exactly as Conversation:ask() does for a book-level
--    chat (no highlighted selection): book_context + the task question.
local task = (arg and arg[1]) or "Highlight the first mention of Verona."
local context = Tools.execute("book_context", {}, readerui)
local current_page = tonumber(context:match("Current page:%s*(%d+)"))
conv.messages[1] = {
    role = "user",
    content = T("<book_context>\n%1\n</book_context>\n\n<question>\n%2\n</question>", context, task),
}
conv.transcript[1] = { role = "user", text = task }

-- 6b. BB_DRY_RUN: a zero-cost harness smoke path — position + seed, then report the
--     reader state WITHOUT a model call. Lets scenarios verify start_page wiring and
--     the spoiler boundary for free. (os.exit, not `return`: a bare return is only
--     legal as a chunk's last statement.)
if os.getenv("BB_DRY_RUN") then
    -- BB_PROBE_GREP: a deterministic, zero-cost way to capture a phrase's real
    -- page anchor for a new scenario. Greps with spoiler=true (whole book, no
    -- gate) so the raw "[page N] (loc:…)" lines land in metadata.probe_grep —
    -- the page/loc the create_highlight/read asserts will key on. (No model.)
    local probe_query = os.getenv("BB_PROBE_GREP")
    local probe_grep
    if probe_query and probe_query ~= "" then
        probe_grep = Tools.execute("grep", { query = probe_query, spoiler = true }, readerui)
    end
    emit({
        output = "",
        metadata = {
            dry_run = true,
            epub = resolved_epub,
            seed_sdr = seed_sdr,
            enable_memory = enable_memory,
            enable_subagents = enable_subagents,
            enable_clarifying_questions = enable_clarifying_questions,
            start_page = start_page,
            current_page = current_page,
            probe_grep = probe_grep,
            seeded_highlights = Tools.execute("get_highlights", {}, readerui),
        },
    })
    pcall(support.close_book, readerui)
    os.exit(0)
end

-- 7. Pump: drive _loop directly (bypassing run()'s NetworkMgr gate) inside a
--    Trapper coroutine, and run UIManager until the loop hits a terminal branch
--    and our wrapper quits it. Mirrors koreader's own spec pump idiom
--    (spec/unit/httpclient_spec.lua: setRunForeverMode + an explicit quit).
local done, loop_ok, loop_err = false, nil, nil
UIManager:setRunForeverMode()
Trapper:wrap(function()
    loop_ok, loop_err = pcall(function()
        conv:_loop()
    end)
    done = true
    UIManager:quit()
end)
if not done then
    UIManager:run()
end
UIManager.show = orig_show

-- 8. Reconstruct the ordered tool trace from the wire history, pairing each
--    tool_use with its tool_result text (which carries the resolved page numbers
--    the deterministic asserts key on).
local results_by_id = {}
for _, m in ipairs(conv.messages) do
    if m.role == "user" and type(m.content) == "table" then
        for _, b in ipairs(m.content) do
            if b.type == "tool_result" and b.tool_use_id then
                results_by_id[b.tool_use_id] = b.content
            end
        end
    end
end
local trace = {}
for _, m in ipairs(conv.messages) do
    if m.role == "assistant" and type(m.content) == "table" then
        for _, b in ipairs(m.content) do
            if b.type == "tool_use" then
                trace[#trace + 1] = {
                    name = b.name,
                    input = b.input or {},
                    result = results_by_id[b.id],
                }
            end
        end
    end
end

-- 9. Final prose = the text blocks of the last assistant message (the model's
--    answer), not the "You:/BookBuddy:"-prefixed transcript.
local final_text = ""
for i = #conv.messages, 1, -1 do
    local m = conv.messages[i]
    if m.role == "assistant" and type(m.content) == "table" then
        local parts = {}
        for _, b in ipairs(m.content) do
            if b.type == "text" and b.text and b.text ~= "" then
                parts[#parts + 1] = b.text
            end
        end
        if #parts > 0 then
            final_text = table.concat(parts, "\n")
            break
        end
    end
end

-- 10. Error metadata: a loop crash, a surfaced gateway/network error, or nothing.
local err
if not loop_ok then
    err = tostring(loop_err)
elseif captured_error then
    err = captured_error.error_message
        or (captured_error.code and ("gateway HTTP " .. tostring(captured_error.code)))
        or "unknown error"
end

emit({
    output = final_text or "",
    metadata = {
        trace = trace,
        usage = conv.usage,
        -- The terminal turn's stop_reason (nil if the loop never completed a turn).
        -- The signal that was invisible while diagnosing the empty "(no response)"
        -- draw: nil => gateway sent no message_delta (transport artifact); "end_turn"
        -- => the model ended its turn with no content (over-pressure); "max_tokens"
        -- => budget. Pairs with output == "(no response)" to classify a hit.
        stop_reason = conv.last_stop_reason,
        error = err,
        epub = resolved_epub,
        seed_sdr = seed_sdr,
        enable_memory = enable_memory,
        enable_subagents = enable_subagents,
        enable_clarifying_questions = enable_clarifying_questions,
        start_page = start_page,
        current_page = current_page,
    },
})

pcall(support.close_book, readerui)
