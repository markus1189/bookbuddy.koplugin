-- A subagent: a read-only, spoiler-safe child agent the main agent delegates a
-- focused research task to. It runs a bounded tool loop over its OWN messages array
-- -- the intermediate grep/read churn never enters the parent's resent history --
-- and returns a single condensed string. The headline win is context isolation.
--
-- Deliberately NOT built via Conversation:new (D2): that constructor CLEARS the
-- shared ui's locator/search state (the _bookbuddy_* reset in Conversation:new), so a child built
-- mid-conversation would silently wipe the parent's live locator table and break a
-- later parent create_highlight{search_result=N} / read{from=loc:N}. This driver is
-- a plain function over a private messages array; it touches the shared ui only
-- through the read tools, and snapshots/restores the one piece of shared search
-- state it can perturb (ui._bookbuddy_last_search, D8).
--
-- It runs on the PARENT's coroutine (D3): the delegate dispatch site is reached only
-- after the parent stream fully returned, so a nested Stream.run is legal. The child
-- MUST NOT spin its own Trapper:wrap.
local Anthropic = require("bbanthropic")
local History = require("bbhistory")
local Prompts = require("bbprompts")
local Retry = require("bbretry") -- the shared single-call retry/backoff policy
local Tools = require("bbtools")
local logger = require("logger")

local Subagents = {}

-- A child may read across several rounds, bounded so a wandering task cannot run
-- forever. The last round drops the tools so the child must answer in text. This is
-- only the fallback when cfg carries no value; the live default is set in bbsettings
-- (subagent_max_turns) and overridable per-user. Keep the two in sync.
local DEFAULT_CHILD_MAX_TURNS = 12

-- Only the first level of delegation is allowed. The PRIMARY bound is that the child
-- has no delegate tool (childSpecs strips it, so the model cannot emit one); this
-- depth cap is the backstop (D6). The parent calls with depth = (own depth) + 1 = 1.
local MAX_SUBAGENT_DEPTH = 1

-- Force every child read to honor the reader's LIVE current page unless the
-- delegation explicitly allowed spoilers. We clamp on the tool input before
-- Tools.execute, so the child is structurally unable to read ahead even if its
-- prompt argues for it -- a net hardening over the parent, where spoiler=true is
-- always reachable. currentPage is re-derived per call from the live ui, so the
-- boundary tracks the reader turning pages (D7). Only grep and read expose a
-- spoiler/page surface; clamping the others is a harmless no-op so we keep it simple.
local function sanitizeInput(name, input, ui, allow_spoiler)
    input = input or {}
    if allow_spoiler then
        return input -- the reader asked to read ahead for this delegation
    end
    input.spoiler = false
    if name == "grep" then
        local cur = Tools.currentPage(ui)
        if cur then
            local mp = tonumber(input.max_page)
            if not mp or mp > cur then
                input.max_page = cur
            end
        end
    end
    return input
end

