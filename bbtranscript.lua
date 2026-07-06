-- Presentation of the human-readable transcript: the plain-text rendering of a
-- conversation's `transcript` entries (You:/BookBuddy:/thinking/tool lines), the
-- friendly per-tool action phrases, and the token-usage footer. Pure functions over
-- the entry tables the conversation owns -- no UI, no wire history, no streaming --
-- so the turn loop in bbconversation stays about orchestration, not formatting.
local _ = require("gettext")
local T = require("ffi/util").template

local Transcript = {}

-- The viewer is plain text, so drop the markdown markers the model emits rather
-- than show them literally. Applied on every render (streaming and final) so the
-- text reads the same throughout; safe on the partial markdown seen mid-stream.
-- We deliberately skip "_"/"__" emphasis: it collides with snake_case and URLs.
local function stripMarkdown(text)
    if not text or text == "" then
        return text
    end
    text = text:gsub("```[%w%-]*\n?", "") -- fenced code markers
    text = text:gsub("%*%*(.-)%*%*", "%1") -- **bold**
    text = text:gsub("%*(%S.-%S)%*", "%1") -- *italic* (multi-char)
    text = text:gsub("%*(%S)%*", "%1") -- *i* (single char)
    text = text:gsub("~~(.-)~~", "%1") -- ~~strike~~
    text = text:gsub("`(.-)`", "%1") -- `inline code`
    text = text:gsub("%[(.-)%]%((.-)%)", "%1 (%2)") -- [text](url) -> text (url)
    text = text:gsub("^#+%s*", "") -- heading on the first line
    text = text:gsub("(\n)#+%s*", "%1") -- headings on later lines
    return text
end

-- Per-entry memo for stripMarkdown: Transcript.text re-renders the whole
-- transcript on every ~2.5fps flush, but only the still-streaming entry's
-- .text changes. Cache the stripped text keyed on the entry's current .text;
-- the live entry (mutating .text) misses and re-strips, finalized entries hit.
-- renderAssistantTurn replaces live entries with fresh tables, so a stale
-- memo can never outlive its source.
local function strippedEntry(turn)
    if turn._md_src ~= turn.text then
        turn._md_src = turn.text
        turn._md_out = stripMarkdown(turn.text)
    end
    return turn._md_out
end

local function navigatePhrase(input)
    if input.back then
        return _("Went back")
    elseif input.page ~= nil then
        return T(_("Went to page %1"), tostring(input.page))
    elseif input.percent ~= nil then
        return T(_("Went to %1%"), tostring(input.percent))
    elseif input.chapter_index ~= nil then
        return T(_("Went to chapter %1"), tostring(input.chapter_index))
    end
    return _("Navigated the book")
end

-- "/memories/notes.md" -> "notes.md"; the /memories root -> nil (no useful name).
local function memoryNoteName(path)
    if type(path) ~= "string" then
        return nil
    end
    local name = path:gsub("^/memories/?", "")
    return name ~= "" and name or nil
end

local function memoryPhrase(input)
    local cmd = input.command
    local name = memoryNoteName(input.path)
    if cmd == "view" then
        if name then
            return T(_("Read memory note %1"), name)
        end
        return _("Reviewed saved memory")
    elseif cmd == "create" then
        return name and T(_("Saved memory note %1"), name) or _("Saved a memory note")
    elseif cmd == "str_replace" or cmd == "insert" then
        return name and T(_("Updated memory note %1"), name) or _("Updated a memory note")
    elseif cmd == "delete" then
        return name and T(_("Deleted memory note %1"), name) or _("Deleted a memory note")
    elseif cmd == "rename" then
        local from, to = memoryNoteName(input.old_path), memoryNoteName(input.new_path)
        if from and to then
            return T(_("Renamed memory note %1 to %2"), from, to)
        end
        return _("Renamed a memory note")
    end
    return _("Used memory")
end

-- A friendly, present-completed description of one tool call, e.g.
--   "  → Searched book for "whales"". The leading arrow/indent set tool lines
-- apart from the You:/BookBuddy: turns in the plain-text transcript. The outcome
-- summary (match count, word count, …) is appended by the caller once known.
function Transcript.toolActionPhrase(tu)
    local input = tu.input or {}
    local phrase
    if tu.name == "grep" then
        phrase = T(_("Searched book for %1"), string.format("%q", input.query or ""))
    elseif tu.name == "read" then
        phrase = T(_("Reading from %1"), (input.from and tostring(input.from)) or _("your current page"))
    elseif tu.name == "get_toc" then
        phrase = _("Fetched the table of contents")
    elseif tu.name == "book_context" then
        phrase = _("Checked the book details")
    elseif tu.name == "get_highlights" then
        phrase = _("Looked up your highlights")
    elseif tu.name == "edit_highlight_note" then
        phrase = T(_("Updated the note on highlight %1"), tostring(input.highlight_index))
    elseif tu.name == "create_highlight" then
        phrase = _("Created a highlight")
    elseif tu.name == "navigate" then
        phrase = navigatePhrase(input)
    elseif tu.name == "memory" then
        phrase = memoryPhrase(input)
    elseif tu.name == "delegate" then
        phrase = T(_("Researching: %1…"), input.task or "")
    elseif tu.name == "ask_user" then
        phrase = T(_("Asked: %1"), input.question or "")
    else
        phrase = T(_("Used %1"), tu.name)
    end
    return "  → " .. phrase
