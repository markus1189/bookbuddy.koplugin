-- Tier-1 coverage for bbstream's pure stall-watchdog decision. The wall-clock tick
-- loop in Stream.run is replaced wholesale by the fake transport in the conversation
-- specs, so its inline timing was never exercised; Stream.shouldAbortStall factors
-- the boundary out so it can be pinned here. (The plumbing -- that a read_error from
-- the loop reaches the retry classifier -- is covered by R1/R1b in conversation_spec.)
local stubs = require("support.stubs")

describe("bbstream stall watchdog", function()
    local Stream
    setup(function()
        stubs.install()
        Stream = require("bbstream")
    end)

    it("tolerates exactly STALL_TIMEOUT_SEC of silence (no abort at the boundary)", function()
        -- 90s on the dot is still progress-tolerated: abort is strictly AFTER the
        -- timeout. now - last_progress == 90 must NOT abort.
        assert.is_false(Stream.shouldAbortStall(1090, 1000)) -- 90s elapsed
        assert.is_false(Stream.shouldAbortStall(1089, 1000)) -- 89s elapsed
    end)

    it("aborts once silence EXCEEDS STALL_TIMEOUT_SEC", function()
        assert.is_true(Stream.shouldAbortStall(1091, 1000)) -- 91s elapsed
        assert.is_true(Stream.shouldAbortStall(2000, 1000)) -- long stall
    end)

    it("a fresh delivery resets the clock back below the threshold", function()
        -- Model process_lines resetting last_progress to now on a delivered line: the
        -- elapsed window collapses to 0, so the very next tick must not abort.
        local now = 5000
        assert.is_true(Stream.shouldAbortStall(now, now - 200)) -- stalled before the line
        local last_progress = now -- a line just arrived, resetting the clock
        assert.is_false(Stream.shouldAbortStall(now, last_progress))
    end)
end)