-- Run one delegated sub-task to completion and return (text, err): the child's final
-- condensed answer, or (nil, message) when it could not produce one. o:
--   ui, cfg               shared live context + resolved config
--   task                  the natural-language sub-task
--   allow_spoiler         when true, the per-call input scrub is relaxed (D7)
--   depth                 delegation depth (parent passes 1); > MAX_SUBAGENT_DEPTH refused
--   stop()                optional: predicate; true => abort at the next round boundary
--   set_cancel(fn|nil)    optional: install/clear the child stream's cancel closure into
--                         the parent's _cancel slot so a Stop aborts the live child stream
--   on_status(round, max) optional: per-round progress callback (round number + the
--                         turn ceiling); fires at the START of each round so the
--                         parent can surface a live "step N/max" line. The child
--                         itself renders nothing.
-- luacheck: push
-- luacheck: max cyclomatic complexity 27 (grandfathered; see .luacheckrc)
function Subagents.runSubagent(o)
    o = o or {}
    local ui = o.ui
    local cfg = o.cfg
    local task = o.task or ""
    local allow_spoiler = o.allow_spoiler == true
    local depth = o.depth or 1
    local stop = o.stop or function()
        return false
    end
    local on_status = o.on_status or function() end

    -- D6 backstop: refuse beyond the first level. Returns before any stream is forked.
    if depth > MAX_SUBAGENT_DEPTH then
        logger.warn("BookBuddy: subagent depth", depth, "exceeds limit; refusing to recurse")
        return nil, "A helper agent cannot start another helper agent."
    end

    -- Refuse an empty task before forking a stream. `task` is required by the schema,
    -- but the gateway may not enforce it; a blank task would otherwise seed an empty
    -- <task></task> and burn a full round-trip on nothing. Like the depth guard above,
    -- this returns before any stream is forked.
    task = task:match("^%s*(.-)%s*$") or ""
    if task == "" then
        return nil, "The delegated task was empty."
    end

    local max_turns = math.max(1, tonumber(cfg and cfg.subagent_max_turns) or DEFAULT_CHILD_MAX_TURNS)
    local specs = Tools.childSpecs()

    -- D8: snapshot the parent's last-search so a child grep cannot re-point a later
    -- parent create_highlight{search_result=N}. Restored in every exit path below.
    local saved_last_search = ui and ui._bookbuddy_last_search

    -- Seed the child's OWN history (D2: not Conversation:new): the researcher
    -- system prompt + a fresh live book_context + the task, all in the first user
    -- message. book_context is read live so the child knows the current position.
    local context = Tools.execute("book_context", {}, ui)
    local seed = Prompts.CHILD_SYSTEM_PROMPT
        .. "\n\n<book_context>\n"
        .. tostring(context)
        .. "\n</book_context>\n\n<task>\n"
        .. task
        .. "\n</task>"
    local messages = { { role = "user", content = seed } }

    local final_text = ""
    local err

    local rounds = 0
    while rounds < max_turns do
        rounds = rounds + 1
        on_status(rounds, max_turns)
        -- Last allowed round: drop the tools so the model must answer in text rather
        -- than asking for another tool call we'd have to refuse (mirrors _loop).
        local last_round = rounds >= max_turns
        local tools = (not last_round) and specs or nil
        local body = Anthropic.buildBody(messages, tools, cfg)

        -- Headless: a bare parser (no on_text/on_thinking), no flush, no viewer (D9).
        -- set_cancel routes the child stream's cancel closure into the parent's single
        -- _cancel slot so a Stop aborts the live child stream; stop() catches a Stop
        -- that lands during a backoff. Retry.streamWithRetries is shared with the
        -- parent loop (bbretry is the single source of the retry policy).
        local r, res, verdict = Retry.streamWithRetries({
            body = body,
            cfg = cfg,
            make_parser = function()
                return Anthropic.newStreamParser({})
            end,
            register_cancel = o.set_cancel,
            stopped = stop,
        })

        if verdict == "stopped" or r.cancelled then
            err = "The helper was stopped before finishing."
            break
        end
        if verdict ~= "ok" then
            err = "The helper could not reach the model to finish the task."
            break
        end
        if type(res.content) ~= "table" or #res.content == 0 then
            err = "The helper got an empty reply."
            break
        end

        -- Commit the assistant turn to the CHILD's history (never the parent's).
        messages[#messages + 1] = { role = "assistant", content = res.content }

        local text_parts, tool_uses = History.split(res.content)
        if #text_parts > 0 then
            final_text = table.concat(text_parts, "\n")
        end

        if res.stop_reason == "tool_use" and #tool_uses > 0 then
            local tool_results = {}
            for i = 1, #tool_uses do
                local tu = tool_uses[i]
                local sanitized = sanitizeInput(tu.name, tu.input, ui, allow_spoiler)
                local result = Tools.execute(tu.name, sanitized, ui)
                tool_results[#tool_results + 1] = {
                    type = "tool_result",
                    tool_use_id = tu.id,
                    content = result,
                }
            end
            messages[#messages + 1] = { role = "user", content = tool_results }
        else
            break -- end_turn (or a turn with no tool calls): the child is done
        end
    end

    -- D8: restore the parent's last-search no matter how we exited, so a child search
    -- never silently re-points a later parent action keyed on the most recent search.
    if ui then
        ui._bookbuddy_last_search = saved_last_search
    end

    -- A turn-limit or recoverable error with SOME text still returns the best result
    -- so far (spec: "returns the best condensed result produced so far"); only a hard
    -- failure with nothing to show surfaces the error to the parent.
    if final_text ~= "" then
        return final_text, nil
    end
    return nil, err or "The helper produced no result."
end
-- luacheck: pop

return Subagents
