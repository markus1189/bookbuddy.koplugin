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

-- 2. Open a real ReaderUI over the resolved epub (runs commonrequire/disable_plugins,
--    which set up the require paths + globals the rest depends on).
local support = require("tests.integration.real.support")
local readerui, Tools = support.open_book(resolved_epub)

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
--    touch. A cheaper eval model, thinking + memory OFF, a modest turn budget.
--    The API key flows in from the environment and is never logged or echoed.
local config = {
    base_url = os.getenv("BB_BASE_URL") or "https://openrouter.ai/api",
    api_key = os.getenv("BB_API_KEY"),
    model = os.getenv("BB_EVAL_MODEL") or "anthropic/claude-opus-4.8",
    max_tokens = tonumber(os.getenv("BB_MAX_TOKENS")) or 8000,
    max_turns = tonumber(os.getenv("BB_MAX_TURNS")) or 8,
    additional_system_prompt = "",
    enable_memory = false,
    enable_thinking = false,
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
            start_page = start_page,
            current_page = current_page,
            probe_grep = probe_grep,
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
        error = err,
        epub = resolved_epub,
        start_page = start_page,
        current_page = current_page,
    },
})

pcall(support.close_book, readerui)
