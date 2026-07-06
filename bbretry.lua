-- The single source of truth for the streamed-call retry policy: one Claude call
-- (fork + SSE parse) wrapped in bounded classify/backoff/retry. Both drivers of a
-- Claude stream -- the parent turn loop in bbconversation and the headless subagent
-- driver in bbsubagents -- run their calls through here, so the classifier sets and
-- attempt bounds are never reimplemented (or allowed to drift) per caller. Extracted
-- from bbconversation so bbsubagents no longer has to require the whole UI-owning
-- conversation module just to share this policy.
--
-- Everything here must stay coroutine-friendly and transcript-agnostic: it runs on
-- the caller's Trapper coroutine and touches the UI only through the injected hooks.
--
-- The transport (bbstream) and UIManager are resolved at CALL time, not load time:
-- require() is a cached-table lookup, and late binding means a re-registered
-- package.loaded["bbstream"]/["ui/uimanager"] (the busted fake stream registers
-- itself that way, per describe block) is always the one actually driven -- a
-- load-time upvalue here would pin whichever double happened to be installed when
-- bbretry was first required.
local Anthropic = require("bbanthropic")

local Retry = {}

-- Bounded retry around the Stream.run + parser:result() acquisition. Nothing is
-- stored until the caller commits past streamWithRetries, so re-forking with a fresh
-- parser between attempts is clean and idempotent. 3 attempts is the safety net
-- against a classifier mistake (a misbucketed-retryable error stops after 3, never
-- loops). Exported (read-only by convention) so the conversation's "Retrying… (n/3)"
-- status can show the real bound.
local MAX_STREAM_ATTEMPTS = 3
Retry.MAX_STREAM_ATTEMPTS = MAX_STREAM_ATTEMPTS
-- Exponential backoff base; attempt N waits BACKOFF_BASE_SEC * 2^(N-1) plus jitter.
local BACKOFF_BASE_SEC = 1.0
local BACKOFF_JITTER_SEC = 0.5

-- Classifier sets, named so the retry decision reads as policy, not magic numbers.
-- RETRYABLE HTTP: transient transport/throttle/5xx. TERMINAL HTTP: a request the
-- gateway will reject identically on every resend (bad request / auth / not found
-- / unprocessable), so retrying only burns quota.
local RETRYABLE_HTTP =
    { [408] = true, [425] = true, [429] = true, [500] = true, [502] = true, [503] = true, [504] = true }
local TERMINAL_HTTP = { [400] = true, [401] = true, [403] = true, [404] = true, [422] = true }
-- A mid-stream "error" event carries an Anthropic error type. Only the transient
-- classes retry; everything else (invalid_request_error, authentication_error, …)
-- is terminal.
local RETRYABLE_ERROR_TYPE = { overloaded_error = true, api_error = true, rate_limit_error = true }

-- Classify a finished stream attempt into "ok" / "retry" / "terminal". `r` is
-- Stream.run's return ({cancelled, read_error, …}); `res` is parser:result(). A
-- cancel is ALWAYS terminal and checked first: a user Stop must abort instantly
-- and must never be retried. The empty-200 case (res.ok but no content blocks) is
-- retryable here so the loop re-forks before falling back to the placeholder; the
-- placeholder only stands in after retries are exhausted.
local function classifyAttempt(r, res)
    if r.cancelled then
        return "terminal"
    end
    if r.read_error then
        return "retry" -- network/transport drop, incl. R4's stall watchdog
    end
    if res.network_error then
        -- A child-side transport failure: the fork wrote the X-BB-NETWORK-ERROR
        -- marker then closed cleanly (so the parent sees EOF, not read_error) when
        -- http.request returned no response -- connection refused/reset, DNS/TLS
        -- failure, or the 120s block-timeout firing. All are the same transient class
        -- as r.read_error (a WiFi blip, a gateway dropping the connection), so retry.
        return "retry"
    end
    if res.ok then
        if type(res.content) ~= "table" or #res.content == 0 then
            return "retry" -- empty-200: a known-transient gateway hiccup (R2)
        end
        return "ok"
    end
    if res.incomplete then
        return "retry" -- truncated/undecodable stream (R3)
    end
    if res.code then
        if RETRYABLE_HTTP[res.code] then
            return "retry"
        end
        if TERMINAL_HTTP[res.code] then
            return "terminal"
        end
        -- An unlisted non-200 (e.g. a novel 5xx) is treated as terminal so an
        -- unknown code can't cause an unbounded-feeling 3x retry on a hard failure.
        return "terminal"
    end
    if res.error_type and RETRYABLE_ERROR_TYPE[res.error_type] then
        return "retry"
    end
    return "terminal" -- mid-stream non-retryable error type
