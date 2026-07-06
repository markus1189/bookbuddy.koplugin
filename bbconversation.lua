-- Drives the multi-turn, tool-using exchange with Claude.
--
-- The whole loop runs inside Trapper:wrap, which gives us a coroutine the
-- streaming transport can yield from (LuaJIT's main thread can't). Each Claude
-- call is streamed from a forked subprocess (network only) while the reply is
-- rendered live into the viewer; tool calls run here in the main process because
-- they touch the live document. We keep two parallel structures: `messages` (the
-- exact Anthropic wire format, resent every turn) and `transcript` (a
-- human-readable log rendered in the viewer).
--
-- Collaborators: bbretry owns the per-call retry/backoff/classify policy,
-- bbhistory the resendability invariants over `messages`, and bbtranscript the
-- plain-text rendering of `transcript`. What remains here is the orchestration:
-- the turn loop, tool dispatch, the reader-facing dialogs, and the viewer.
local ButtonDialog = require("ui/widget/buttondialog")
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
local Chats = require("bbchats")
local History = require("bbhistory")
local Memory = require("bbmemory")
local Presets = require("bbpresets")
local Retry = require("bbretry")
local StatusBar = require("bbstatusbar")
local Tools = require("bbtools")
local Transcript = require("bbtranscript")

-- Repaint the live transcript at most this often while text streams in. The
-- transport wakes every 0.125s; coalescing to ~2.5 fps keeps e-ink usable.
local FLUSH_INTERVAL_SEC = 0.4

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
    -- Subagent delegation is opt-in (default off, like show_streaming_thinking), the
    -- inverse polarity of web_search above: drop the delegate tool UNLESS the setting
    -- is explicitly on, so the model is never offered a tool the feature gate disables.
    if not (o.settings and o.settings:getConfig().enable_subagents == true) then
        for i = #o.tool_specs, 1, -1 do
            local t = o.tool_specs[i]
            if type(t) == "table" and t.name == "delegate" then
                table.remove(o.tool_specs, i)
            end
        end
    end
    -- The clarifying-question tool (ask_user) is on by default -- it costs no extra
    -- tokens and opens no new spoiler surface, so unlike subagents it ships enabled --
    -- but stays toggleable. Same polarity as web_search above: only an explicit false
    -- removes it, so an absent flag keeps the default-on behaviour.
    if o.settings and o.settings:getConfig().enable_clarifying_questions == false then
        for i = #o.tool_specs, 1, -1 do
            local t = o.tool_specs[i]
            if type(t) == "table" and t.name == "ask_user" then
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
    -- Tokens the conversation currently occupies, as opposed to the cumulative
    -- billed total above. Overwritten (not summed) on every call: the latest call's
    -- full prompt (input + cache_read + cache_write covers the whole resent history,
    -- whether a token was billed fresh or served from cache) plus its output, which
    -- is now appended to history and will ride along in the next request.
    o.context_size = 0
    -- Reopen a stored chat (see bbchats): restore the persisted wire history and
    -- display transcript instead of starting empty, so a follow-up runs the SAME
    -- ask() -> _loop path as an in-session reply — messages is non-empty, so ask()
    -- appends the plain question and resends the full history. The wire format IS
    -- the resume format; there is no separate resume protocol. chat_id makes the
    -- next save overwrite this chat's payload rather than mint a new one.
    -- _last_saved_len records where the stored history already ends, so merely
    -- reopening (which _renders) doesn't rewrite an unchanged payload.
    if o.resume_state then
        local s = o.resume_state
        o.resume_state = nil
        o.messages = type(s.messages) == "table" and s.messages or {}
        o.transcript = type(s.transcript) == "table" and s.transcript or {}
        if type(s.usage) == "table" then
            -- tonumber() both coerces decoded numbers and rejects rapidjson.null.
            o.usage.input = tonumber(s.usage.input) or 0
            o.usage.output = tonumber(s.usage.output) or 0
            o.usage.cache_read = tonumber(s.usage.cache_read) or 0
            o.usage.cache_write = tonumber(s.usage.cache_write) or 0
        end
        o.chat_id = s.id
        o.chat_ts_created = tonumber(s.ts_created)
        -- Cosmetic post-resume: these only shaped turn 1's seed, which already
        -- happened. Restored for completeness (a decoded null must not stand in
        -- for a string, hence the type guards).
        if type(s.selected_text) == "string" then
            o.selected_text = s.selected_text
        end
        if type(s.note) == "string" then
            o.note = s.note
        end
        o._last_saved_len = #o.messages
    end
    return o
