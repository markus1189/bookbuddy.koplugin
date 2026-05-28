-- Drives the multi-turn, tool-using exchange with Claude.
--
-- The whole loop runs inside Trapper:wrap, which gives us a coroutine the
-- streaming transport can yield from (LuaJIT's main thread can't). Each Claude
-- call is streamed from a forked subprocess (network only) while the reply is
-- rendered live into the viewer; tool calls run here in the main process because
-- they touch the live document. We keep two parallel structures: `messages` (the
-- exact Anthropic wire format, resent every turn) and `transcript` (a
-- human-readable log rendered in the viewer).
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local NetworkMgr = require("ui/network/manager")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local Anthropic = require("bbanthropic")
local ChatViewer = require("bbchatviewer")
local Memory = require("bbmemory")
local Stream = require("bbstream")
local Tools = require("bbtools")

-- Repaint the live transcript at most this often while text streams in. The
-- transport wakes every 0.125s; coalescing to ~2.5 fps keeps e-ink usable.
local FLUSH_INTERVAL_SEC = 0.4

local Conversation = {}
Conversation.__index = Conversation

function Conversation:new(o)
    o = o or {}
    setmetatable(o, self)
    o.messages = {}
    o.transcript = {}
    o.tool_specs = Tools.getSpecs()
    -- When memory is enabled, build the per-book store once and offer the memory
    -- tool alongside the others. It rides in tool_specs, so the last_round rule
    -- that drops tools to force a text answer drops memory too. Skip it if the
    -- book has no resolvable sidecar dir to store memory in.
    o.memory = nil
    if o.ui and o.settings and o.settings:getConfig().enable_memory then
        local base = Memory.baseDirForBook(o.ui)
        if base then
            o.memory = Memory.new(base)
            o.tool_specs[#o.tool_specs + 1] = Memory.spec()
        end
    end
    o.viewer = nil
    o.streaming_viewer = false
    o._cancel = nil
    o._flush_task = nil
    -- Accumulated across every API call in the conversation (each turn resends the
    -- full history, so summing input_tokens reflects what was actually billed).
    o.usage = { input = 0, output = 0, cache_read = 0, cache_write = 0 }
    return o
end

function Conversation:ask(question)
    if #self.messages == 0 then
        local context = Tools.execute("book_context", {}, self.ui)
        local seed = T(
            "I'm reading this book:\n%1\n\nI've highlighted this passage:\n\"\"\"\n%2\n\"\"\"\n\nMy question: %3",
            context, self.selected_text or "", question)
        self.messages[#self.messages + 1] = { role = "user", content = seed }
    else
        self.messages[#self.messages + 1] = { role = "user", content = question }
    end
    self.transcript[#self.transcript + 1] = { role = "user", text = question }
    self:run()
end

function Conversation:run()
    if NetworkMgr:willRerunWhenOnline(function() self:run() end) then
        return
    end
    Trapper:wrap(function()
        self:_loop()
    end)
end

function Conversation:_loop()
    local cfg = self.settings:getConfig()
    local max_turns = cfg.max_turns

    local iterations = 0
    while iterations < max_turns do
        iterations = iterations + 1
        -- On the final allowed round, drop the tools so the model has to answer in
        -- text rather than requesting another tool call we'd refuse to run.
        local last_round = iterations >= max_turns
        local tools = (not last_round) and self.tool_specs or nil

        local body = Anthropic.buildBody(self.messages, tools, cfg)
        self:_ensureStreamingViewer()

        -- The assistant entry is created on the first text delta so a pure tool
        -- turn (no text) leaves no empty "BookBuddy:" line in the transcript.
        local entry
        local parser = Anthropic.newStreamParser{
            on_text = function(t)
                if not entry then
                    entry = { role = "assistant", text = "" }
                    self.transcript[#self.transcript + 1] = entry
                end
                entry.text = entry.text .. t
                self:_scheduleFlush()
            end,
        }

        local r = Stream.run{
            child_fn = Anthropic.streamChildFn(body, cfg),
            on_line = function(line) parser:feed(line) end,
            register_cancel = function(fn) self._cancel = fn end,
        }
        self:_cancelFlush()

        if r.cancelled then
            self:_closeViewer()
            UIManager:show(InfoMessage:new{ text = _("BookBuddy request cancelled.") })
            return
        end
        if r.read_error then
            self:_closeViewer()
            UIManager:show(InfoMessage:new{ text = _("BookBuddy: the streaming connection failed.") })
            return
        end

        local res = parser:result()
        if not res.ok then
            self:_closeViewer()
            self:_showError(res)
            return
        end

        local u = res.usage
        if u then
            self.usage.input = self.usage.input + (u.input_tokens or 0)
            self.usage.output = self.usage.output + (u.output_tokens or 0)
            self.usage.cache_read = self.usage.cache_read + (u.cache_read_input_tokens or 0)
            self.usage.cache_write = self.usage.cache_write + (u.cache_creation_input_tokens or 0)
        end

        self.messages[#self.messages + 1] = { role = "assistant", content = res.content }
        local text_parts, tool_uses = self:_split(res.content)
        if #text_parts > 0 then
            if not entry then
                entry = { role = "assistant", text = "" }
                self.transcript[#self.transcript + 1] = entry
            end
            -- Canonical text (handles multiple text blocks the deltas glued together).
            entry.text = table.concat(text_parts, "\n\n")
        elseif entry and self.transcript[#self.transcript] == entry then
            self.transcript[#self.transcript] = nil
        end

        if res.stop_reason ~= "tool_use" or #tool_uses == 0 then
            self:_render()
            return
        end

        self:_flushNow()
        local tool_results = {}
        for i = 1, #tool_uses do
            local tu = tool_uses[i]
            self.transcript[#self.transcript + 1] = { role = "tool", text = self:_toolLabel(tu) }
            self:_flushNow()
            local result
            if tu.name == "memory" and self.memory then
                result = self.memory:execute(tu.input)
            else
                result = Tools.execute(tu.name, tu.input, self.ui)
            end
            tool_results[#tool_results + 1] = {
                type = "tool_result",
                tool_use_id = tu.id,
                content = result,
            }
        end
        self.messages[#self.messages + 1] = { role = "user", content = tool_results }
    end

    -- Unreachable in practice: the final round omits tools and returns above.
    self:_render()
end

function Conversation:_split(content)
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

function Conversation:_toolLabel(tu)
    local input = tu.input or {}
    local detail
    if tu.name == "search_book" then
        detail = string.format("%q", input.query or "")
    elseif tu.name == "read_page_range" then
        detail = T(_("pages %1–%2"), tostring(input.start_page), tostring(input.end_page))
    elseif tu.name == "read_chapter" then
        detail = T(_("chapter %1"), tostring(input.chapter_index))
    elseif tu.name == "memory" then
        local path = input.path or input.old_path
        detail = path and (tostring(input.command) .. " " .. tostring(path)) or tostring(input.command)
    end
    if detail then
        return T(_("[used %1: %2]"), tu.name, detail)
    end
    return T(_("[used %1]"), tu.name)
end

function Conversation:_transcriptText()
    local out = {}
    for i = 1, #self.transcript do
        local turn = self.transcript[i]
        if turn.role == "user" then
            out[#out + 1] = T(_("You: %1"), turn.text)
        elseif turn.role == "assistant" then
            out[#out + 1] = T(_("BookBuddy: %1"), turn.text)
        else
            out[#out + 1] = turn.text
        end
    end
    local usage = self:_usageText()
    if usage then
        out[#out + 1] = usage
    end
    return table.concat(out, "\n\n")
end

-- Footer summarizing token spend across the whole conversation. nil until at
-- least one API call has reported usage. cache_read/cache_write are the prompt
-- tokens served from / written to the prompt cache (Anthropic reports them
-- separately from input_tokens).
function Conversation:_usageText()
    local u = self.usage
    if u.input + u.output == 0 then
        return nil
    end
    local parts = { T(_("input %1"), u.input), T(_("output %1"), u.output) }
    local cached = u.cache_read + u.cache_write
    if cached > 0 then
        parts[#parts + 1] = T(_("cached %1"), cached)
    end
    return T(_("[tokens — %1]"), table.concat(parts, ", "))
end

-- Show (or re-show) the viewer in streaming mode, i.e. with a Stop button. A
-- follow-up reuses the finished viewer, which is in Ask-follow-up mode, so we
-- rebuild it here; mid-conversation turns keep the same streaming viewer.
function Conversation:_ensureStreamingViewer()
    if self.viewer and self.streaming_viewer then
        return
    end
    if self.viewer then
        UIManager:close(self.viewer)
        self.viewer = nil
    end
    self.viewer = ChatViewer.build{
        title = _("BookBuddy"),
        text = self:_transcriptText(),
        on_stop = function()
            if self._cancel then self._cancel() end
        end,
        scroll_to_bottom = true,
    }
    self.streaming_viewer = true
    UIManager:show(self.viewer)
end

function Conversation:_closeViewer()
    self:_cancelFlush()
    if self.viewer then
        UIManager:close(self.viewer)
        self.viewer = nil
    end
    self.streaming_viewer = false
end

-- Throttled live update: at most one repaint per FLUSH_INTERVAL_SEC.
function Conversation:_scheduleFlush()
    if self._flush_task then
        return
    end
    self._flush_task = function()
        self._flush_task = nil
        self:_flushNow()
    end
    UIManager:scheduleIn(FLUSH_INTERVAL_SEC, self._flush_task)
end

function Conversation:_cancelFlush()
    if self._flush_task then
        UIManager:unschedule(self._flush_task)
        self._flush_task = nil
    end
end

function Conversation:_flushNow()
    if self.viewer then
        ChatViewer.updateText(self.viewer, self:_transcriptText(), true)
    end
end

function Conversation:_render()
    self:_cancelFlush()
    if self.viewer then
        UIManager:close(self.viewer)
        self.viewer = nil
    end
    self.viewer = ChatViewer.build{
        title = _("BookBuddy"),
        text = self:_transcriptText(),
        on_followup = function() self:_promptFollowup() end,
        scroll_to_bottom = true,
    }
    self.streaming_viewer = false
    UIManager:show(self.viewer)
end

function Conversation:_promptFollowup()
    local dialog
    dialog = InputDialog:new{
        title = _("Ask a follow-up"),
        input = "",
        input_hint = _("Type your follow-up question"),
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Ask"),
                is_enter_default = true,
                callback = function()
                    local q = dialog:getInputText()
                    UIManager:close(dialog)
                    if q and q ~= "" then
                        self:ask(q)
                    end
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Conversation:_showError(res)
    local msg
    if res.network_error then
        msg = T(_("BookBuddy: network error contacting the gateway (%1)."), tostring(res.code))
    elseif res.code then
        msg = T(_("BookBuddy: the gateway returned an error (HTTP %1)."), tostring(res.code))
        if res.error_message then
            msg = msg .. "\n" .. tostring(res.error_message)
        end
    else
        msg = T(_("BookBuddy API error: %1"), tostring(res.error_message or _("unknown error")))
    end
    UIManager:show(InfoMessage:new{ text = msg })
end

return Conversation
