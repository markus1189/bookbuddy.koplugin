-- Drives the multi-turn, tool-using exchange with Claude.
--
-- The whole loop runs inside Trapper:wrap so the spinner is dismissable. Each
-- Claude call is forked into a subprocess (network only); tool calls run here in
-- the main process because they touch the live document. We keep two parallel
-- structures: `messages` (the exact Anthropic wire format, resent every turn)
-- and `transcript` (a human-readable log rendered in the viewer).
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local NetworkMgr = require("ui/network/manager")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local Anthropic = require("bbanthropic")
local ChatViewer = require("bbchatviewer")
local Tools = require("bbtools")

local Conversation = {}
Conversation.__index = Conversation

function Conversation:new(o)
    o = o or {}
    setmetatable(o, self)
    o.messages = {}
    o.transcript = {}
    o.tool_specs = Tools.getSpecs()
    o.viewer = nil
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

    -- Show an error and dismiss the progress popup in one place.
    local function fail(text)
        Trapper:reset()
        UIManager:show(InfoMessage:new{ text = text })
    end

    local iterations = 0
    while iterations < max_turns do
        iterations = iterations + 1
        -- On the final allowed round, drop the tools so the model has to answer in
        -- text rather than requesting another tool call we'd refuse to run.
        local last_round = iterations >= max_turns
        local tools = (not last_round) and self.tool_specs or nil

        -- Progress feedback: Trapper:info shows/updates a single dismissable popup
        -- (it persists until replaced, so it reads as steady progress).
        Trapper:info(last_round and _("BookBuddy is writing the answer…")
            or T(_("BookBuddy is thinking… (step %1)"), iterations))

        local body = Anthropic.buildBody(self.messages, tools, cfg)
        -- `false` => invisible trap that catches a tap to cancel without stacking a
        -- second visible popup on top of the progress message.
        local completed, resp = Trapper:dismissableRunInSubprocess(function()
            return Anthropic.request(body, cfg)
        end, false)

        if not completed then
            fail(_("BookBuddy request cancelled."))
            return
        end
        if type(resp) ~= "table" then
            fail(_("BookBuddy: no response from the gateway."))
            return
        end
        if not resp.ok then
            Trapper:reset()
            self:_showError(resp)
            return
        end

        local data = Anthropic.decode(resp.body)
        if not data then
            fail(_("BookBuddy: could not parse the gateway response."))
            return
        end
        if data.error then
            local msg = data.error.message or data.error.type or "unknown error"
            fail(T(_("BookBuddy API error: %1"), tostring(msg)))
            return
        end

        self.messages[#self.messages + 1] = { role = "assistant", content = data.content }
        local text_parts, tool_uses = self:_split(data.content)
        if #text_parts > 0 then
            self.transcript[#self.transcript + 1] = {
                role = "assistant",
                text = table.concat(text_parts, "\n\n"),
            }
        end

        if data.stop_reason ~= "tool_use" or #tool_uses == 0 then
            Trapper:reset()
            self:_render()
            return
        end

        local tool_results = {}
        for i = 1, #tool_uses do
            local tu = tool_uses[i]
            self.transcript[#self.transcript + 1] = { role = "tool", text = self:_toolLabel(tu) }
            Trapper:info(self:_toolProgress(tu))
            local result = Tools.execute(tu.name, tu.input, self.ui)
            tool_results[#tool_results + 1] = {
                type = "tool_result",
                tool_use_id = tu.id,
                content = result,
            }
        end
        self.messages[#self.messages + 1] = { role = "user", content = tool_results }
    end

    -- Unreachable in practice: the final round omits tools and returns above.
    Trapper:reset()
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
    end
    if detail then
        return T(_("[used %1: %2]"), tu.name, detail)
    end
    return T(_("[used %1]"), tu.name)
end

-- Friendly present-tense progress text shown while a tool runs.
function Conversation:_toolProgress(tu)
    local input = tu.input or {}
    if tu.name == "search_book" then
        return T(_("Searching for %1…"), string.format("%q", tostring(input.query or "")))
    elseif tu.name == "read_page_range" then
        return T(_("Reading pages %1–%2…"), tostring(input.start_page), tostring(input.end_page))
    elseif tu.name == "read_chapter" then
        return T(_("Reading chapter %1…"), tostring(input.chapter_index))
    elseif tu.name == "get_toc" then
        return _("Reading the table of contents…")
    elseif tu.name == "book_context" then
        return _("Checking book details…")
    end
    return T(_("Running %1…"), tu.name)
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
    return table.concat(out, "\n\n")
end

function Conversation:_render()
    if self.viewer then
        UIManager:close(self.viewer)
        self.viewer = nil
    end
    self.viewer = ChatViewer.build{
        title = _("BookBuddy"),
        text = self:_transcriptText(),
        on_followup = function() self:_promptFollowup() end,
    }
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

function Conversation:_showError(resp)
    local msg
    if resp.network_error then
        msg = T(_("BookBuddy: network error contacting the gateway (%1)."), tostring(resp.code))
    else
        msg = T(_("BookBuddy: the gateway returned an error (HTTP %1)."), tostring(resp.code))
        local data = resp.body and Anthropic.decode(resp.body)
        if data and data.error and data.error.message then
            msg = msg .. "\n" .. tostring(data.error.message)
        end
    end
    UIManager:show(InfoMessage:new{ text = msg })
end

return Conversation