end

-- Show a reopened chat's finished transcript in Reply mode. Just the terminal
-- render: the follow-up path is the ordinary one from there.
function Conversation:reopen()
    self:_render()
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
        -- Every round (fresh, tool continuation, resume) starts back at
        -- "connecting" until the stream's first delta lands.
        self:_setStatus("connecting")

        -- Each entry is created on its first delta so a turn that produces no
        -- thinking (or no text) leaves no empty line in the transcript. These live
        -- entries are replaced by content-ordered ones once the turn finishes (see
        -- _renderAssistantTurn); mark where this turn's entries begin.
        local turn_transcript_start = #self.transcript
        -- L1 transcript checkpoint: a mid-round failure (or a retry between attempts)
        -- trims self.transcript back to the last clean/resendable state, dropping the
        -- abandoned live-stream partials so a recovered conversation shows no orphaned
        -- text. It must mirror _dropDanglingTail's wire-history rollback EXACTLY: that
        -- rollback walks back over the WHOLE in-flight tool round (every dangling
        -- user/assistant turn), which can span several rounds -- e.g. a committed
        -- [assistant tool_use][user tool_result] pair from a PRIOR round is also
        -- unwound, because an unanswered tool round is not resendable. So the
        -- checkpoint must advance only at the START of a fresh chain -- a round whose
        -- pending user turn is the reader's question (string content), not a
        -- tool_result we appended (table content) and not a pause resume. On a
        -- tool-continuation or resume round the checkpoint stays pinned at the chain's
        -- start, exactly where _dropDanglingTail will roll the wire history back to. A
        -- per-round reset (the old behaviour) left a prior round's committed-but-now-
        -- dropped entries stranded in the human log after a multi-round rollback.
        local pending = self.messages[#self.messages]
        local chain_start = (not is_resume) and pending and pending.role == "user" and type(pending.content) ~= "table"
        if chain_start or self._clean_transcript_len == nil then
            self._clean_transcript_len = turn_transcript_start
        end

        -- Bounded retry around the fork+parse, via the shared Retry.streamWithRetries
        -- policy (also driving the subagent loop). The make_parser hook rebuilds the
        -- live transcript entries FRESH per attempt (a retried attempt must not append
        -- onto an aborted attempt's partials); on_retry trims those partials back to
        -- the checkpoint and shows the "Retrying" status -- _dropDanglingTail, which
        -- would unwind the whole in-flight round, is reserved for the give-up exits
        -- below. This is safe precisely because nothing is stored until
        -- _storeAssistant past the helper, so the wire history is already the
        -- resendable state we re-fork FROM (a committed [assistant tool_use][user
        -- tool_result] pair must be RESENT, not dropped).
        local r, res, verdict = Retry.streamWithRetries({
            body = body,
            cfg = cfg,
            make_parser = function()
                local entry, thinking_entry
                return Anthropic.newStreamParser({
                    on_thinking = function(delta)
                        -- By default we don't surface the summarized thinking text, just a
                        -- "Thinking..." status that flips to "Done" once the answer
                        -- starts (or the turn finishes; see _renderAssistantTurn). The
                        -- parser still accumulates the fragments onto the content block
                        -- for resend -- this transcript entry is display-only. When the
                        -- reader opts into show_streaming_thinking (off by default, it can
                        -- spoil unread plot), we stream the text into the entry, and the
                        -- render replaces the indicator with the live reasoning entirely.
                        local first = not thinking_entry
                        if first then
                            thinking_entry = { role = "thinking", done = false }
                            self.transcript[#self.transcript + 1] = thinking_entry
                        end
                        self:_setStatus("thinking")
                        if cfg.show_streaming_thinking and delta and delta ~= "" then
                            thinking_entry.text = (thinking_entry.text or "") .. delta
                        end
                        -- Paint the first fragment immediately so streamed reasoning shows up
                        -- the instant it starts rather than a throttle window later; the rest
                        -- coalesce at one repaint per window to spare the e-ink panel.
                        if first then
                            self:_flushNow()
                        else
                            self:_scheduleFlush()
                        end
                    end,
                    on_text = function(t)
                        if thinking_entry then
                            thinking_entry.done = true
                        end
                        self:_setStatus("writing")
                        if not entry then
                            entry = { role = "assistant", text = "" }
                            self.transcript[#self.transcript + 1] = entry
                        end
                        entry.text = entry.text .. t
                        self:_scheduleFlush()
                    end,
                })
            end,
            register_cancel = function(fn)
                self._cancel = fn
            end,
            on_attempt_done = function()
                self:_cancelFlush()
            end,
            on_retry = function(next_attempt)
                self:_trimTranscript()
                self:_showRetryStatus(next_attempt)
                self:_setStatus("retrying", tostring(next_attempt) .. "/" .. tostring(Retry.MAX_STREAM_ATTEMPTS))
            end,
            stopped = function()
                return self.stop_requested
            end,
        })

        -- A Stop tapped during a backoff aborted the retry loop. Same cleanup as the
        -- live-stream cancel below: roll the dangling tail back, close, and report.
        if verdict == "stopped" then
            self:_dropDanglingTail()
            self:_closeViewer()
            UIManager:show(InfoMessage:new({ text = _("BookBuddy request cancelled.") }))
            return
        end

        -- Cancel is terminal and instant: a user Stop during the live stream.
        if r.cancelled then
            self:_dropDanglingTail()
            self:_closeViewer()
            UIManager:show(InfoMessage:new({ text = _("BookBuddy request cancelled.") }))
            return
        end

        if verdict == "retry" then
            -- Retries exhausted. An empty-200 still falls through to the placeholder
            -- branch below (res.ok stays true); a read_error / incomplete / retryable
            -- error reaches here non-ok -> surface the failure and roll back.
            if not (res.ok and (type(res.content) ~= "table" or #res.content == 0)) then
                logger.warn("BookBuddy: stream failed after retries", res.code, res.error_message, res.error_body)
                self:_dropDanglingTail()
                self:_closeViewer()
                if r.read_error or res.incomplete then
                    UIManager:show(InfoMessage:new({ text = _("BookBuddy: the streaming connection failed.") }))
                else
                    self:_showError(res)
                end
                return
            end
        elseif verdict == "terminal" then
            -- A non-retryable failure (4xx the gateway rejects every time, an
            -- auth/not-found error, or a non-retryable mid-stream error type).
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
            self.context_size = (u.input_tokens or 0)
                + (u.cache_read_input_tokens or 0)
                + (u.cache_creation_input_tokens or 0)
                + (u.output_tokens or 0)
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
        -- placeholder block so history stays resendable, and surface the gap. We
        -- only reach here for an empty-200 AFTER retries are exhausted (R2): the
        -- classifier treats empty-200 as retryable, so a transient empty reply gets
        -- re-forked first; the placeholder is the last resort.
        if type(res.content) ~= "table" or #res.content == 0 then
            logger.warn(
                "BookBuddy: assistant reply had no content blocks; storing placeholder",
                "stop_reason:",
                tostring(res.stop_reason)
            )
            self:_storeAssistant({ { type = "text", text = "(no response)" } }, is_resume)
            self.transcript[#self.transcript + 1] = { role = "assistant", text = _("(no response)") }
            self:_render()
            return
        end

        logger.dbg("BookBuddy: reply", res.stop_reason, "blocks:", #res.content)
        self:_storeAssistant(res.content, is_resume)
        -- Pair any orphan server_tool_use for EVERY stored turn, not just a
        -- pause_turn. A turn can carry an unpaired web search under any stop_reason
        -- (end_turn, tool_use, or gateway weirdness); left unpaired it persists and
        -- the next ask() resends it, which the Vertex validator 400s forever ("web
        -- search tool use ... without a corresponding web_search_tool_result").
        -- pairDanglingWebSearch's has_result guard makes this an idempotent no-op
        -- when the result block is already present (the common case), so running it
        -- unconditionally is safe. Operate on the freshly merged message content.
        History.pairDanglingWebSearch(self.messages[#self.messages].content)
        local tool_uses = select(2, History.split(res.content))
        -- Replace this turn's live streamed entries with content-ordered ones, so a
        -- server-side web search shows between the lead-in and the answer rather than
        -- hoisted above them. Client tool calls are added below, after execution.
        self:_renderAssistantTurn(res.content, turn_transcript_start, cfg.show_streaming_thinking)

        if res.stop_reason == "pause_turn" then
            -- The API paused a long server-side turn. Resume by resending the partial
            -- assistant turn (no user message). Any orphan server_tool_use the pause
            -- stopped on was already paired above (unconditionally, right after
            -- _storeAssistant), so the resend validates and the model can finish.
            -- Advance the transcript checkpoint past this committed pause turn. Unlike a
            -- tool-continuation round (whose [assistant tool_use][user tool_result] is
            -- dangling, so _dropDanglingTail unwinds it back to the chain start),
            -- _dropDanglingTail STOPS here: the pause turn's server_tool_use is paired,
            -- so it is non-dangling and stays in the wire. _trimTranscript must mirror
            -- that and stop here too -- otherwise a later failing resume would trim this
            -- turn's rendered lead-in/search lines out of the human log while the wire
            -- keeps (and resends) them, desyncing the transcript from history.
            self._clean_transcript_len = #self.transcript
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
                -- Paint the status BEFORE the executor: tools run synchronously and
                -- block the event loop, so the ticker can't fire mid-call -- this
                -- line is the bar's last update until the tool returns, and it must
                -- say what the turn is stuck on.
                self:_setStatus("tool", tu.name)
                self:_flushNow()
                local result, summary
                if tu.name == "memory" and self.memory then
                    result = self.memory:execute(tu.input)
                elseif tu.name == "delegate" then
                    result, summary = self:_runDelegate(tu, cfg, tool_entry)
                elseif tu.name == "ask_user" then
                    -- REENTRANCY INVARIANT: this dispatch site is reached only AFTER the
                    -- parent stream fully returned, so the loop's coroutine is parked at an
                    -- ordinary call site, never mid-yield -- which is exactly what makes it
                    -- legal for _askUser to yield AGAIN to await the reader's dialog (same
                    -- reasoning the delegate nested-stream comment relies on). _askUser MUST
                    -- resume the coroutine on every dialog close path (answer/skip/dismiss)
                    -- or the turn parks forever; it always returns a non-empty string, so
                    -- the tool_use below is always answered and the wire history stays
                    -- balanced (an unanswered ask_user tool_use would 400 on the next resend).
                    result, summary = self:_askUser(tu.input)
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

-- Record an assistant reply in the wire history (History.storeAssistant holds the
-- pause_turn merge rule and its role-alternation rationale).
function Conversation:_storeAssistant(blocks, is_resume)
    History.storeAssistant(self.messages, blocks, is_resume)
end

-- After an error/cancel exit, roll the wire history back to the last resendable
-- state (History.dropDanglingTail holds the walk-back rule and its rationale), then
-- unwind the human-readable transcript to match.
function Conversation:_dropDanglingTail()
    History.dropDanglingTail(self.messages)
    self:_trimTranscript()
end

-- L1: unwind the human-readable transcript to match a rolled-back wire history.
-- _clean_transcript_len is the length recorded before the current round's body (in
-- _loop), i.e. the last clean/resendable state; everything past it is this round's
-- abandoned live-stream phase -- partial assistant / thinking entries and the
-- in-progress tool-action line -- whose backing messages were (or are about to be)
-- dropped. Without this the next ask() re-renders those orphaned lines before the
-- real answer. Mirror _renderAssistantTurn's trim idiom (nil out from the tail).
-- nil checkpoint = nothing to trim (e.g. a tail dropped before any round ran).
function Conversation:_trimTranscript()
    local cp = self._clean_transcript_len
    if cp == nil then
        return
    end
    for i = #self.transcript, cp + 1, -1 do
        self.transcript[i] = nil
    end
end

-- A friendly, present-completed description of one tool call (see
-- Transcript.toolActionPhrase, which owns the per-tool phrasing). Kept as a
-- method because the loop appends the outcome summary to the entry it creates.
function Conversation:_toolActionPhrase(tu)
    return Transcript.toolActionPhrase(tu)
end

-- Run a `delegate` tool call: hand the sub-task to a read-only child agent and
-- return (tool_result_string, summary). Returns a recoverable error string (never
-- raises) so a child failure or Stop becomes an ordinary tool_result the parent's
-- next round can react to, rather than crashing the conversation.
--
-- Reentrancy invariant (LOAD-BEARING): this runs only at the tool-dispatch site,
-- which is reached only AFTER the parent's own stream has fully returned -- the
-- coroutine is parked at an ordinary call site, never mid-yield -- so a NESTED
-- Stream.run inside runSubagent is legal. The child reuses THIS coroutine and MUST
-- NOT spin its own Trapper:wrap (two Trapper coroutines both scheduling UIManager
-- ticks deadlock). If a future change moves delegation onto a path that can yield
-- before reaching here, that nested stream would deadlock the child.
function Conversation:_runDelegate(tu, cfg, tool_entry)
    local Subagents = require("bbsubagents") -- lazy: the delegate tool is feature-gated (default off)
    local input = tu.input or {}
    -- The child runs a bounded multi-round tool loop that can take many seconds; without
    -- a live signal the committed "Researching: …" line sits frozen and reads as a hang.
    -- on_status fires at the start of each child round, so we append a "(step N/max)"
    -- counter to that exact transcript entry and repaint (mirrors _showRetryStatus's
    -- "(n/3)" idiom). We keep the original phrase as `base` and restore it before
    -- returning, so the caller's " — done"/" — failed" summary append reads cleanly off
    -- the unsuffixed line rather than "(step 6/6) — done".
    local base = tool_entry and tool_entry.text
    -- The child stream installs its cancel closure into the single _cancel slot via
    -- set_cancel; save/restore the parent's slot around the run (it is nil during a
    -- tool call, but be explicit) so a Stop aborts the child and unwinds here. A Stop
    -- also sets self.stop_requested, which the loop's next UI-boundary yield honors.
    local saved_cancel = self._cancel
    local text, err = Subagents.runSubagent({
        ui = self.ui,
        cfg = cfg,
        task = input.task,
        allow_spoiler = input.allow_spoiler == true,
        depth = (self._subagent_depth or 0) + 1,
        stop = function()
            return self.stop_requested
        end,
        set_cancel = function(fn)
            self._cancel = fn
        end,
        on_status = function(round, max)
            if base then
                tool_entry.text = base .. " " .. T(_("(step %1/%2)"), tostring(round), tostring(max))
                self:_flushNow()
            end
        end,
    })
    self._cancel = saved_cancel
    if base then
        tool_entry.text = base -- restore for the caller's clean summary append
    end
    if text and text ~= "" then
        return text, _("done")
    end
    -- A recoverable failure: feed the model a plain note so it can apologize or try
    -- another approach, instead of treating a missing answer as a complete one.
    return T(_("The delegated task did not complete: %1"), tostring(err or _("unknown error"))), _("failed")
end

-- Show the reader a clarifying question (ask_user) and PARK the turn loop until they
-- answer, then return their reply as the tool result plus a short transcript summary.
--
-- Mechanism: the same yield/resume shape as bbretry's backoff -- capture this coroutine, build a
-- dialog whose callbacks resume it, then coroutine.yield(). The dialog callbacks run on
-- the UIManager event loop (a real reader tap) and feed the answer back through the
-- resume.
--
-- NO-HANG INVARIANT (load-bearing): EVERY way the dialog can close -- each option button,
-- the typed-answer Send/Skip, the Skip button, AND a plain dismissal (tap-outside / Back,
-- which closes the widget through onCloseWidget without running any button callback) --
-- routes through resume(). A close path that forgets to resume parks the loop forever with
-- no Stop target. The one-shot `resumed` guard makes a double-close (a button answer that
-- then triggers onCloseWidget) safe: the first resume wins, later ones are no-ops. We
-- resume on the NEXT tick (not inline) so the dialog is fully closed before the loop runs
-- on, and so a real button answer set before onCloseWidget's fallback fires takes priority.
-- _askUser always returns a NON-EMPTY string, so the ask_user tool_use is always answered.
function Conversation:_askUser(input)
    input = input or {}
    -- The turn is parked on the reader's dialog, not on the model or a tool;
    -- say so (the ticker keeps running -- this path yields, unlike client tools).
    self:_setStatus("asking")
    local question = tostring(input.question or _("Could you clarify what you mean?"))
    local options = input.options

    -- A skip/dismiss is recoverable, not an answer: hand the model a plain note (like a
    -- failed delegate) so it proceeds on its own judgement or asks again differently,
    -- rather than treating an empty reply as the reader's choice.
    local SKIP =
        _("[The reader closed the question without answering. Proceed with your best judgement, or ask differently.]")

    local co = coroutine.running()
    local resumed = false
    local answer
    local function resume(reply)
        if resumed then
            return
        end
        resumed = true
        answer = reply
        UIManager:nextTick(function()
            coroutine.resume(co)
        end)
    end

    local dialog, input_dialog
    -- Set while the options dialog hands off to the free-text dialog: its onCloseWidget
    -- fallback must NOT fire a premature SKIP during that handoff (the free-text dialog
    -- then owns the resume).
    local handing_off = false

    -- Free-text path: an InputDialog mirroring _promptFollowup's construction. An empty
    -- Send counts as a skip (the model gets the recoverable note, never a blank result).
    local function promptFreeText()
        local buttons = {
            {
                {
                    text = _("Skip"),
                    callback = function()
                        resume(SKIP)
                        UIManager:close(input_dialog)
                    end,
                },
                {
                    text = _("Send"),
                    is_enter_default = true,
                    callback = function()
                        local a = input_dialog and input_dialog:getInputText()
                        resume((a and a ~= "") and a or SKIP)
                        UIManager:close(input_dialog)
                    end,
                },
            },
        }
        input_dialog = InputDialog:new({
            title = _("Your answer"),
            description = question,
            input = "",
            input_hint = _("Type your answer"),
            text_height = Presets.inputLines(2),
            buttons = buttons,
        })
        -- NO-HANG net: a dismissal frees the widget through onCloseWidget without any
        -- button callback; chain a resume(SKIP) so the loop still wakes. Guarded, so a
        -- real answer (which resumed first) makes this a no-op.
        local orig = input_dialog.onCloseWidget
        input_dialog.onCloseWidget = function(d)
            if orig then
                orig(d)
            end
            resume(SKIP)
        end
        UIManager:show(input_dialog)
        input_dialog:onShowKeyboard()
    end

    if type(options) == "table" and #options > 0 then
        local rows = {}
        for _, opt in ipairs(options) do
            local label = tostring(opt)
            rows[#rows + 1] = {
                {
                    text = label,
                    callback = function()
                        resume(label)
                        UIManager:close(dialog)
                    end,
                },
            }
        end
        rows[#rows + 1] = {
            {
                text = _("Type my own…"),
                callback = function()
                    handing_off = true
                    UIManager:close(dialog)
                    dialog = nil
                    promptFreeText()
                end,
            },
            {
                text = _("Skip"),
                callback = function()
                    resume(SKIP)
                    UIManager:close(dialog)
                end,
            },
        }
        dialog = ButtonDialog:new({
            title = question,
            title_align = "center",
            buttons = rows,
        })
        -- NO-HANG net, as in promptFreeText: a tap-outside / Back dismissal must still
        -- resume. The "Type my own…" path deliberately closes this dialog WITHOUT
        -- resuming -- it hands off to the free-text dialog, which owns the resume -- so
        -- the fallback skips the SKIP while `handing_off` is set.
        local orig = dialog.onCloseWidget
        dialog.onCloseWidget = function(d)
            if orig then
                orig(d)
            end
            if not handing_off then
                resume(SKIP)
            end
        end
        UIManager:show(dialog)
    else
        promptFreeText()
    end

    coroutine.yield()

    -- Fold a short, single-line summary into the "Asked: …" transcript entry.
    if answer == SKIP then
        return SKIP, _("skipped")
    end
    local shown = tostring(answer)
    if #shown > 40 then
        shown = shown:sub(1, 39) .. "…"
    end
    return answer, T(_("“%1”"), shown)
end

-- Re-render this turn's assistant content into the transcript in block order,
-- replacing the live streamed entries (everything past turn_start); see
-- Transcript.renderAssistantTurn for the ordering rationale.
function Conversation:_renderAssistantTurn(content, turn_start, show_thinking)
    Transcript.renderAssistantTurn(self.transcript, content, turn_start, show_thinking)
end

function Conversation:_transcriptText()
    return Transcript.text(self.transcript, self:_usageText())
end

function Conversation:_usageText()
    return Transcript.usageText(self.usage, self.context_size)
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
    -- One status bar (one clock) per user turn: created here at turn start --
    -- multi-round turns never re-enter past the early return above -- and
    -- retired by _render (freeze) or _closeViewer (stop). The paint callback
    -- reads self.viewer at call time, so it follows a rebuilt viewer.
    if not self._statusbar_active then
        self._statusbar = StatusBar.new({
            get_context = function()
                return self.context_size
            end,
            on_paint = function(text)
                if self.viewer then
                    ChatViewer.updateStatus(self.viewer, text)
                end
            end,
        })
        self._statusbar_active = true
        self._status_key = nil
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
        status_text = self._statusbar:text(),
        on_close = function()
            -- Reader closed the viewer mid-stream: without this the ticker would
            -- keep repainting a dead widget once a second until the turn ends.
            if self._statusbar then
                self._statusbar:stop()
            end
        end,
        scroll_to_bottom = true,
    })
    self.streaming_viewer = true
    UIManager:show(self.viewer)
    -- Start after show so the initial paint lands on the live viewer; idempotent
    -- on a rebuilt viewer mid-turn (keeps t0 and the pending tick).
    self._statusbar:start()
end

-- Route an activity change to the status bar, deduped: on_text fires per stream
-- delta, so without the key check the bar would repaint the same "writing" line
-- dozens of times a second.
function Conversation:_setStatus(state, detail)
    if not self._statusbar then
        return
    end
    local key = state .. "\0" .. tostring(detail or "")
    if self._status_key == key then
        return
    end
    self._status_key = key
    self._statusbar:setState(state, detail)
end

function Conversation:_closeViewer()
    self:_cancelFlush()
    -- Cancel/error path: kill the ticker without painting a "done" line.
    if self._statusbar then
        self._statusbar:stop()
        self._statusbar_active = false
    end
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

-- Surface a transient "Retrying… (n/3)" line in the streaming viewer so the reader
-- sees the loop is recovering rather than hung. Appended to the live transcript
-- text only (not stored as a transcript entry), so the next render/_dropDanglingTail
-- naturally drops it; the recovered turn's real content replaces it.
function Conversation:_showRetryStatus(attempt)
    if self.viewer then
        local status = T(_("Retrying… (%1/%2)"), tostring(attempt), tostring(Retry.MAX_STREAM_ATTEMPTS))
        ChatViewer.updateText(self.viewer, self:_transcriptText() .. "\n\n" .. status, true)
    end
end

-- Persist this conversation to the book's sidecar (bbchats). Called only from
-- _render — the single terminal render — so a stored chat always ends on a
-- finished assistant answer, never a dangling mid-tool-round state (the wire
-- history is guaranteed resendable here; that's _dropDanglingTail's invariant).
-- A chat that never reaches a completed turn (turn-one error) is never saved.
-- Failures are logged and swallowed: persistence must never break the render.
function Conversation:_persist()
    -- Nothing new since the last save (or since resume restored the stored
    -- history): skip, so a mere reopen doesn't rewrite an unchanged payload and
    -- bump its ts_updated.
    if #self.messages == 0 or #self.messages == self._last_saved_len then
        return
    end
    if not (self.ui and Chats.baseDirForBook(self.ui)) then
        return
    end
    -- Copy transcript entries minus derived display caches: the stripMarkdown
    -- memo (_md_src/_md_out) and any other _-prefixed transient are pure caches
    -- keyed on the entry's live .text — persisting them bloats the payload and
    -- could mislead after reload; they re-derive on the first render after reopen.
    local transcript = {}
    for i, e in ipairs(self.transcript) do
        local copy = {}
        for k, v in pairs(e) do
            if not (type(k) == "string" and k:sub(1, 1) == "_") then
                copy[k] = v
            end
        end
        transcript[i] = copy
    end
    local state = {
        id = self.chat_id,
        ts_created = self.chat_ts_created,
        selected_text = self.selected_text,
        note = self.note,
        messages = self.messages,
        transcript = transcript,
        usage = self.usage,
    }
    -- The settings double in some specs only implements getConfig; treat a
    -- missing accessor like an unset value and fall back to the default cap.
    local max_chats = self.settings and self.settings.get and tonumber(self.settings:get("max_saved_chats"))
    local ok, id = pcall(Chats.save, self.ui, state, max_chats or Chats.DEFAULT_MAX)
    if ok and id then
        self.chat_id = id
        self.chat_ts_created = state.ts_created
        self._last_saved_len = #self.messages
    elseif not ok then
        logger.warn("BookBuddy: failed to save chat", id)
    end
end

function Conversation:_render()
    self:_persist()
    self:_cancelFlush()
    -- The turn is over -- it's the reader's move. Freeze BEFORE closing the old
    -- viewer (freeze stops the ticker and pins the elapsed time) and seed the
    -- rebuilt Reply-mode viewer with the static "✓ m:ss · done · ctx Nk" line.
    local frozen_status
    if self._statusbar then
        frozen_status = self._statusbar:freeze()
        self._statusbar_active = false
    end
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
        status_text = frozen_status,
        scroll_to_bottom = true,
    })
    self.streaming_viewer = false
    UIManager:show(self.viewer)
end

function Conversation:_promptFollowup()
    local dialog
    -- Guarded access: spec stubs legitimately pass a partial settings double
    -- (getConfig only), and withCustom treats a nil custom list as "none".
    local custom = self.settings and self.settings.getCustomPresets and self.settings:getCustomPresets()
    local buttons = Presets.buttonRows(Presets.withCustom(Presets.followup, custom), function()
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
        text_height = Presets.inputLines(2),
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
