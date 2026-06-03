-- Drives the multi-turn, tool-using exchange with Claude.
--
-- The whole loop runs inside Trapper:wrap, which gives us a coroutine the
-- streaming transport can yield from (LuaJIT's main thread can't). Each Claude
-- call is streamed from a forked subprocess (network only) while the reply is
-- rendered live into the viewer; tool calls run here in the main process because
-- they touch the live document. We keep two parallel structures: `messages` (the
-- exact Anthropic wire format, resent every turn) and `transcript` (a
-- human-readable log rendered in the viewer).
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local NetworkMgr = require("ui/network/manager")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local Anthropic = require("bbanthropic")
local ChatViewer = require("bbchatviewer")
local Memory = require("bbmemory")
local Presets = require("bbpresets")
local Stream = require("bbstream")
local Tools = require("bbtools")

-- Repaint the live transcript at most this often while text streams in. The
-- transport wakes every 0.125s; coalescing to ~2.5 fps keeps e-ink usable.
local FLUSH_INTERVAL_SEC = 0.4

-- The viewer is plain text, so drop the markdown markers the model emits rather
-- than show them literally. Applied on every render (streaming and final) so the
-- text reads the same throughout; safe on the partial markdown seen mid-stream.
-- We deliberately skip "_"/"__" emphasis: it collides with snake_case and URLs.
local function stripMarkdown(text)
    if not text or text == "" then
        return text
    end
    text = text:gsub("```[%w%-]*\n?", "") -- fenced code markers
    text = text:gsub("%*%*(.-)%*%*", "%1") -- **bold**
    text = text:gsub("%*(%S.-%S)%*", "%1") -- *italic* (multi-char)
    text = text:gsub("%*(%S)%*", "%1") -- *i* (single char)
    text = text:gsub("~~(.-)~~", "%1") -- ~~strike~~
    text = text:gsub("`(.-)`", "%1") -- `inline code`
    text = text:gsub("%[(.-)%]%((.-)%)", "%1 (%2)") -- [text](url) -> text (url)
    text = text:gsub("^#+%s*", "") -- heading on the first line
    text = text:gsub("(\n)#+%s*", "%1") -- headings on later lines
    return text
end

-- Per-entry memo for stripMarkdown: _transcriptText re-renders the whole
-- transcript on every ~2.5fps flush, but only the still-streaming entry's
-- .text changes. Cache the stripped text keyed on the entry's current .text;
-- the live entry (mutating .text) misses and re-strips, finalized entries hit.
-- _renderAssistantTurn replaces live entries with fresh tables, so a stale
-- memo can never outlive its source.
local function strippedEntry(turn)
    if turn._md_src ~= turn.text then
        turn._md_src = turn.text
        turn._md_out = stripMarkdown(turn.text)
    end
    return turn._md_out
end

-- Vertex AI's request validator (unlike Anthropic's first-party API) rejects any
-- server_tool_use that lacks a paired web_search_tool_result in the same assistant
-- message. A pause_turn can stop right after the in-flight web search's
-- server_tool_use, before its result arrives, so resending that turn verbatim --
-- which the pause_turn contract otherwise prescribes -- makes the next request 400
-- ("web_search tool use ... without a corresponding web_search_tool_result block").
-- Pair each orphan with a synthetic "unavailable" error result so the resend
-- validates; the model then resumes and either retries the search (a fresh turn
-- has a fresh search budget) or answers without it.
local function pairDanglingWebSearch(content)
    if type(content) ~= "table" then
        return
    end
    local has_result = {}
    for _, b in ipairs(content) do
        if b.type == "web_search_tool_result" and b.tool_use_id then
            has_result[b.tool_use_id] = true
        end
    end
    local i = 1
    while i <= #content do
        local b = content[i]
        if b.type == "server_tool_use" and b.id and not has_result[b.id] then
            table.insert(content, i + 1, {
                type = "web_search_tool_result",
                tool_use_id = b.id,
                content = { type = "web_search_tool_result_error", error_code = "unavailable" },
            })
            has_result[b.id] = true
            i = i + 2
        else
            i = i + 1
        end
    end
end

local Conversation = {}
Conversation.__index = Conversation