end

-- Re-render a turn's assistant content into the transcript in block order,
-- replacing the live streamed entries (everything past turn_start). This keeps a
-- server-side web search between the model's lead-in and its answer instead of
-- hoisting it above them, and renders interleaved thinking/text in reading order.
-- Web search runs server-side, so its query never reaches the client tool loop;
-- we surface it here, with the result count from the matching result block when it
-- is in this turn (after a pause_turn the result can be absent, so we show the
-- query alone).
function Transcript.renderAssistantTurn(transcript, content, turn_start, show_thinking)
    for i = #transcript, turn_start + 1, -1 do
        transcript[i] = nil
    end
    if type(content) ~= "table" then
        return
    end
    local outcome = {}
    for i = 1, #content do
        local b = content[i]
        if b.type == "web_search_tool_result" and b.tool_use_id then
            local c = b.content
            if type(c) == "table" and c.type == "web_search_tool_result_error" then
                outcome[b.tool_use_id] = { error = c.error_code }
            elseif type(c) == "table" then
                outcome[b.tool_use_id] = { count = #c }
            end
        end
    end
    for i = 1, #content do
        local b = content[i]
        if b.type == "thinking" and b.thinking and b.thinking ~= "" then
            transcript[#transcript + 1] = { role = "thinking", done = true, text = show_thinking and b.thinking or nil }
        elseif b.type == "text" and b.text and b.text ~= "" then
            transcript[#transcript + 1] = { role = "assistant", text = b.text }
        elseif b.type == "server_tool_use" and b.name == "web_search" then
            local query = (b.input and b.input.query) or ""
            local text = "  → " .. T(_("Searched the web for %1"), string.format("%q", query))
            local r = outcome[b.id]
            if r and r.error then
                text = text .. " — " .. T(_("error: %1"), tostring(r.error))
            elseif r and r.count then
                text = text .. " — " .. T(_("%1 result(s)"), r.count)
            end
            transcript[#transcript + 1] = { role = "tool", text = text }
        end
    end
end

-- Rule drawn wherever BookBuddy's prose borders the thinking/tool machinery, so
-- with streamed thinking on the reader can see at a glance where the actual
-- answer starts and ends. Rendered per call, never stored in transcript entries.
local RULE = string.rep("─", 24)

-- The full plain-text rendering the viewer shows. Transient status (activity,
-- elapsed, context occupancy) lives on the live status bar (bbstatusbar), NOT
-- here: this is the durable transcript, so it carries no token/context footer and
-- no "Thinking..." placeholder -- those would only double what the bar already shows.
function Transcript.text(transcript)
    local out = {}
    -- Fence answers off from machinery: emit RULE at every prose<->machinery
    -- boundary (assistant vs. visible thinking/tool). A plain You:/BookBuddy:
    -- exchange has no such boundary and renders without any rules. Tracked over
    -- *rendered* entries only, so hidden thinking (indicator-only, empty text)
    -- never conjures a fence.
    local prev_kind
    local function push(kind, text)
        if prev_kind and kind ~= prev_kind and kind ~= "user" and prev_kind ~= "user" then
            out[#out + 1] = RULE
        end
        prev_kind = kind
        out[#out + 1] = text
    end
    for i = 1, #transcript do
        local turn = transcript[i]
        if turn.role == "user" then
            push("user", T(_("You: %1"), turn.text))
        elseif turn.role == "assistant" then
            push("prose", T(_("BookBuddy: %1"), strippedEntry(turn)))
        elseif turn.role == "thinking" then
            -- Only surface reasoning the reader opted into streaming (show_streaming_thinking):
            -- the text itself is the content. An indicator-only entry (empty text) renders
            -- nothing -- the status bar's "thinking" activity is the sole progress signal.
            if turn.text and turn.text ~= "" then
                push("machinery", T(_("Thinking: %1"), turn.text))
            end
        else
            push("machinery", turn.text)
        end
    end
    return table.concat(out, "\n\n")
end

return Transcript
