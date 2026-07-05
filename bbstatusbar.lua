-- Live status line for the conversation viewer: an animated spinner, the elapsed
-- time of the in-flight agentic turn, the current activity ("thinking", "using
-- grep_book", ...) and the live context-window size. UI-agnostic on purpose: it
-- paints through an injected on_paint(text) callback and reads tokens through an
-- injected get_context(), so bbconversation owns the wiring and the tier-1 specs
-- can drive the real module headlessly (bbchatviewer stays a recording double).
--
-- Lifecycle: new() -> start() (captures the turn's t0 and arms a 1s ticker) ->
-- setState() on activity changes -> freeze() when the turn ends and it's the
-- reader's move (static line, ticker stopped) or stop() on cancel/error/close
-- (ticker stopped, nothing painted). One instance per user turn: a follow-up
-- ask() builds a fresh bar, which is what resets the clock.
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local StatusBar = {}
StatusBar.__index = StatusBar

-- 1s matches the elapsed counter's resolution, and one small-region repaint per
-- second is far below the transcript's 0.4s full-text flush cadence on e-ink.
local TICK_INTERVAL_SEC = 1

-- ASCII-only spinner: braille (U+2800) and quadrant-circle (U+25D0) spinners are
-- not covered by NotoSans and fall back inconsistently across device font stacks,
-- so a tofu-proof four-frame bar is the safe choice on e-ink.
local FRAMES = { "|", "/", "-", "\\" }

-- Wall clock, seconds. Module-level so specs can monkeypatch it; elapsed time is
-- always now() - t0 rather than a tick count, so scheduler drift never skews it.
StatusBar.now = os.time

-- Keep in sync with abbrevTokens in bbconversation.lua (the transcript footer):
-- both round >=1000 to "Nk". Duplicated because this module must not require
-- bbconversation, and a shared util module for five lines isn't worth it.
local function abbrevTokens(n)
    if n >= 1000 then
        return string.format("%dk", math.floor(n / 1000 + 0.5))
    end
    return tostring(n)
end

local function stateLabel(state, detail)
    if state == "connecting" then
        return _("connecting")
    elseif state == "thinking" then
        return _("thinking")
    elseif state == "writing" then
        return _("writing")
    elseif state == "tool" then
        return T(_("using %1"), tostring(detail))
    elseif state == "retrying" then
        return T(_("retrying %1"), tostring(detail))
    elseif state == "asking" then
        return _("waiting for your answer")
    elseif state == "done" then
        return _("done")
    end
    return tostring(state)
end

-- opts: { on_paint = fn(text), get_context = fn() -> tokens }
function StatusBar.new(opts)
    local o = setmetatable({}, StatusBar)
    o.on_paint = opts and opts.on_paint
    o.get_context = (opts and opts.get_context) or function()
        return 0
    end
    o._frame = 1
    o._state = "connecting"
    o._detail = nil
    o._running = false
    o._frozen = false
    return o
end

function StatusBar:_elapsedText()
    local t0 = self._t0 or self.now()
    -- freeze() pins the end time so the frozen line keeps the turn's final
    -- duration even if it's re-rendered later.
    local now = self._t_end or self.now()
    local sec = math.max(0, now - t0)
    return string.format("%d:%02d", math.floor(sec / 60), sec % 60)
end

-- Pure formatter: "<spinner|✓> <m:ss> · <activity> · ctx <Nk>". The ctx segment
-- is omitted while get_context() is 0 (no API call has reported usage yet).
function StatusBar:text()
    local marker = self._frozen and "✓" or FRAMES[self._frame]
    local parts = { marker .. " " .. self:_elapsedText(), stateLabel(self._state, self._detail) }
    local ctx = self.get_context() or 0
    if ctx > 0 then
        parts[#parts + 1] = T(_("ctx %1"), abbrevTokens(ctx))
    end
    return table.concat(parts, " · ")
end

function StatusBar:_paint()
    if self.on_paint then
        self.on_paint(self:text())
    end
end

-- Arm the ticker and paint the initial line. Idempotent while running (a
-- multi-round turn re-enters _ensureStreamingViewer): t0 and the pending tick
-- are preserved, so the clock spans the whole turn and never double-schedules.
function StatusBar:start()
    if self._running then
        return
    end
    self._running = true
    self._frozen = false
    self._t0 = self._t0 or self.now()
    -- One stable closure per instance so UIManager:unschedule(self._tick_fn)
    -- removes exactly what scheduleIn armed.
    self._tick_fn = self._tick_fn or function()
        self:_tick()
    end
    self:_paint()
    UIManager:scheduleIn(TICK_INTERVAL_SEC, self._tick_fn)
end

function StatusBar:_tick()
    -- Leak backstop: a tick that was already queued when freeze()/stop()
    -- unscheduled must neither paint nor re-arm (the headless UIManager double's
    -- unschedule is a no-op, and even on-device unschedule can race the pop).
    if not self._running then
        return
    end
    self._frame = self._frame % #FRAMES + 1
    self:_paint()
    UIManager:scheduleIn(TICK_INTERVAL_SEC, self._tick_fn)
end

-- state: connecting | thinking | writing | tool | retrying | asking (see
-- stateLabel); detail carries the tool name / retry counter. Paints immediately
-- so an activity change shows up without waiting for the next tick.
function StatusBar:setState(state, detail)
    self._state = state
    self._detail = detail
    if self._running then
        self:_paint()
    end
end

-- Stop the ticker without painting: cancel/error/viewer-close paths where the
-- viewer is going away. Idempotent, and a no-op after freeze().
function StatusBar:stop()
    if not self._running then
        return
    end
    self._running = false
    if self._tick_fn then
        UIManager:unschedule(self._tick_fn)
    end
end

-- The turn is over and it's the reader's move: stop the ticker, pin the elapsed
-- time, and compose the static "✓ m:ss · done · ctx Nk" line. Returns the text so
-- _render can seed the rebuilt Reply-mode viewer's bar with it; also paints, so
-- the still-open streaming viewer shows the final state until that rebuild.
function StatusBar:freeze()
    self:stop()
    self._frozen = true
    self._t_end = self.now()
    self._state = "done"
    self._detail = nil
    local text = self:text()
    if self.on_paint then
        self.on_paint(text)
    end
    return text
end

return StatusBar
