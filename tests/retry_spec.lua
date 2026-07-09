-- bbretry unit checks: the per-attempt delay policy (computeDelay) and the
-- HTTP-code classification, driven end-to-end through streamWithRetries over the
-- scripted fake transport + the real bbanthropic parser (so the child-marker →
-- parser → classifier → delay plumbing is exercised, not mocked). The
-- conversation-level retry behaviour (transcript trimming, retry status lines,
-- stop-during-backoff) stays in conversation_spec.
local stubs = require("support.stubs")
local sse = require("support.sse")

describe("bbretry", function()
    local Retry, Anthropic, Trapper, fake

    setup(function()
        stubs.install()
        fake = sse.new_fake_stream({})
        Anthropic = require("bbanthropic")
        Retry = require("bbretry")
        Trapper = require("ui/trapper")
    end)

    -- Jitter is uniform in [0, JITTER); assert the deterministic part exactly and
    -- the jitter by range, instead of monkeypatching math.random.
    local JITTER = 0.5
    local function assert_delay(expected, actual)
        assert.is_true(
            actual >= expected and actual < expected + JITTER,
            string.format("delay %s not in [%s, %s)", tostring(actual), tostring(expected), tostring(expected + JITTER))
        )
    end

    describe("computeDelay", function()
        it("grows exponentially with the attempt number", function()
            assert_delay(1, Retry.computeDelay(1, {}))
            assert_delay(2, Retry.computeDelay(2, {}))
            assert_delay(4, Retry.computeDelay(3, {}))
        end)

        it("caps the exponential so a raised attempt cap can never park the reader", function()
            assert_delay(30, Retry.computeDelay(10, {}))
        end)

        it("backs off harder on throttle-shaped failures", function()
            assert_delay(4, Retry.computeDelay(1, { code = 429 }))
            assert_delay(8, Retry.computeDelay(2, { code = 529 }))
            assert_delay(4, Retry.computeDelay(1, { error_type = "rate_limit_error" }))
            assert_delay(4, Retry.computeDelay(1, { error_type = "overloaded_error" }))
            -- A generic transient failure keeps the plain base.
            assert_delay(1, Retry.computeDelay(1, { code = 503 }))
        end)

        it("honors a server Retry-After as a floor on the computed delay", function()
            -- Above the computed backoff: the server's hint wins.
            assert_delay(25, Retry.computeDelay(1, { code = 503, retry_after = 25 }))
            -- Below it: the hint never SHORTENS our own backoff (429 base is 4s).
            assert_delay(4, Retry.computeDelay(1, { code = 429, retry_after = 2 }))
        end)

        it("caps an oversized Retry-After instead of obeying it", function()
            assert_delay(60, Retry.computeDelay(1, { code = 429, retry_after = 300 }))
        end)

        it("ignores an absent or non-numeric retry_after", function()
            assert_delay(1, Retry.computeDelay(1, { code = 503 }))
            assert_delay(1, Retry.computeDelay(1, { code = 503, retry_after = "soonish" }))
            assert_delay(1, Retry.computeDelay(1, nil))
        end)
    end)

    describe("streamWithRetries classification", function()
        -- A non-200 as the child streams it: the JSON error body, the status
        -- marker, then (optionally) the relayed Retry-After header marker.
        local function non200(code, retry_after)
            local lines = {
                stubs.json.encode({ error = { type = "server_error", message = "boom " .. tostring(code) } }),
                "X-BB-NON-200: " .. tostring(code),
            }
            if retry_after then
                lines[#lines + 1] = "X-BB-RETRY-AFTER: " .. tostring(retry_after)
            end
            return lines
        end

        local function goodSSE()
            return sse.buildTurnSSE({ blocks = { { type = "text", text = "recovered" } } })
        end

        -- Drive one call through the real retry loop on the Trapper pump (backoff
        -- yields; the stubbed scheduleIn resumes it via the nextTick queue).
        local function stream(responses)
            fake:reset(responses)
            local out = { retries = {} }
            Trapper:wrap(function()
                out.r, out.res, out.verdict = Retry.streamWithRetries({
                    body = "{}",
                    cfg = {},
                    make_parser = function()
                        return Anthropic.newStreamParser({})
                    end,
                    on_retry = function(next_attempt, delay)
                        out.retries[#out.retries + 1] = { attempt = next_attempt, delay = delay }
                    end,
                })
            end)
            return out
        end

        it("retries an Anthropic 529 (overloaded) to recovery", function()
            local out = stream({ non200(529), goodSSE() })
            assert.are.equal("ok", out.verdict)
            assert.are.equal(2, fake.idx)
            -- The 529 attempt backed off on the heavier throttle base.
            assert.are.equal(1, #out.retries)
            assert_delay(4, out.retries[1].delay)
        end)

        it("retries a novel unlisted 5xx (Cloudflare-style 522)", function()
            local out = stream({ non200(522), goodSSE() })
            assert.are.equal("ok", out.verdict)
            assert.are.equal(2, fake.idx)
        end)

        it("treats a 501 as terminal despite being 5xx", function()
            local out = stream({ non200(501), goodSSE() })
            assert.are.equal("terminal", out.verdict)
            assert.are.equal(501, out.res.code)
            assert.are.equal(1, fake.idx) -- the scripted recovery is never consumed
        end)

        it("keeps a novel 4xx terminal", function()
            local out = stream({ non200(418), goodSSE() })
            assert.are.equal("terminal", out.verdict)
            assert.are.equal(1, fake.idx)
        end)

        it("paces the backoff on a relayed Retry-After header", function()
            -- End-to-end: the child's X-BB-RETRY-AFTER marker reaches the parser,
            -- rides res.retry_after into computeDelay, and floors the wait that
            -- on_retry reports.
            local out = stream({ non200(429, 7), goodSSE() })
            assert.are.equal("ok", out.verdict)
            assert.are.equal(1, #out.retries)
            assert.are.equal(2, out.retries[1].attempt)
            assert_delay(7, out.retries[1].delay)
        end)
    end)
end)
