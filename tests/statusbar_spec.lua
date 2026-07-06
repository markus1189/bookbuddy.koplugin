-- The real bbstatusbar driven headlessly: the stub UIManager queues the ticker's
-- scheduleIn callbacks onto handle.tick_queue and the spec pops them by hand (the
-- Trapper pump never runs here -- it would spin forever on a self-rearming
-- ticker, which is exactly why conversation_spec sees a recording double
-- instead). The clock is a fake so elapsed-time assertions are exact.
local stubs = require("support.stubs")

describe("statusbar", function()
    local StatusBar, handle
    local real_now

    setup(function()
        handle = stubs.install()
        -- stubs.install registers a bbstatusbar recording double for the
        -- conversation specs; this spec wants the real module.
        package.loaded["bbstatusbar"] = nil
        StatusBar = require("bbstatusbar")
        real_now = StatusBar.now
    end)

    teardown(function()
        StatusBar.now = real_now
        package.loaded["bbstatusbar"] = nil
    end)

    local t, paints, ctx, bar

    local function newBar()
        return StatusBar.new({
            on_paint = function(text)
                paints[#paints + 1] = text
            end,
            get_context = function()
                return ctx
            end,
        })
    end

    before_each(function()
        t = 1000
        ctx = 0
        paints = {}
        StatusBar.now = function()
            return t
        end
        for i = #handle.tick_queue, 1, -1 do
            handle.tick_queue[i] = nil
        end
        bar = newBar()
    end)

    -- Pop and run the single queued ticker callback, as UIManager would after
    -- the tick interval elapsed.
    local function fireTick()
        local fn = table.remove(handle.tick_queue, 1)
        assert.is_function(fn, "expected a queued tick")
        fn()
    end

    it("paints the initial line and arms exactly one tick on start", function()
        bar:start()
        assert.are.same({ "| 0:00 · connecting" }, paints)
        assert.are.equal(1, #handle.tick_queue)
    end)

    it("ticks advance the spinner frame and track the wall clock", function()
        bar:start()
        t = t + 61
        fireTick()
        assert.are.equal("/ 1:01 · connecting", paints[#paints])
        assert.are.equal(1, #handle.tick_queue, "tick should re-arm itself")
    end)

    it("cycles | / - \\ and wraps back to |", function()
        bar:start()
        local seen = {}
        for _ = 1, 4 do
            fireTick()
            seen[#seen + 1] = paints[#paints]:sub(1, 1)
        end
        assert.are.same({ "/", "-", "\\", "|" }, seen)
    end)

    it("setState paints immediately with the activity label", function()
        bar:start()
        bar:setState("tool", "grep_book")
        assert.are.equal("| 0:00 · using grep_book", paints[#paints])
        bar:setState("retrying", "2/3")
        assert.are.equal("| 0:00 · retrying 2/3", paints[#paints])
        assert.are.equal(1, #handle.tick_queue, "setState must not schedule extra ticks")
    end)

    it("shows the context segment once usage has landed, abbreviated", function()
        bar:start()
        ctx = 12345
        fireTick()
        assert.are.equal("/ 0:00 · connecting · ctx 12k", paints[#paints])
        ctx = 900
        bar:setState("writing")
        assert.are.equal("/ 0:00 · writing · ctx 900", paints[#paints])
    end)

    it("freeze stops the ticker, pins the elapsed time, and returns the frozen line", function()
        bar:start()
        t = t + 94
        local frozen = bar:freeze()
        assert.are.equal("✓ 1:34 · done", frozen)
        assert.are.equal(frozen, paints[#paints])
        -- The tick armed by start() is still queued (the stub's unschedule is a
        -- no-op): popping it must neither paint nor re-arm.
        local n = #paints
        t = t + 10
        fireTick()
        assert.are.equal(n, #paints)
        assert.are.equal(0, #handle.tick_queue)
        -- And the frozen line keeps the final duration even if re-read later.
        assert.are.equal("✓ 1:34 · done", bar:text())
    end)

    it("stop halts painting without a frozen line, and is idempotent", function()
        bar:start()
        bar:stop()
        bar:stop()
        local n = #paints
        fireTick() -- stale queued tick
        assert.are.equal(n, #paints)
        assert.are.equal(0, #handle.tick_queue)
        bar:freeze()
        bar:stop() -- no-op after freeze
    end)

    it("a second start neither resets the clock nor double-schedules", function()
        bar:start()
        t = t + 30
        bar:start()
        assert.are.equal(1, #handle.tick_queue)
        fireTick()
        assert.are.equal("/ 0:30 · connecting", paints[#paints])
    end)
end)
