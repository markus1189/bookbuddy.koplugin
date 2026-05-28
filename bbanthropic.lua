-- Minimal Anthropic Messages API client routed through a Portkey gateway.
-- buildBody/decode run in the main process (rapidjson keeps the object/array
-- distinction across decode→encode so tool_use inputs round-trip correctly).
-- request() is meant to run inside a Trapper subprocess: it touches no UI or
-- document state and returns a plain, serializable table.

local ANTHROPIC_VERSION = "2023-06-01"

local Anthropic = {}

function Anthropic.buildBody(messages, tool_specs, cfg)
    local rapidjson = require("rapidjson")
    local body = {
        model = cfg.model,
        max_tokens = cfg.max_tokens,
        system = {
            {
                type = "text",
                text = cfg.system_prompt or "",
                cache_control = { type = "ephemeral" },
            },
        },
        messages = messages,
    }
    if tool_specs and #tool_specs > 0 then
        body.tools = tool_specs
    end
    return rapidjson.encode(body)
end

function Anthropic.decode(body)
    if not body or body == "" then
        return nil
    end
    local rapidjson = require("rapidjson")
    local ok, result = pcall(rapidjson.decode, body)
    if ok and type(result) == "table" then
        return result
    end
    return nil
end

-- Runs in a forked subprocess. Returns { ok, code, body, network_error }.
function Anthropic.request(body_json, cfg)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local socketutil = require("socketutil")

    local sink = {}
    local headers = {
        ["content-type"] = "application/json",
        ["anthropic-version"] = ANTHROPIC_VERSION,
        ["x-portkey-api-key"] = cfg.portkey_api_key,
        -- Anthropic's API mandates an x-api-key header; Portkey authenticates via
        -- x-portkey-api-key plus the provider-prefixed model slug, so the value
        -- here is an ignored placeholder.
        ["x-api-key"] = "dummy",
        ["content-length"] = tostring(#body_json),
    }

    -- Non-streaming: the gateway holds the socket until the whole reply is
    -- generated, so the block (time-to-first-byte) timeout must cover the model's
    -- entire generation, not just network latency. With a high max_tokens a long
    -- reply can take many minutes; the user can still cancel anytime via Trapper.
    socketutil:set_timeout(600, 660)
    local code, resp_headers = socket.skip(1, http.request{
        url = cfg.base_url .. "/v1/messages",
        method = "POST",
        headers = headers,
        source = ltn12.source.string(body_json),
        sink = ltn12.sink.table(sink),
    })
    socketutil:reset_timeout()

    if resp_headers == nil then
        return { ok = false, code = code, network_error = true }
    end
    return { ok = code == 200, code = code, body = table.concat(sink) }
end

return Anthropic