end

-- Coroutine-friendly backoff between retry attempts: schedule a delayed resume and
-- yield, mirroring Stream.run's tick idiom so the UI stays live (and a Stop pressed
-- during the wait is delivered, setting the caller's stop flag, which the retry loop
-- re-checks through the stopped() hook after we return). Exponential with jitter to
-- avoid a thundering-herd resend.
-- TODO: honor a server Retry-After header here once the child plumbs it through;
-- the child currently only writes a status marker, not response headers (out of
-- scope for this change).
local function backoff(attempt)
    local UIManager = require("ui/uimanager") -- late-bound; see the module header
    local delay = BACKOFF_BASE_SEC * (2 ^ (attempt - 1)) + math.random() * BACKOFF_JITTER_SEC
    local co = coroutine.running()
    -- One-shot resume: scheduleIn fires it after the real wall-clock delay in
    -- production. (Under the busted harness scheduleIn enqueues onto the nextTick
    -- pump, so the resume runs synchronously and the backoff collapses to instant.)
    local resumed = false
    UIManager:scheduleIn(delay, function()
        if not resumed then
            resumed = true
            coroutine.resume(co)
        end
    end)
    coroutine.yield()
end

-- One streamed Claude call with the bounded retry/backoff/classify policy.
-- classifyAttempt and MAX_STREAM_ATTEMPTS stay the single source of truth here,
-- never reimplemented by a caller. Returns (r, res, verdict) where verdict is
-- "ok" / "terminal" / "retry" (retries exhausted) / "stopped" (a Stop landed during
-- a backoff). The caller owns ALL transcript / viewer / history side effects through
-- the injected hooks, so a transcript-less caller (the subagent driver) passes none:
--   body, cfg            request body + config for the fork
--   make_parser()        a FRESH Anthropic stream parser per attempt (the parent's
--                        closes over its live transcript entries; the child's is bare)
--   register_cancel(fn)  install/clear the cancel closure into the caller's _cancel slot
--   on_attempt_done()    optional: after Stream.run returns (parent cancels its flush)
--   on_retry(next)       optional: before the backoff (parent trims + shows "Retrying")
--   stopped()            optional: predicate checked after a backoff; true => "stopped"
-- This is safe to re-fork between attempts precisely because nothing durable is
-- stored until the caller commits past the helper -- the wire history is already the
-- resendable state to re-fork FROM, so a retry is idempotent (see the callers).
function Retry.streamWithRetries(opts)
    local Stream = require("bbstream") -- late-bound; see the module header
    local r, res, verdict
    for attempt = 1, MAX_STREAM_ATTEMPTS do
        local parser = opts.make_parser()
        r = Stream.run({
            child_fn = Anthropic.streamChildFn(opts.body, opts.cfg),
            on_line = function(line)
                parser:feed(line)
            end,
            register_cancel = opts.register_cancel,
        })
        if opts.on_attempt_done then
            opts.on_attempt_done()
        end
        res = parser:result()
        verdict = classifyAttempt(r, res)
        if verdict ~= "retry" then
            return r, res, verdict
        end
        -- Retryable, and attempts remain. The caller's on_retry only trims its
        -- live-stream display partials; the wire history is untouched and resendable.
        if attempt < MAX_STREAM_ATTEMPTS then
            if opts.on_retry then
                opts.on_retry(attempt + 1)
            end
            backoff(attempt)
            -- A Stop tapped during the backoff must abort instantly, never silently
            -- consume a retry (it set the stopped() flag; there was no live stream to
            -- cancel during the wait). Signal it and let the caller unwind.
            if opts.stopped and opts.stopped() then
                return r, res, "stopped"
            end
        end
    end
    return r, res, verdict -- "retry": exhausted
end

return Retry