function Conversation:new(o)
    o = o or {}
    setmetatable(o, self)
    o.messages = {}
    o.transcript = {}
    o.tool_specs = Tools.getSpecs()
    -- Web search is a server-side tool that only executes on a first-party
    -- Anthropic backend; endpoints routed through Vertex/Bedrock silently no-op
    -- it. When the user turns it off, stop advertising it (mirrors how Claude
    -- Code hides WebSearch on those platforms). Only an explicit false removes it,
    -- so callers that don't set the flag keep the default-on behaviour.
    if o.settings and o.settings:getConfig().enable_web_search == false then
        for i = #o.tool_specs, 1, -1 do
            local t = o.tool_specs[i]
            if type(t) == "table" and t.type == "web_search_20250305" then
                table.remove(o.tool_specs, i)
            end
        end
    end
    -- Per-conversation read state lives on the shared ui, which outlives a single
    -- Conversation, so a new chat must clear it or it inherits stale locators and
    -- search results. (Also fixes the long-standing _bookbuddy_last_search leak.)
    if o.ui then
        o.ui._bookbuddy_last_search = nil
        o.ui._bookbuddy_locators = nil
        o.ui._bookbuddy_loc_seq = nil
    end
    -- When memory is enabled, build the per-book store once and offer the memory
    -- tool alongside the others. It rides in tool_specs, so the last_round rule
    -- that drops tools to force a text answer drops memory too. Skip it if the
    -- book has no resolvable sidecar dir to store memory in.
    o.memory = nil
    if o.ui and o.settings and o.settings:getConfig().enable_memory then
        local base = Memory.baseDirForBook(o.ui)
        if base then
            o.memory = Memory.new(base)
            o.tool_specs[#o.tool_specs + 1] = Memory.spec()
        end
    end
    o.viewer = nil
    o.streaming_viewer = false
    o._cancel = nil
    -- Set true by the viewer's Stop button. A Stop pressed while a stream is live
    -- cancels it immediately via _cancel; a Stop pressed during a synchronous tool
    -- call (no live stream, _cancel is nil) can only be recorded here and is
    -- honored at the next loop boundary (see _loop).
    o.stop_requested = false
    o._flush_task = nil
    -- Accumulated across every API call in the conversation (each turn resends the
    -- full history, so summing input_tokens reflects what was actually billed).
    o.usage = { input = 0, output = 0, cache_read = 0, cache_write = 0 }
    return o
end

function Conversation:ask(question)
    if #self.messages == 0 then
        local context = Tools.execute("book_context", {}, self.ui)
        local seed
        if not (self.selected_text and self.selected_text ~= "") then
            -- Book-level chat: no highlighted passage, just the book context and
            -- the reader's question (started from the menu, not a selection).
            seed = T("<book_context>\n%1\n</book_context>\n\n<question>\n%2\n</question>", context, question)
        elseif self.note and self.note ~= "" then
            seed = T(
                "<book_context>\n%1\n</book_context>\n\n"
                    .. "<highlighted_passage>\n%2\n</highlighted_passage>\n\n"
                    .. "<reader_note>\n%3\n</reader_note>\n\n"
                    .. "<question>\n%4\n</question>",
                context,
                self.selected_text,
                self.note,
                question
            )
        else
            seed = T(
                "<book_context>\n%1\n</book_context>\n\n"
                    .. "<highlighted_passage>\n%2\n</highlighted_passage>\n\n"
                    .. "<question>\n%3\n</question>",
                context,
                self.selected_text,
                question
            )
        end
        self.messages[#self.messages + 1] = { role = "user", content = seed }
    else
        self.messages[#self.messages + 1] = { role = "user", content = question }
    end
    self.transcript[#self.transcript + 1] = { role = "user", text = question }
    self:run()
end

function Conversation:run()
    if NetworkMgr:willRerunWhenOnline(function()
        self:run()
    end) then
        return
    end
    Trapper:wrap(function()
        self:_loop()
    end)
end

function Conversation:_loop()
    local cfg = self.settings:getConfig()
    local max_turns = cfg.max_turns

    -- Fresh per user turn (_loop runs once per ask(); resumes stay in the loop
    -- below). Clears any Stop left set by a prior turn so a reused Conversation
    -- can't abort a follow-up at its first boundary before the reader acts.
    self.stop_requested = false

    -- A pause_turn is not a turn of its own: it's the API stopping mid-turn to let
    -- a long server-side job (e.g. a web search) keep running, which we continue by
    -- resending the partial assistant turn unchanged. Counting each resume against
    -- max_turns let a repeatedly-pausing search burn the whole budget on pauses and
    -- never reach an answer, so we count substantive turns and resumes separately:
    -- a resume doesn't spend a turn, but its own cap still stops a server that
    -- pauses without end.
    local max_resumes = 16
    local iterations = 0
    local resumes = 0
    -- Set after a pause_turn: the next round resends the partial assistant turn
    -- unchanged to let the server finish (e.g. a long web search).
    local resuming = false
    while true do
        -- This round continues a turn the previous round left paused: its reply must
        -- extend that same assistant message, not start a new one (see below), and
        -- it keeps the tools the paused turn references so the API can finish.
        local is_resume = resuming
        resuming = false
        if is_resume then
            resumes = resumes + 1
            if resumes > max_resumes then
                logger.warn("BookBuddy: pause_turn resume limit reached; rendering partial reply")
                self:_render()
                return
            end
        else
            iterations = iterations + 1
            resumes = 0
            if iterations > max_turns then
                break
            end
        end
        -- The synchronous tool loop blocks the event loop (Tools.execute below never
        -- yields), so a Stop tapped during a tool call is buffered, not dispatched.
        -- Yield once here -- mirroring Stream.run's idiom -- so UIManager runs
        -- handleInput and delivers the buffered tap into on_stop, then abort if it
        -- set the flag. Doing this before buildBody/the next fork means a Stop during
        -- the previous round's tools costs no extra request, and history is already
        -- balanced (the prior round appended both the assistant tool_use and the user
        -- tool_result), so a later ask() can resend it.
        local co = coroutine.running()
        UIManager:nextTick(function()
            coroutine.resume(co)
        end)
        coroutine.yield()
        if self.stop_requested then
            self:_closeViewer()
            UIManager:show(InfoMessage:new({ text = _("BookBuddy request cancelled.") }))
            return
        end

        -- On the final allowed substantive round, drop the tools so the model has to
        -- answer in text rather than requesting another tool call we'd refuse to
        -- run. (web_search rides in tool_specs too, so dropping tools also rules out
        -- a pause on this round -- the round always yields a text answer.) A resume
        -- always keeps the tools: its paused turn references a server tool.
        local last_round = (not is_resume) and iterations >= max_turns
        local tools = (not last_round) and self.tool_specs or nil

        local body = Anthropic.buildBody(self.messages, tools, cfg)
        logger.dbg("BookBuddy: request", cfg.model, "messages:", #self.messages, "tools:", tools and #tools or 0)
        self:_ensureStreamingViewer()

        -- Each entry is created on its first delta so a turn that produces no
        -- thinking (or no text) leaves no empty line in the transcript. These live
        -- entries are replaced by content-ordered ones once the turn finishes (see
        -- _renderAssistantTurn); mark where this turn's entries begin.
        local turn_transcript_start = #self.transcript
        local entry, thinking_entry
        local parser = Anthropic.newStreamParser({
            on_thinking = function()
                -- We don't surface the summarized thinking text anymore, just a
                -- "Thinking..." status that flips to "Done" once the answer
                -- starts (or the turn finishes; see _renderAssistantTurn). The
                -- parser still accumulates the fragments onto the content block
                -- for resend -- this transcript entry is display-only.
                if not thinking_entry then
                    thinking_entry = { role = "thinking", done = false }
                    self.transcript[#self.transcript + 1] = thinking_entry
                    self:_scheduleFlush()
                end
            end,
            on_text = function(t)
                if thinking_entry then
                    thinking_entry.done = true
                end
                if not entry then
                    entry = { role = "assistant", text = "" }
                    self.transcript[#self.transcript + 1] = entry
                end
                entry.text = entry.text .. t
                self:_scheduleFlush()
            end,
        })

        local r = Stream.run({
            child_fn = Anthropic.streamChildFn(body, cfg),
            on_line = function(line)
                parser:feed(line)
            end,
            register_cancel = function(fn)
                self._cancel = fn
            end,
        })
        self:_cancelFlush()

        if r.cancelled then
            self:_dropDanglingTail()
            self:_closeViewer()
            UIManager:show(InfoMessage:new({ text = _("BookBuddy request cancelled.") }))
            return
        end
        if r.read_error then
            logger.warn("BookBuddy: streaming connection failed")
            self:_dropDanglingTail()
            self:_closeViewer()
            UIManager:show(InfoMessage:new({ text = _("BookBuddy: the streaming connection failed.") }))
            return
        end

        local res = parser:result()
        if not res.ok then
            logger.warn("BookBuddy: API error", res.code, res.error_message, res.error_body)
            self:_dropDanglingTail()
            self:_closeViewer()
            self:_showError(res)
            return
        end

        local u = res.usage
        if u then
            self.usage.input = self.usage.input + (u.input_tokens or 0)
            self.usage.output = self.usage.output + (u.output_tokens or 0)
            self.usage.cache_read = self.usage.cache_read + (u.cache_read_input_tokens or 0)
            self.usage.cache_write = self.usage.cache_write + (u.cache_creation_input_tokens or 0)
        end

        -- Record the terminal turn's stop_reason so a headless driver (and the warn
        -- below) can surface why a turn ended. Notably it tells an empty completion
        -- caused by the gateway (no message_delta, so stop_reason stays nil) apart
        -- from one the model chose to end empty (stop_reason "end_turn"). Purely
        -- diagnostic -- no behavior change.
        self.last_stop_reason = res.stop_reason

        -- A reply with no content blocks serializes as an empty JSON object, which
        -- the API rejects ("content should be a valid list") when the history is
        -- resent on a follow-up. We can't just skip the turn either: that would put
        -- two user messages in a row and break role alternation. Store a valid
        -- placeholder block so history stays resendable, and surface the gap.
        if type(res.content) ~= "table" or #res.content == 0 then
            logger.warn("BookBuddy: assistant reply had no content blocks; storing placeholder",
                "stop_reason:", tostring(res.stop_reason))
            self:_storeAssistant({ { type = "text", text = "(no response)" } }, is_resume)
            self.transcript[#self.transcript + 1] = { role = "assistant", text = _("(no response)") }
            self:_render()
            return
        end

        logger.dbg("BookBuddy: reply", res.stop_reason, "blocks:", #res.content)
        self:_storeAssistant(res.content, is_resume)
        local tool_uses = select(2, self:_split(res.content))
        -- Replace this turn's live streamed entries with content-ordered ones, so a
        -- server-side web search shows between the lead-in and the answer rather than
        -- hoisted above them. Client tool calls are added below, after execution.
        self:_renderAssistantTurn(res.content, turn_transcript_start)

        if res.stop_reason == "pause_turn" then
            -- The API paused a long server-side turn. Resume by resending the partial
            -- assistant turn (no user message). The pause can stop on the in-flight
            -- web search's server_tool_use before its result, which our Vertex gateway
            -- rejects on resend; pair any such orphan with a synthetic error result
            -- first so the request validates and the model can finish its turn.
            pairDanglingWebSearch(self.messages[#self.messages].content)
            resuming = true
            self:_flushNow()
        elseif res.stop_reason == "tool_use" and #tool_uses > 0 then
            -- Tools run synchronously and are not interruptible mid-call: a Stop
            -- pressed during a slow tool (a large read, a wide grep) is
            -- buffered and honored at the next loop boundary above, after the tool
            -- returns -- not instantly.
            self:_flushNow()
            local tool_results = {}
            for i = 1, #tool_uses do
                local tu = tool_uses[i]
                -- Show the in-progress action immediately, then fold the outcome
                -- summary into the same line once the executor returns.
                local tool_entry = { role = "tool", text = self:_toolActionPhrase(tu) }
                self.transcript[#self.transcript + 1] = tool_entry
                self:_flushNow()
                local result, summary
                if tu.name == "memory" and self.memory then
                    result = self.memory:execute(tu.input)
                else
                    result, summary = Tools.execute(tu.name, tu.input, self.ui)
                end
                if summary and summary ~= "" then
                    tool_entry.text = tool_entry.text .. " — " .. summary
                end
                tool_results[#tool_results + 1] = {
                    type = "tool_result",
                    tool_use_id = tu.id,
                    content = result,
                }
            end
            self.messages[#self.messages + 1] = { role = "user", content = tool_results }
        else
            self:_render()
            return
        end
    end

    -- Reached only when the substantive-turn budget runs out (the loop broke).
    -- The final round omitted tools, so it produced a text answer that's already
    -- in the transcript; render it.
    self:_render()
end

-- Record an assistant reply in the wire history. A pause_turn continuation
-- (is_resume) extends the existing assistant turn instead of adding a second
-- assistant message in a row: a paused-then-resumed turn is one logical turn, and
-- two consecutive assistant messages make the gateway 400 ("roles must alternate")
-- once a later user turn resends the pair. Merging also keeps each server_tool_use
-- in the same message as its web_search_tool_result.
function Conversation:_storeAssistant(blocks, is_resume)
    local prev = self.messages[#self.messages]
    if is_resume and prev and prev.role == "assistant" and type(prev.content) == "table" then
        for i = 1, #blocks do
            prev.content[#prev.content + 1] = blocks[i]
        end
    else
        self.messages[#self.messages + 1] = { role = "assistant", content = blocks }
    end
end

-- After an error/cancel exit, _loop has appended a user (seed or tool_result)
-- turn but never stored the assistant reply for it, so history ends on a
-- dangling, unanswered user turn. ask() would then append a *second* user
-- message and the gateway 400s ("roles must alternate"); dropping only the
-- trailing user would instead expose an unanswered client tool_use (also a
-- 400). Walk back over the whole in-flight tool round to the last clean
-- assistant turn (or empty history, which lets ask() re-seed) so the stored
-- history is always resendable before the next ask(). This makes explicit the
-- "history ends with an assistant reply" invariant that was, until now, only
-- upheld by the error path closing the viewer.
function Conversation:_dropDanglingTail()
    local m = self.messages
    while #m > 0 do
        local last = m[#m]
        local dangling = (last.role == "user")
        if last.role == "assistant" and type(last.content) == "table" then
            for _, b in ipairs(last.content) do
                if b.type == "tool_use" then
                    dangling = true
                    break
                end
            end
        end
        if not dangling then
            break
        end
        m[#m] = nil
    end
end

function Conversation:_split(content)
    local text_parts, tool_uses = {}, {}
    if type(content) ~= "table" then
        return text_parts, tool_uses
    end
    for _, block in ipairs(content) do
        if block.type == "text" and block.text then
            text_parts[#text_parts + 1] = block.text
        elseif block.type == "tool_use" then
            tool_uses[#tool_uses + 1] = block
        end
    end
    return text_parts, tool_uses
end

-- A friendly, present-completed description of one tool call, e.g.
--   "  → Searched book for "whales"". The leading arrow/indent set tool lines
-- apart from the You:/BookBuddy: turns in the plain-text transcript. The outcome
-- summary (match count, word count, …) is appended by the caller once known.
function Conversation:_toolActionPhrase(tu)
    local input = tu.input or {}
    local phrase
    if tu.name == "grep" then
        phrase = T(_("Searched book for %1"), string.format("%q", input.query or ""))
    elseif tu.name == "read" then
        phrase = T(_("Reading from %1"), (input.from and tostring(input.from)) or _("your current page"))
    elseif tu.name == "get_toc" then
        phrase = _("Fetched the table of contents")
    elseif tu.name == "book_context" then
        phrase = _("Checked the book details")
    elseif tu.name == "get_highlights" then
        phrase = _("Looked up your highlights")
    elseif tu.name == "edit_highlight_note" then
        phrase = T(_("Updated the note on highlight %1"), tostring(input.highlight_index))
    elseif tu.name == "create_highlight" then
        phrase = _("Created a highlight")
    elseif tu.name == "navigate" then
        phrase = self:_navigatePhrase(input)
    elseif tu.name == "memory" then
        phrase = self:_memoryPhrase(input)
    else
        phrase = T(_("Used %1"), tu.name)
    end
    return "  → " .. phrase
end

function Conversation:_navigatePhrase(input)
    if input.back then
        return _("Went back")
    elseif input.page ~= nil then
        return T(_("Went to page %1"), tostring(input.page))
    elseif input.percent ~= nil then
        return T(_("Went to %1%"), tostring(input.percent))
    elseif input.chapter_index ~= nil then
        return T(_("Went to chapter %1"), tostring(input.chapter_index))
    end
    return _("Navigated the book")
end

-- "/memories/notes.md" -> "notes.md"; the /memories root -> nil (no useful name).
local function memoryNoteName(path)
    if type(path) ~= "string" then
        return nil
    end
    local name = path:gsub("^/memories/?", "")
    return name ~= "" and name or nil
end

function Conversation:_memoryPhrase(input)
    local cmd = input.command
    local name = memoryNoteName(input.path)
    if cmd == "view" then
        if name then
            return T(_("Read memory note %1"), name)
        end
        return _("Reviewed saved memory")
    elseif cmd == "create" then
        return name and T(_("Saved memory note %1"), name) or _("Saved a memory note")
    elseif cmd == "str_replace" or cmd == "insert" then
        return name and T(_("Updated memory note %1"), name) or _("Updated a memory note")
    elseif cmd == "delete" then
        return name and T(_("Deleted memory note %1"), name) or _("Deleted a memory note")
    elseif cmd == "rename" then
        local from, to = memoryNoteName(input.old_path), memoryNoteName(input.new_path)
        if from and to then
            return T(_("Renamed memory note %1 to %2"), from, to)
        end
        return _("Renamed a memory note")
    end
    return _("Used memory")
end

-- Re-render this turn's assistant content into the transcript in block order,
-- replacing the live streamed entries (everything past turn_start). This keeps a
-- server-side web search between the model's lead-in and its answer instead of
-- hoisting it above them, and renders interleaved thinking/text in reading order.
-- Web search runs server-side, so its query never reaches the client tool loop;
-- we surface it here, with the result count from the matching result block when it
-- is in this turn (after a pause_turn the result can be absent, so we show the
-- query alone).
function Conversation:_renderAssistantTurn(content, turn_start)
    for i = #self.transcript, turn_start + 1, -1 do
        self.transcript[i] = nil
    end
    if type(content) ~= "table" then
        return
    end
    local outcome = {}
    for i = 1, #content do
        local b = content[i]
        if b.type == "web_search_tool_result" and b.tool_use_id then
            local c = b.content
            if type(c) == "table" and c.type == "web_search_tool_result_error" then
                outcome[b.tool_use_id] = { error = c.error_code }
            elseif type(c) == "table" then
                outcome[b.tool_use_id] = { count = #c }
            end
        end
    end
    for i = 1, #content do
        local b = content[i]
        if b.type == "thinking" and b.thinking and b.thinking ~= "" then
            self.transcript[#self.transcript + 1] = { role = "thinking", done = true }
        elseif b.type == "text" and b.text and b.text ~= "" then
            self.transcript[#self.transcript + 1] = { role = "assistant", text = b.text }
        elseif b.type == "server_tool_use" and b.name == "web_search" then
            local query = (b.input and b.input.query) or ""
            local text = "  → " .. T(_("Searched the web for %1"), string.format("%q", query))
            local r = outcome[b.id]
            if r and r.error then
                text = text .. " — " .. T(_("error: %1"), tostring(r.error))
            elseif r and r.count then
                text = text .. " — " .. T(_("%1 result(s)"), r.count)
            end
            self.transcript[#self.transcript + 1] = { role = "tool", text = text }
        end
    end
end

function Conversation:_transcriptText()
    local out = {}
    for i = 1, #self.transcript do
        local turn = self.transcript[i]
        if turn.role == "user" then
            out[#out + 1] = T(_("You: %1"), turn.text)
        elseif turn.role == "assistant" then
            out[#out + 1] = T(_("BookBuddy: %1"), strippedEntry(turn))
        elseif turn.role == "thinking" then
            out[#out + 1] = turn.done and _("Thinking... Done") or _("Thinking...")
        else
            out[#out + 1] = turn.text
        end
    end
    local usage = self:_usageText()
    if usage then
        out[#out + 1] = usage
    end
    return table.concat(out, "\n\n")
end

-- Footer summarizing token spend across the whole conversation. nil until at
-- least one API call has reported usage. cache_read/cache_write are the prompt
-- tokens served from / written to the prompt cache (Anthropic reports them
-- separately from input_tokens).
function Conversation:_usageText()
    local u = self.usage
    if u.input + u.output == 0 then
        return nil
    end
    local parts = { T(_("input %1"), u.input), T(_("output %1"), u.output) }
    local cached = u.cache_read + u.cache_write
    if cached > 0 then
        parts[#parts + 1] = T(_("cached %1"), cached)
    end
    return T(_("[tokens — %1]"), table.concat(parts, ", "))
end

-- Show (or re-show) the viewer in streaming mode, i.e. with a Stop button. A
-- follow-up reuses the finished viewer, which is in Reply mode, so we
-- rebuild it here; mid-conversation turns keep the same streaming viewer.
function Conversation:_ensureStreamingViewer()
    if self.viewer and self.streaming_viewer then
        return
    end
    if self.viewer then
        UIManager:close(self.viewer)
        self.viewer = nil
    end
    self.viewer = ChatViewer.build({
        title = _("BookBuddy"),
        text = self:_transcriptText(),
        on_stop = function()
            -- Record the request either way: a live-stream Stop cancels via _cancel
            -- (Stream.run returns cancelled), while a Stop during a synchronous tool
            -- call has no stream to cancel (_cancel is nil) and is picked up at the
            -- next loop boundary.
            self.stop_requested = true
            if self._cancel then
                self._cancel()
            end
        end,
        scroll_to_bottom = true,
    })
    self.streaming_viewer = true
    UIManager:show(self.viewer)
end

function Conversation:_closeViewer()
    self:_cancelFlush()
    if self.viewer then
        UIManager:close(self.viewer)
        self.viewer = nil
    end
    self.streaming_viewer = false
end

-- Throttled live update: at most one repaint per FLUSH_INTERVAL_SEC.
function Conversation:_scheduleFlush()
    if self._flush_task then
        return
    end
    self._flush_task = function()
        self._flush_task = nil
        self:_flushNow()
    end
    UIManager:scheduleIn(FLUSH_INTERVAL_SEC, self._flush_task)
end

function Conversation:_cancelFlush()
    if self._flush_task then
        UIManager:unschedule(self._flush_task)
        self._flush_task = nil
    end
end

function Conversation:_flushNow()
    if self.viewer then
        ChatViewer.updateText(self.viewer, self:_transcriptText(), true)
    end
end

function Conversation:_render()
    self:_cancelFlush()
    if self.viewer then
        UIManager:close(self.viewer)
        self.viewer = nil
    end
    self.viewer = ChatViewer.build({
        title = _("BookBuddy"),
        text = self:_transcriptText(),
        on_followup = function()
            self:_promptFollowup()
        end,
        scroll_to_bottom = true,
    })
    self.streaming_viewer = false
    UIManager:show(self.viewer)
end

function Conversation:_promptFollowup()
    local dialog
    local buttons = Presets.buttonRows(Presets.followup, function()
        return dialog
    end)
    buttons[#buttons + 1] = {
        {
            text = _("Cancel"),
            id = "close",
            callback = function()
                UIManager:close(dialog)
            end,
        },
        {
            text = _("Send"),
            is_enter_default = true,
            callback = function()
                local q = dialog:getInputText()
                UIManager:close(dialog)
                if q and q ~= "" then
                    self:ask(q)
                end
            end,
        },
    }
    dialog = InputDialog:new({
        title = _("Reply"),
        input = "",
        input_hint = _("Type your reply"),
        buttons = buttons,
    })
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Conversation:_showError(res)
    local msg
    if res.network_error then
        msg = T(_("BookBuddy: network error contacting the gateway (%1)."), tostring(res.code))
    elseif res.code then
        msg = T(_("BookBuddy: the gateway returned an error (HTTP %1)."), tostring(res.code))
        if res.error_message then
            msg = msg .. "\n" .. tostring(res.error_message)
        end
    else
        msg = T(_("BookBuddy API error: %1"), tostring(res.error_message or _("unknown error")))
    end
    UIManager:show(InfoMessage:new({ text = msg }))
end

return Conversation
