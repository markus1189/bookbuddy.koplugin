-- Invariants over the Anthropic wire history (the `messages` array resent on every
-- call). Everything here exists to keep that history RESENDABLE: the gateway 400s a
-- request whose roles don't alternate, whose client tool_use has no tool_result in
-- the following user message, or (on Vertex) whose server_tool_use lacks a paired
-- web_search_tool_result in the same assistant message. Both history owners -- the
-- parent conversation and the subagent driver's private child history -- share these
-- helpers, so the rules live in one place and are never re-derived per caller.
--
-- Pure data-structure work only: no UI, no transcript, no streaming. The functions
-- mutate the messages/content tables they are given (the callers own them).
local History = {}

-- Vertex AI's request validator (unlike Anthropic's first-party API) rejects any
-- server_tool_use that lacks a paired web_search_tool_result in the same assistant
-- message. A pause_turn can stop right after the in-flight web search's
-- server_tool_use, before its result arrives, so resending that turn verbatim --
-- which the pause_turn contract otherwise prescribes -- makes the next request 400
-- ("web_search tool use ... without a corresponding web_search_tool_result block").
-- Pair each orphan with a synthetic "unavailable" error result so the resend
-- validates; the model then resumes and either retries the search (a fresh turn
-- has a fresh search budget) or answers without it.
function History.pairDanglingWebSearch(content)
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

-- Pull an assistant turn's text and client tool_use blocks apart. Server-side
-- blocks (server_tool_use, web_search_tool_result, thinking) are neither: they stay
-- in the stored content but never reach the client tool loop.
function History.split(content)
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

-- Record an assistant reply in the wire history. A pause_turn continuation
-- (is_resume) extends the existing assistant turn instead of adding a second
-- assistant message in a row: a paused-then-resumed turn is one logical turn, and
-- two consecutive assistant messages make the gateway 400 ("roles must alternate")
-- once a later user turn resends the pair. Merging also keeps each server_tool_use
-- in the same message as its web_search_tool_result.
function History.storeAssistant(messages, blocks, is_resume)
    local prev = messages[#messages]
    if is_resume and prev and prev.role == "assistant" and type(prev.content) == "table" then
        for i = 1, #blocks do
            prev.content[#prev.content + 1] = blocks[i]
        end
    else
        messages[#messages + 1] = { role = "assistant", content = blocks }
    end
end

-- After an error/cancel exit, the turn loop has appended a user (seed or
-- tool_result) turn but never stored the assistant reply for it, so history ends on
-- a dangling, unanswered user turn. The next ask() would then append a *second*
-- user message and the gateway 400s ("roles must alternate"); dropping only the
-- trailing user would instead expose an unanswered client tool_use (also a
-- 400). Walk back over the whole in-flight tool round to the last clean
-- assistant turn (or empty history, which lets ask() re-seed) so the stored
-- history is always resendable before the next ask(). This makes explicit the
-- "history ends with an assistant reply" invariant that was, until now, only
-- upheld by the error path closing the viewer.
function History.dropDanglingTail(messages)
    local m = messages
    while #m > 0 do
        local last = m[#m]
        local dangling = (last.role == "user")
        if last.role == "assistant" and type(last.content) == "table" then
            -- Which web searches already have their result in THIS message; an
            -- orphan server_tool_use (paired result missing) makes the resend 400 on
            -- Vertex just like an unanswered client tool_use, so it is dangling too.
            -- This self-heals orphans persisted by older sessions whose check only
            -- matched type=="tool_use" (server_tool_use predates the pairing fix).
            local has_result = {}
            for _, b in ipairs(last.content) do
                if b.type == "web_search_tool_result" and b.tool_use_id then
                    has_result[b.tool_use_id] = true
                end
            end
            for _, b in ipairs(last.content) do
                if b.type == "tool_use" then
                    dangling = true
                    break
                end
                if b.type == "server_tool_use" and b.id and not has_result[b.id] then
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

return History
