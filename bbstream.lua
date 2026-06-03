-- Generic streaming transport: runs a child function in a forked subprocess and
-- feeds whatever it writes to the pipe back to the parent line by line, while
-- the UI stays responsive. Knows nothing about HTTP or SSE — line classification
-- is the caller's job (see bbanthropic.newStreamParser).
--
-- It must run inside a coroutine (LuaJIT's main thread can't yield); BookBuddy
-- provides one via Trapper:wrap. The loop mirrors Trapper:dismissableRunInSubprocess
-- but reads incrementally instead of blocking on readAllFromFD until EOF.
local UIManager = require("ui/uimanager")
local logger = require("logger")
local ffi = require("ffi")
local ffiutil = require("ffi/util")

local Stream = {}

local CHECK_INTERVAL_SEC = 0.125
local CHUNK_SIZE = 1024 * 16
local COLLECT_INTERVAL_SEC = 5

-- Parent-side stall watchdog. The child sets only a between-chunk socket timeout
-- (bbanthropic: 120s, no total), so a server trickling one byte just under that
-- timeout can hang for minutes without the child ever erroring. We measure wall
-- time since the last COMPLETE line was delivered to on_line and abort the read as
-- a read_error (which the conversation loop treats as retryable) once it exceeds
-- this. Deliberately >> CHECK_INTERVAL_SEC so a normally-paced stream never trips
-- it, and there is NO hard total cap: a long legitimate reply keeps streaming for
-- as long as it makes progress, because every delivered line (data OR SSE
-- comment/keep-alive) resets the timer.
--
-- Validation boundary: tier-1 specs replace this whole module with a synchronous
-- fake (tests/support/sse.lua), so the real wall-clock tick loop here is not
-- exercised under busted; the watchdog's timer behaviour is validated manually /
-- against real crengine (tier-2). What tier-1 DOES cover is that a read_error
-- result is plumbed through the conversation loop's retry classifier.
local STALL_TIMEOUT_SEC = 90

-- The stall decision, factored out of the wall-clock tick loop so its boundary is
-- unit-testable at tier-1 (the fake transport replaces Stream.run wholesale, so the
-- inline check below would otherwise never run under busted). Abort strictly AFTER
-- the timeout elapses: exactly STALL_TIMEOUT_SEC of silence is still tolerated, so a
-- stream that delivers a line every 90s on the dot keeps going. last_progress is
-- reset on every complete line in process_lines, so any delivered byte stream (data
-- OR keep-alive) resets the clock and this returns false again.
function Stream.shouldAbortStall(now, last_progress)
    return (now - last_progress) > STALL_TIMEOUT_SEC
end

-- opts: { child_fn, on_line, register_cancel }
--   child_fn(pid, child_write_fd): runs in the subprocess, writes bytes to the fd.
--   on_line(line): called per complete line (newline stripped) as data arrives.
--   register_cancel(fn|nil): receives an interrupt closure for the duration of the
--       stream (and nil once it ends) so a Stop button can cancel mid-flight.
-- Returns { completed, cancelled, read_error }.
function Stream.run(opts)
    local pid, parent_read_fd = ffiutil.runInSubProcess(opts.child_fn, true)
    if not pid then
        logger.warn("BookBuddy: failed to start streaming subprocess")
        return { completed = false, cancelled = false, read_error = true }
    end

    local _coroutine = coroutine.running()
    local cancelled, read_error, completed = false, false, false

    if opts.register_cancel then
        opts.register_cancel(function()
            coroutine.resume(_coroutine, false)
        end)
    end

    local buffer = ffi.new("char[?]", CHUNK_SIZE)
    local buffer_ptr = ffi.cast("void*", buffer)
    local partial_data = ""

    -- Liveness clock for the stall watchdog: reset on EVERY complete line handed to
    -- on_line below, so even SSE comment / ":" keep-alive lines count as progress
    -- and a chatty-but-slow stream is never false-timed-out.
    local last_progress = os.time()

    local function process_lines()
        while true do
            local line_end = partial_data:find("[\r\n]")
            if not line_end then
                break
            end
            local line = partial_data:sub(1, line_end - 1)
            partial_data = partial_data:sub(line_end + 1)
            last_progress = os.time()
            if opts.on_line then
                opts.on_line(line)
            end
        end
    end

    while not completed do
        -- Hand control back to the UI, then resume on the next tick (true) unless
        -- the cancel closure resumes us first (false).
        local go_on_func = function()
            coroutine.resume(_coroutine, true)
        end
        UIManager:scheduleIn(CHECK_INTERVAL_SEC, go_on_func)
        if not coroutine.yield() then
            cancelled = true
            UIManager:unschedule(go_on_func)
            break
        end

        local readsize = ffiutil.getNonBlockingReadSize(parent_read_fd)
        if readsize and readsize > 0 then
            -- Drain everything the kernel has buffered this tick (not just one
            -- CHUNK_SIZE) so throughput isn't pinned to one read per CHECK_INTERVAL.
            while readsize and readsize > 0 do
                local bytes_read = tonumber(ffi.C.read(parent_read_fd, buffer_ptr, CHUNK_SIZE))
                if bytes_read < 0 then
                    logger.warn("BookBuddy: stream read error:", ffi.string(ffi.C.strerror(ffi.errno())))
                    read_error = true
                    break
                elseif bytes_read == 0 then
                    completed = true
                    break
                else
                    partial_data = partial_data .. ffi.string(buffer, bytes_read)
                    process_lines()
                end
                readsize = ffiutil.getNonBlockingReadSize(parent_read_fd)
            end
            if read_error then
                break
            end
        elseif ffiutil.isSubProcessDone(pid) then
            -- Nothing buffered and the child has exited: we've drained the pipe.
            completed = true
        elseif Stream.shouldAbortStall(os.time(), last_progress) then
            -- Child still alive but no line has arrived for STALL_TIMEOUT_SEC: the
            -- stream is wedged below the child's between-chunk socket timeout. Abort
            -- as a read_error so the conversation loop retries; unschedule the
            -- pending tick resume since we break out before yielding to it again.
            logger.warn("BookBuddy: stream stalled; no progress for", STALL_TIMEOUT_SEC, "s")
            read_error = true
            UIManager:unschedule(go_on_func)
            break
        end
    end

    -- A final line without a trailing newline only matters on a clean finish.
    if completed and #partial_data > 0 and opts.on_line then
        opts.on_line(partial_data)
    end

    if opts.register_cancel then
        opts.register_cancel(nil)
    end

    -- Kill the child (no-op if it already exited) and reap it lazily so a
    -- cancelled or write-blocked subprocess can't linger as a zombie.
    ffiutil.terminateSubProcess(pid)
    local collect_and_clean
    collect_and_clean = function()
        if ffiutil.isSubProcessDone(pid) then
            if parent_read_fd then
                ffiutil.readAllFromFD(parent_read_fd)
                parent_read_fd = nil
            end
        else
            if parent_read_fd and (ffiutil.getNonBlockingReadSize(parent_read_fd) or 0) ~= 0 then
                -- Drain so the child's write() unblocks and it can exit.
                ffiutil.readAllFromFD(parent_read_fd)
                parent_read_fd = nil
            end
            UIManager:scheduleIn(COLLECT_INTERVAL_SEC, collect_and_clean)
        end
    end
    UIManager:scheduleIn(COLLECT_INTERVAL_SEC, collect_and_clean)

    return { completed = completed, cancelled = cancelled, read_error = read_error }
end

return Stream
