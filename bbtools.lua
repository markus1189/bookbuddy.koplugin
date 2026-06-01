-- Tool specs (Anthropic input_schema) and their executors. Executors run in the
-- main process and call straight into KOReader's document API. They never run in
-- the network subprocess. Every executor returns a plain string for tool_result.

local Event = require("ui/event")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

local Tools = {}

local MAX_RESULT_CHARS = 6000
local DEFAULT_SEARCH_RESULTS = 8
local MAX_SEARCH_RESULTS = 20
local FINDALL_CONTEXT_WORDS = 10
local FINDALL_MAX_HITS = 5000
local DEFAULT_HIGHLIGHTS = 100
local MAX_HIGHLIGHTS = 500

local function truncate(text, limit)
    limit = limit or MAX_RESULT_CHARS
    if #text > limit then
        return text:sub(1, limit) .. "\n…[truncated]"
    end
    return text
end

local function wordCount(text)
    if not text or text == "" then
        return 0
    end
    local _, n = text:gsub("%S+", "")
    return n
end

local function isRolling(ui)
    return ui.rolling ~= nil
end

-- Standard guard for tools that only work on reflowable (EPUB) documents.
-- Returns (error_string, summary) when the document is paging (PDF/DjVu), or
-- nil when it is rolling and the tool may proceed.
local function rollingOnly(ui, tool_name)
    if isRolling(ui) then
        return nil
    end
    return string.format("%s is only supported for reflowable (EPUB) books in this version.", tool_name), _("EPUB only")
end

-- True when v is a whole number >= 1 -- the shape every 1-based index input must
-- have. v is already the result of tonumber() (so a number or nil); per-tool
-- upper bounds and error wording stay with the caller.
local function isPositiveInteger(v)
    return v ~= nil and v >= 1 and v == math.floor(v)
end

local function currentPage(ui)
    if isRolling(ui) then
        return ui.document:getCurrentPage()
    end
    return ui.view and ui.view.state and ui.view.state.page
end

local function currentChapter(ui)
    if not ui.toc then
        return nil
    end
    local ok, title = pcall(function()
        return ui.toc:getTocTitleOfCurrentPage()
    end)
    if ok and title and title ~= "" then
        return title
    end
    return nil
end

-- Plain-English "page N (Chapter)" for the model-facing tool_result. With no
-- page argument it reports the reader's current page/chapter; with a page it
-- labels that page, naming its chapter via the TOC when available.
local function locationLabel(ui, page)
    local chapter
    if page == nil then
        page = currentPage(ui)
        chapter = currentChapter(ui)
    elseif ui.toc then
        local ok, title = pcall(function()
            return ui.toc:getTocTitleByPage(page)
        end)
        if ok and title and title ~= "" then
            chapter = title
        end
    end
    local page_s = tostring(page or "?")
    if chapter then
        return string.format("page %s (%s)", page_s, chapter)
    end
    return "page " .. page_s
end

local function pageOfResult(ui, item)
    if isRolling(ui) then
        return ui.document:getPageFromXPointer(item.start)
    end
    return item.start
end

-- Per-conversation locator table. Maps an opaque "loc:<n>" token to a stored
-- position so the model never handles raw xpointers (which it mangles). Lives on
-- the shared ui; Conversation:new resets it so it does not leak across chats.
-- An entry is { kind = "point"|"span", xp = <start xpointer>, xp_end = <optional> }.
local function ensureLocators(ui)
    ui._bookbuddy_locators = ui._bookbuddy_locators or {}
    ui._bookbuddy_loc_seq = ui._bookbuddy_loc_seq or 0
    return ui._bookbuddy_locators
end

-- Store one position and return its opaque token. Monotonic within a conversation.
local function mintLocator(ui, entry)
    local locators = ensureLocators(ui)
    ui._bookbuddy_loc_seq = ui._bookbuddy_loc_seq + 1
    local n = ui._bookbuddy_loc_seq
    locators[n] = entry
    return "loc:" .. n
end

-- The integer n from a "loc:<n>" token, or nil if the string is not a locator.
local function parseLocToken(tok)
    if type(tok) ~= "string" then
        return nil
    end
    local n = tok:match("^loc:(%d+)$")
    return n and tonumber(n) or nil
end

-- Case-insensitive full-text search over the whole book. With regex=true the
-- query is treated as a pattern (findAllText's 5th arg, credocument.lua:1442);
-- otherwise it is a literal substring. Each result item carries item.start /
-- item["end"] -- the xpointers (rolling) or page positions (paging) spanning the
-- match -- which is exactly what create_highlight needs, so both tools go through
-- this one call.
local function findPassageMatches(ui, query, regex)
    return ui.document:findAllText(query, true, FINDALL_CONTEXT_WORDS, FINDALL_MAX_HITS, regex and true or false)
end

-- The short word-window snippet around a hit (the "words" context mode): the
-- engine's prev/matched/next text joined and whitespace-collapsed.
local function snippetWindow(item)
    local snippet = table.concat({
        item.prev_text or "",
        item.matched_word_prefix or "",
        item.matched_text or "",
        item.matched_word_suffix or "",
        item.next_text or "",
    })
    return (snippet:gsub("%s+", " "))
end

-- Anchor a hit to its enclosing sentence for the minted span locator. Returns
-- xp0, xp1, sentence_text. extendXPointersToSentenceSegment (credocument.lua:982)
-- returns a SINGLE table { text, pos0, pos1 } or nil; on nil we fall back to the
-- raw hit start/end span and no sentence text.
local function sentenceSpan(ui, item)
    local xp0, xp1, sent = item.start, item["end"], nil
    if ui.document and ui.document.extendXPointersToSentenceSegment then
        local ok, seg = pcall(function()
            return ui.document:extendXPointersToSentenceSegment(item.start, item["end"])
        end)
        if ok and type(seg) == "table" and seg.pos0 and seg.pos1 then
            xp0, xp1, sent = seg.pos0, seg.pos1, seg.text
        end
    end
    return xp0, xp1, sent
end

-- Search the current book (like Grep). By default only hits at or before the
-- reader's current page are shown (spoiler-safe); later hits are counted but never
-- revealed (no page, no text). spoiler=true reveals all; max_page only tightens the
-- cap to an earlier page. Each visible hit mints a sentence-anchored span locator
-- the model can pass to read or create_highlight.
local function tool_grep(ui, input)
    local query = input.query
    if not query or query == "" then
        return "Error: 'query' is required."
    end
    local regex = input.regex == true
    local context = input.context == "sentence" and "sentence" or "words"
    local spoiler = input.spoiler == true
    local max_results = math.min(tonumber(input.max_results) or DEFAULT_SEARCH_RESULTS, MAX_SEARCH_RESULTS)

    local results = findPassageMatches(ui, query, regex)
    if not results or #results == 0 then
        return string.format("No matches found for %q.", query), _("no matches")
    end

    -- Page cap: default to the reader's current page (spoiler-safe). max_page only
    -- tightens it to an earlier page; it can never widen past the current page
    -- unless spoiler=true (which removes the cap entirely).
    local cur = currentPage(ui)
    local cap = nil
    if not spoiler then
        cap = cur
        local mp = tonumber(input.max_page)
        if cap and mp and mp < cap then
            cap = mp
        end
    end

    -- Partition hits into visible / hidden by page vs cap. A nil page is treated as
    -- visible (we can't prove it's a spoiler).
    local visible, hidden = {}, 0
    for i = 1, #results do
        local item = results[i]
        local page = pageOfResult(ui, item)
        if cap ~= nil and page ~= nil and tonumber(page) and tonumber(page) > cap then
            hidden = hidden + 1
        else
            item._page = page
            visible[#visible + 1] = item
        end
    end

    -- Build the shown lines. shown[i] stays lock-step with the printed index AND the
    -- minted loc token, so create_highlight{search_result=i} and the loc:N agree.
    local shown, out = {}, {}
    local limit = math.min(#visible, max_results)
    for i = 1, limit do
        local item = visible[i]
        shown[i] = item
        local xp0, xp1, sent = sentenceSpan(ui, item)
        local tok = mintLocator(ui, { kind = "span", xp = xp0, xp_end = xp1 })
        local snippet
        if context == "sentence" and sent then
            snippet = (sent:gsub("%s+", " "))
        else
            snippet = snippetWindow(item)
        end
        out[#out + 1] = string.format("%d. [page %s] (%s) …%s…", i, tostring(item._page), tok, snippet)
    end
    ui._bookbuddy_last_search = { query = query, items = shown }

    if #shown == 0 then
        if hidden > 0 and not spoiler then
            return T(_("%1 match(es) hidden past your current page; pass spoiler=true to see them."), tostring(hidden)),
                _("all hidden")
        end
        return string.format("No matches found for %q.", query), _("no matches")
    end

    local header = string.format("Found %d match(es) for %q (showing up to %d):", #shown, query, max_results)
    table.insert(out, 1, header)
    if hidden > 0 and not spoiler then
        out[#out + 1] =
            T(_("%1 match(es) hidden past your current page; pass spoiler=true to see them."), tostring(hidden))
    end
    return truncate(table.concat(out, "\n")), T(_("%1 match(es)"), #shown)
end

local function tool_get_toc(ui, _input)
    local toc = ui.document:getToc()
    if not toc or #toc == 0 then
        return "This book has no table of contents.", _("none")
    end
    local out = { string.format("Table of contents (%d entries):", #toc) }
    local limit = math.min(#toc, 300)
    for i = 1, limit do
        local item = toc[i]
        local indent = string.rep("  ", math.max(0, (item.depth or 1) - 1))
        -- Mint a point locator at the chapter's start xpointer so the model can
        -- read({from = loc}) to begin reading at that chapter. Only when the entry
        -- carries an xpointer (CRE/EPUB TOC entries do): read resolves a loc: only
        -- through a stored xpointer, so for paging docs / xpointer-less entries we
        -- omit the token rather than mint one read could not honor.
        if type(item.xpointer) == "string" and item.xpointer ~= "" then
            local tok = mintLocator(ui, { kind = "point", xp = item.xpointer })
            out[#out + 1] =
                string.format("%d. %s%s (page %s) (%s)", i, indent, item.title or "", tostring(item.page or "?"), tok)
        else
            out[#out + 1] = string.format("%d. %s%s (page %s)", i, indent, item.title or "", tostring(item.page or "?"))
        end
    end
    if #toc > limit then
        out[#out + 1] = string.format("…and %d more entries.", #toc - limit)
    end
    return truncate(table.concat(out, "\n")), T(_("%1 entries"), #toc)
end

local DEFAULT_READ_LIMIT = 1500
local MAX_READ_LIMIT = 4000

-- Read the book's prose forward from a position, bounded to ~limit chars and
-- snapped to a word boundary, returning the chunk plus a continuation locator.
-- Reflowable (EPUB) only: it steps word-by-word through crengine's xpointer API.
-- `from` is polymorphic: a "loc:<n>" token, a bare page number string, or omitted
-- (the reader's current page). A page-level spoiler gate refuses a start past the
-- reader's current page and clamps a forward chunk that would cross into the next
-- page, unless spoiler=true.
local function tool_read(ui, input)
    input = input or {}
    local doc = ui.document
    if not doc then
        return _("No book is currently open.")
    end
    -- Reflowable-only guard: a paging doc (has_pages) or a doc missing the cre
    -- xpointer stepping API can't drive the forward advance loop.
    if
        (doc.info and doc.info.has_pages)
        or not doc.getNextVisibleWordEnd
        or not doc.compareXPointers
        or not doc.getTextFromXPointers
        or not doc.getPageXPointer
    then
        return _("read works only on reflowable (EPUB) books.")
    end

    local from = input.from
    if from == "" then
        from = nil
    end
    local spoiler = input.spoiler == true

    -- Resolve the start xpointer and its page.
    local xp_start, start_page, prefix
    if from == nil then
        start_page = currentPage(ui)
        xp_start = doc:getPageXPointer(start_page)
    else
        local n = parseLocToken(from)
        if n ~= nil then
            local entry = ensureLocators(ui)[n]
            if not entry then
                return _("That locator is stale; search again or give a page.")
            end
            local xp = entry.xp
            -- Re-validate against the live document: a font/DOM change can move an
            -- xpointer out of the document. Degrade to that page's start rather than
            -- erroring, and tell the model why its place shifted.
            if doc.isXPointerInDocument and not doc:isXPointerInDocument(xp) then
                local pg = doc:getPageFromXPointer(xp)
                pg = pg or currentPage(ui)
                xp_start = doc:getPageXPointer(pg)
                start_page = pg
                prefix = T(_("(Your place shifted because the layout changed; resuming from page %1.)"), tostring(pg))
                    .. "\n\n"
            else
                xp_start = xp
            end
        elseif tonumber(from) ~= nil then
            local pg = math.max(1, math.min(tonumber(from), doc:getPageCount() or tonumber(from)))
            xp_start = doc:getPageXPointer(pg)
            start_page = pg
        else
            return _("That locator is stale; search again or give a page.")
        end
    end
    start_page = start_page or doc:getPageFromXPointer(xp_start)

    -- Page-level spoiler gate (skipped when spoiler=true).
    local cur = currentPage(ui)
    local limit_xp
    if not spoiler then
        if start_page and cur and start_page > cur then
            -- Start is ahead of the reader: refuse outright, no text, no next.
            return T(
                _(
                    "That's past where you are in the book (page %1 of your current page %2). "
                        .. "I won't read ahead and risk spoiling it — call read again with spoiler=true "
                        .. "if you really want to."
                ),
                tostring(start_page),
                tostring(cur)
            )
        end
        if cur then
            -- Clamp the forward chunk at the start of the next page.
            limit_xp = doc:getPageXPointer(cur + 1)
        end
    end

    local budget = tonumber(input.limit) or DEFAULT_READ_LIMIT
    budget = math.max(1, math.min(budget, MAX_READ_LIMIT))

    -- Advance forward from xp_start until ~budget chars, snapping to a word
    -- boundary. compareXPointers is the oracle: 1 means the second arg is after
    -- the first. Track which stop condition fired so the trailer is exact.
    local xp_end, eob, clamped = xp_start, false, false
    while true do
        -- Spoiler clamp oracle: once xp_end reaches the start of the next page
        -- (limit_xp), compareXPointers(xp_end, limit_xp) is 0 (equal) or -1 (past),
        -- i.e. ~= 1, so stop. Skipped (limit_xp nil) when spoiler=true.
        if limit_xp and doc:compareXPointers(xp_end, limit_xp) ~= 1 then
            clamped = true
            break
        end
        local nxt = doc:getNextVisibleWordEnd(xp_end)
        if not nxt then
            eob = true
            break
        end
        if doc:compareXPointers(xp_end, nxt) ~= 1 then
            break -- no forward progress
        end
        if #(doc:getTextFromXPointers(xp_start, nxt) or "") > budget then
            break -- budget reached
        end
        xp_end = nxt
    end
    -- Forced progress: a single word longer than budget, or an absurdly low limit,
    -- must still advance the cursor so the model's continue-loop terminates.
    if doc:compareXPointers(xp_start, xp_end) ~= 1 and not eob and not clamped then
        if doc.getNextVisibleChar then
            local nxt = doc:getNextVisibleChar(xp_end)
            if nxt then
                xp_end = nxt
            end
        end
    end

    local text = doc:getTextFromXPointers(xp_start, xp_end) or ""
    if text == "" and eob then
        return _("Nothing further to read — you're at the end of the book.")
    end

    local header = T(_("[%1] reading forward:"), locationLabel(ui, start_page))

    local trailer
    if eob then
        trailer = _("(End of book reached.)")
    elseif clamped then
        trailer = _("(Stopped at your current page to avoid spoilers. Pass spoiler=true to keep reading.)")
    else
        local nexttok = mintLocator(ui, { kind = "point", xp = xp_end })
        trailer = T(_("(More follows — read again with from: %1.)"), nexttok)
    end

    return truncate((prefix or "") .. header .. "\n\n" .. text .. "\n\n" .. trailer), T(_("~%1 words"), wordCount(text))
end

local function tool_book_context(ui, _input)
    local props = ui.document:getProps() or {}
    local lines = {
        "Title: " .. (props.title or "(unknown)"),
        "Author: " .. (props.authors or "(unknown)"),
    }
    if props.series then
        lines[#lines + 1] = "Series: " .. props.series
    end
    local cur = tostring(currentPage(ui) or "?")
    local total = tostring(ui.document:getPageCount() or "?")
    lines[#lines + 1] = string.format("Current page: %s of %s", cur, total)
    if ui.toc then
        local ok, title = pcall(function()
            return ui.toc:getTocTitleOfCurrentPage()
        end)
        if ok and title and title ~= "" then
            lines[#lines + 1] = "Current chapter: " .. title
        end
    end
    return table.concat(lines, "\n"), T(_("page %1 of %2"), cur, total)
end

-- The reader's annotations that carry a highlighted passage or a note, in the
-- order KOReader stores them (reading order), skipping bare page bookmarks.
-- This is the single source of the 1-based numbering shared by get_highlights
-- (which lists them) and edit_highlight_note (which addresses them by number);
-- the array index here is NOT the index into ui.annotation.annotations, which
-- also holds bare bookmarks.
local function highlightList(ui)
    local items = ui.annotation and ui.annotation.annotations
    local list = {}
    if items then
        for i = 1, #items do
            local a = items[i]
            local has_text = a.text and a.text ~= ""
            local has_note = a.note and a.note ~= ""
            if has_text or has_note then
                list[#list + 1] = a
            end
        end
    end
    return list
end

-- Location label for a highlight, e.g. "page 42, Chapter 2".
local function highlightLocation(a)
    local loc = a.pageno and ("page " .. tostring(a.pageno)) or "page ?"
    if a.chapter and a.chapter ~= "" then
        loc = loc .. ", " .. a.chapter
    end
    return loc
end

local function tool_get_highlights(ui, input)
    local list = highlightList(ui)
    local total = #list
    if total == 0 then
        return "This book has no highlights or notes yet.", _("none yet")
    end
    local max_results = math.min(tonumber(input.max_results) or DEFAULT_HIGHLIGHTS, MAX_HIGHLIGHTS)
    local out, shown = {}, 0
    for i = 1, total do
        if shown >= max_results then
            break
        end
        shown = shown + 1
        local a = list[i]
        local text = a.text and a.text ~= "" and a.text:gsub("%s+", " ") or nil
        local note = a.note and a.note ~= "" and a.note:gsub("%s+", " ") or nil
        local entry = string.format("%d. [%s | %s]", i, note and "note" or "highlight", highlightLocation(a))
        if text then
            entry = entry .. '\n   "' .. text .. '"'
        end
        if note then
            entry = entry .. "\n   note: " .. note
        end
        out[#out + 1] = entry
    end
    local header = string.format(
        "%d highlight(s)/note(s) in this book%s:",
        total,
        shown < total and string.format(" (showing first %d)", shown) or ""
    )
    return truncate(header .. "\n" .. table.concat(out, "\n")), T(_("%1 found"), total)
end

-- Move the reader within the book. Mirrors KOReader's own jump idiom
-- (readertoc.lua:984-990): push the current spot onto ReaderLink's location
-- stack first, so the reader's Back gesture and the menu's forward arrow return
-- here -- then fire the navigation event. The result reports where the reader
-- was so the model can narrate it. Non-destructive, so no confirmation.
local function tool_navigate(ui, input)
    local targets = {}
    if input.page ~= nil then
        targets[#targets + 1] = "page"
    end
    if input.percent ~= nil then
        targets[#targets + 1] = "percent"
    end
    if input.chapter_index ~= nil then
        targets[#targets + 1] = "chapter_index"
    end
    if input.back then
        targets[#targets + 1] = "back"
    end
    if #targets == 0 then
        return "Error: provide exactly one of page, percent, chapter_index, or back."
    end
    if #targets > 1 then
        return "Error: provide only one of page, percent, chapter_index, or back (got "
            .. table.concat(targets, ", ")
            .. ")."
    end
    if not ui.link then
        return "Error: navigation is unavailable for this document."
    end

    if input.back then
        -- ReaderLink itself gates its Back menu item on a non-empty stack
        -- (readerlink.lua:474); do the same check so we can answer gracefully
        -- instead of triggering an empty-history notification.
        local stack = ui.link.location_stack
        if type(stack) == "table" and #stack == 0 then
            return "There is no previous location to go back to.", _("nothing to go back to")
        end
        local from = locationLabel(ui)
        ui.link:onGoBackLink()
        return string.format("Went back from %s to %s.", from, locationLabel(ui)), _("went back")
    end

    local from = locationLabel(ui)

    if input.page ~= nil then
        local page = tonumber(input.page)
        if not page then
            return "Error: 'page' must be a number."
        end
        local count = ui.document:getPageCount() or page
        page = math.max(1, math.min(math.floor(page), count))
        ui.link:addCurrentLocationToStack()
        ui:handleEvent(Event:new("GotoPage", page))
    elseif input.percent ~= nil then
        local percent = tonumber(input.percent)
        if not percent then
            return "Error: 'percent' must be a number between 0 and 100."
        end
        percent = math.max(0, math.min(percent, 100))
        ui.link:addCurrentLocationToStack()
        ui:handleEvent(Event:new("GotoPercent", percent))
    else -- chapter_index
        local toc = ui.document:getToc()
        if not toc or #toc == 0 then
            return "This book has no table of contents to navigate by chapter."
        end
        local idx = tonumber(input.chapter_index)
        if not idx or idx < 1 or idx > #toc then
            return string.format("Error: 'chapter_index' must be between 1 and %d (see get_toc).", #toc)
        end
        local entry = toc[idx]
        ui.link:addCurrentLocationToStack()
        if entry.xpointer then
            ui:handleEvent(Event:new("GotoXPointer", entry.xpointer, entry.xpointer))
        else
            ui:handleEvent(Event:new("GotoPage", entry.page))
        end
    end

    local to = locationLabel(ui)
    return string.format("Moved from %s to %s. The reader can tap Back to return here.", from, to), T(_("→ %1"), to)
end

-- Add to (never overwrite) the note on one of the reader's highlights. The
-- highlight is addressed by its number from get_highlights, so both tools share
-- highlightList()'s numbering. Strictly non-destructive: a note-less highlight
-- gets the note set; a highlight that already has a note gets the text appended
-- below it (KOReader joins notes with a blank line, readerbookmark.lua:1376). It
-- never deletes or replaces existing note text, so -- like navigate -- no
-- confirmation is needed. Mirrors ReaderBookmark:setBookmarkNote for persistence:
-- the in-place mutation is saved by ReaderAnnotation:onSaveSettings on close, and
-- the AnnotationsModified event keeps the footer's counters and the
-- datetime_updated timestamp honest.
local function tool_edit_highlight_note(ui, input)
    local list = highlightList(ui)
    if #list == 0 then
        return "Error: this book has no highlights or notes to edit."
    end
    local idx = tonumber(input.highlight_index)
    if not isPositiveInteger(idx) or idx > #list then
        return string.format(
            "Error: 'highlight_index' must be a whole number between 1 and %d (see get_highlights).",
            #list
        )
    end
    local note = input.note
    if type(note) ~= "string" or note:gsub("%s", "") == "" then
        return "Error: 'note' text is required."
    end

    local a = list[idx]
    local had_note = a.note and a.note ~= ""
    local new_note = had_note and (a.note .. "\n\n" .. note) or note

    -- No-op for non-PDF documents (readerhighlight.lua:2151 self-guards), but
    -- keeps note content in sync for PDFs with write-into-pdf enabled.
    if ui.highlight then
        ui.highlight:writePdfAnnotation("content", a, new_note)
    end
    a.note = new_note

    if ui.handleEvent then
        if had_note then
            ui:handleEvent(Event:new("AnnotationsModified", { a, modify_datetime = true }))
        else -- a bare highlight became a note: keep the highlight/note counters right
            ui:handleEvent(Event:new("AnnotationsModified", { a, nb_highlights_added = -1, nb_notes_added = 1 }))
        end
    end

    local verb = had_note and "Appended to" or "Added"
    return string.format(
        "%s the note on highlight %d (%s). The note now reads:\n%s",
        verb,
        idx,
        highlightLocation(a),
        new_note
    ),
        had_note and _("appended note") or _("added note")
end

-- Valid highlight styles and colors, mirroring ReaderHighlight's own lists
-- (readerhighlight.lua: highlight drawer styles and highlight_colors). These
-- ordered lists are the single source of truth: they feed the lookup sets that
-- validate input, the tool spec's enum, and the error messages. Both are
-- optional on create_highlight; omitting them falls back to the book's saved style.
local DRAWER_LIST = { "lighten", "underscore", "strikeout", "invert" }
local COLOR_LIST = { "red", "orange", "yellow", "green", "olive", "cyan", "blue", "purple", "gray" }
local function toSet(list)
    local set = {}
    for i = 1, #list do
        set[list[i]] = true
    end
    return set
end
local DRAWERS = toSet(DRAWER_LIST)
local COLORS = toSet(COLOR_LIST)

-- Build and persist a highlight from a pos0/pos1 pair, mirroring
-- ReaderHighlight:saveHighlight (readerhighlight.lua:2108): assemble the same
-- annotation item, hand it to ReaderAnnotation:addItem (which fills datetime,
-- pageno and pageref and inserts it in reading order), then fire
-- AnnotationsModified so the footer counters update and the page redraws/persists.
-- Returns (item) on success or (nil, error_string).
local function saveHighlightFromXPointers(ui, pos0, pos1, opts)
    if not (ui.document:isXPointerInDocument(pos0) and ui.document:isXPointerInDocument(pos1)) then
        return nil, "Error: the located position is no longer valid in this document."
    end
    local text = util.cleanupSelectedText(ui.document:getTextFromXPointers(pos0, pos1) or "")
    if text == "" then
        return nil, "Error: no text could be read at that position, so there is nothing to highlight."
    end
    local hl = ui.view and ui.view.highlight
    local item = {
        page = pos0, -- xpointer doubles as the location key for rolling books
        pos0 = pos0,
        pos1 = pos1,
        text = text,
        drawer = opts.drawer or (hl and hl.saved_drawer),
        color = opts.color or (hl and hl.saved_color),
        note = (opts.note and opts.note ~= "") and opts.note or nil,
        chapter = ui.toc and ui.toc:getTocTitleByPage(pos0) or nil,
    }
    local index = ui.annotation:addItem(item)
    if ui.view and ui.view.footer and ui.view.footer.maybeUpdateFooter then
        ui.view.footer:maybeUpdateFooter()
    end
    ui:handleEvent(Event:new("AnnotationsModified", { item, nb_highlights_added = 1, index_modified = index }))
    return item
end

-- Create a new highlight in the book. Positions never come from the model (it only
-- ever sees text); they come from KOReader's own search index. The model can hand a
-- span locator from a recent grep hit (locator, a "loc:<n>" span -- reused verbatim),
-- name a match from its most recent grep call (search_result, the precise path --
-- those xpointers are reused verbatim), or quote a verbatim passage (text), which we
-- re-search here, disambiguating repeated hits by occurrence/page. All paths converge
-- on saveHighlightFromXPointers. Reflowable (EPUB) only for now: paging documents
-- need pos tables + pboxes rather than xpointers.
local function tool_create_highlight(ui, input)
    local err, summary = rollingOnly(ui, "create_highlight")
    if err then
        return err, summary
    end
    if not ui.annotation then
        return "Error: highlights are not available for this document."
    end
    if input.color ~= nil and not COLORS[input.color] then
        return "Error: 'color' must be one of: " .. table.concat(COLOR_LIST, ", ") .. "."
    end
    if input.drawer ~= nil and not DRAWERS[input.drawer] then
        return "Error: 'drawer' must be one of: " .. table.concat(DRAWER_LIST, ", ") .. "."
    end

    local pos0, pos1
    if input.locator ~= nil then
        -- A span locator from a recent grep hit: its xpointers are reused verbatim.
        local n = parseLocToken(input.locator)
        local entry = n and ensureLocators(ui)[n]
        if not entry then
            return "Error: that locator is stale; grep again, or give a search_result number or verbatim text."
        end
        if entry.kind ~= "span" or not entry.xp_end then
            return "Error: that locator points at a single position, not a passage, so it cannot be highlighted. Use a grep hit's locator."
        end
        pos0, pos1 = entry.xp, entry.xp_end
    elseif input.search_result ~= nil then
        local last = ui._bookbuddy_last_search
        if not (last and last.items and #last.items > 0) then
            return "Error: there are no recent search results. Call grep first, then highlight a match by its number."
        end
        local n = tonumber(input.search_result)
        if not isPositiveInteger(n) or n > #last.items then
            return string.format(
                "Error: 'search_result' must be a whole number between 1 and %d (from your most recent grep call).",
                #last.items
            )
        end
        local item = last.items[n]
        pos0, pos1 = item.start, item["end"]
    elseif input.text ~= nil and input.text ~= "" then
        local results = findPassageMatches(ui, input.text, false)
        if not results or #results == 0 then
            return string.format(
                "No passage matching %q was found to highlight. Use the exact wording from the book, or grep first.",
                input.text
            ),
                _("no match")
        end
        local page = input.page ~= nil and tonumber(input.page) or nil
        local matches = {}
        for i = 1, #results do
            local it = results[i]
            local p = pageOfResult(ui, it)
            if not page or (tonumber(p) and tonumber(p) == page) then
                it._page = p
                matches[#matches + 1] = it
            end
        end
        if #matches == 0 then
            return string.format("No passage matching %q was found on page %d.", input.text, page)
        end
        if input.occurrence ~= nil then
            local occ = tonumber(input.occurrence)
            if not isPositiveInteger(occ) then
                return "Error: 'occurrence' must be a whole number (1 for the first match)."
            end
            if occ > #matches then
                return string.format(
                    "Only %d match(es) for %q%s; cannot highlight occurrence %d.",
                    #matches,
                    input.text,
                    page and (" on page " .. page) or "",
                    occ
                )
            end
            pos0, pos1 = matches[occ].start, matches[occ]["end"]
        elseif #matches > 1 then
            -- Ambiguous: name the pages and make the model choose rather than guess.
            local pages = {}
            for i = 1, math.min(#matches, 10) do
                pages[i] = tostring(matches[i]._page)
            end
            return string.format(
                "Found %d matches for %q (pages %s). Specify 'occurrence' (1-based, in reading order) or narrow with 'page'.",
                #matches,
                input.text,
                table.concat(pages, ", ")
            ),
                _("ambiguous")
        else
            pos0, pos1 = matches[1].start, matches[1]["end"]
        end
    else
        return "Error: provide 'locator' (a loc: token from a grep hit), 'search_result' (a number from your most recent grep), or 'text' (a verbatim passage to highlight)."
    end

    local item
    item, err =
        saveHighlightFromXPointers(ui, pos0, pos1, { note = input.note, color = input.color, drawer = input.drawer })
    if not item then
        return err
    end
    local snippet = item.text:gsub("%s+", " ")
    local note_part = item.note and ("\nNote: " .. item.note) or ""
    return string.format('Highlighted on %s:\n"%s"%s', highlightLocation(item), snippet, note_part),
        _("highlight added")
end

local DISPATCH = {
    grep = tool_grep,
    read = tool_read,
    get_toc = tool_get_toc,
    book_context = tool_book_context,
    get_highlights = tool_get_highlights,
    navigate = tool_navigate,
    edit_highlight_note = tool_edit_highlight_note,
    create_highlight = tool_create_highlight,
}

function Tools.getSpecs()
    local rapidjson = require("rapidjson")
    local function no_args()
        return { type = "object", properties = rapidjson.object({}) }
    end
    return {
        {
            name = "grep",
            description = "Search the current book for text and return matching passages with a little surrounding context, each with a page number and a locator you can pass to read or create_highlight. Literal by default; set regex=true for a pattern. By default only matches at or before the reader's current page are shown (spoiler-safe); later matches are counted but hidden. Set spoiler=true to reveal them, or max_page to tighten the cap to an even earlier page.",
            input_schema = {
                type = "object",
                properties = {
                    query = {
                        type = "string",
                        description = "Text or, with regex=true, a pattern to find (case-insensitive).",
                    },
                    regex = {
                        type = "boolean",
                        description = "Treat query as a regular expression instead of a literal substring (default false).",
                    },
                    context = {
                        type = "string",
                        enum = { "words", "sentence" },
                        description = "How much context to show per hit: a short word window ('words', the default) or the whole sentence ('sentence').",
                    },
                    max_results = { type = "integer", description = "Maximum matches to return (default 8, max 20)." },
                    spoiler = {
                        type = "boolean",
                        description = "Allow matches past the reader's current page (default false). Left false, later-page matches are hidden so the reader is not spoiled; only their count is reported.",
                    },
                    max_page = {
                        type = "integer",
                        description = "Hide matches on pages greater than this (1-based). Only tightens the spoiler-safe window to an earlier page; it never reveals past the reader's current page.",
                    },
                },
                required = { "query" },
                input_examples = {
                    { query = "Mara" },
                    { query = "the harbour", max_results = 5 },
                    { query = "harbour", context = "sentence" },
                },
            },
        },
        {
            name = "get_toc",
            description = "Get the book's table of contents as a numbered list of chapters with page numbers and nesting depth. Each entry that has one also carries a loc: token you can pass to read (from=loc:N) to start reading at that chapter.",
            input_schema = no_args(),
        },
        {
            name = "read",
            description = "Read the current book's text in order, starting from a locator (from grep or "
                .. "get_toc), a page number, or — if you give neither — the reader's current page. "
                .. "Returns a chunk of text and a 'next' locator; call read again with from=next to "
                .. "keep going. Reflowable (EPUB) books only. Read only what you need — every chunk "
                .. "you read stays in context.",
            input_schema = {
                type = "object",
                properties = {
                    from = {
                        type = "string",
                        description = "A locator (loc:… from grep/get_toc/a previous read) OR a page number as a string. Omit to start at the reader's current page.",
                    },
                    limit = {
                        type = "integer",
                        description = "Approximate characters to return (default 1500, max 4000). Smaller is cheaper.",
                    },
                    spoiler = {
                        type = "boolean",
                        description = "Allow reading past the reader's current page (default false). Left false, a read that would go beyond where the reader is stops there, and a read that starts ahead is refused, to avoid spoilers.",
                    },
                },
            },
            input_examples = {
                {},
                { from = "loc:4" },
                { from = "120" },
                { from = "loc:12", limit = 800 },
                { from = "300", spoiler = true },
            },
        },
        {
            name = "book_context",
            description = "Get the book's title and author, the total page count, and the reader's current page and chapter.",
            input_schema = no_args(),
        },
        {
            name = "get_highlights",
            description = "List the reader's own highlights and notes for the current book, in reading order, with the highlighted passage, any attached note, the chapter, and the page number. Use this to discuss passages the reader marked as important or to ground answers in them.",
            input_schema = {
                type = "object",
                properties = {
                    max_results = {
                        type = "integer",
                        description = "Maximum highlights/notes to return (default 100, max 500).",
                    },
                },
            },
        },
        {
            name = "navigate",
            description = "Move the reader to a location in the book. Provide exactly one of: "
                .. "page, percent, chapter_index, or back. The reader's current spot is pushed onto "
                .. "the book's history first, so the result reports where they were and the reader can "
                .. "tap Back (or call this again with back=true) to return. Use get_toc to find chapter "
                .. "numbers. After navigating, tell the reader where you took them.",
            input_schema = {
                type = "object",
                properties = {
                    page = { type = "integer", description = "Absolute page number to jump to (1-based)." },
                    percent = { type = "number", description = "Position in the book as a percentage, 0 to 100." },
                    chapter_index = { type = "integer", description = "1-based chapter number as listed by get_toc." },
                    back = { type = "boolean", description = "Set true to return to the reader's previous location." },
                },
            },
            input_examples = {
                { page = 42 },
                { chapter_index = 3 },
                { percent = 50 },
                { back = true },
            },
        },
        {
            name = "edit_highlight_note",
            description = "Add or extend the note attached to one of the reader's highlights. "
                .. "Identify the highlight by its number from get_highlights (call that first). "
                .. "If the highlight has no note yet, this sets it; if it already has a note, your "
                .. "text is appended below the existing note. It never overwrites or deletes the "
                .. "reader's existing note, so it is safe to use without asking first.",
            input_schema = {
                type = "object",
                properties = {
                    highlight_index = {
                        type = "integer",
                        description = "1-based number of the highlight as listed by get_highlights.",
                    },
                    note = {
                        type = "string",
                        description = "Note text to add. Appended below any existing note for that highlight.",
                    },
                },
                required = { "highlight_index", "note" },
            },
        },
        {
            name = "create_highlight",
            description = "Create a highlight in the book (reflowable/EPUB books only). "
                .. "Provide ONE of: locator -- a loc: token of a grep hit (a passage), the "
                .. "reliable way; OR search_result -- the number of a match from your most "
                .. "recent grep call (also reuses that match's exact position) -- OR text, a "
                .. "short verbatim passage to find and highlight. "
                .. "If the same text occurs more than once, the result lists the pages and "
                .. "asks you to pick one with occurrence (1-based, in reading order) or page. "
                .. "Optionally attach a note and choose color/drawer; both default to the "
                .. "reader's usual highlight style. After highlighting, tell the reader what "
                .. "you marked and on which page.",
            input_schema = {
                type = "object",
                properties = {
                    locator = {
                        type = "string",
                        description = "A loc: token of a grep hit (a passage) to highlight, from your most recent grep results.",
                    },
                    search_result = {
                        type = "integer",
                        description = "1-based number of a match from your most recent grep call.",
                    },
                    text = {
                        type = "string",
                        description = "Verbatim passage to find and highlight (use exact wording from the book). Ignored if locator or search_result is given.",
                    },
                    occurrence = {
                        type = "integer",
                        description = "Which match of 'text' to highlight when it occurs more than once (1-based, reading order). Defaults to the only/first match.",
                    },
                    page = {
                        type = "integer",
                        description = "Restrict the 'text' search to this page (1-based) to disambiguate repeated passages.",
                    },
                    note = { type = "string", description = "Optional note to attach to the new highlight." },
                    color = {
                        type = "string",
                        enum = COLOR_LIST,
                        description = "Optional highlight color. Defaults to the reader's saved color.",
                    },
                    drawer = {
                        type = "string",
                        enum = DRAWER_LIST,
                        description = "Optional highlight style. Defaults to the reader's saved style.",
                    },
                },
            },
            input_examples = {
                { locator = "loc:3" },
                { search_result = 2 },
                { text = "It was the best of times" },
                { text = "the green light", occurrence = 2, note = "recurring symbol" },
                { search_result = 1, color = "yellow" },
            },
        },
        -- Server-side tool: Anthropic runs the search and returns the results
        -- inline, so there is no DISPATCH executor and the model finishes the turn
        -- itself (stop_reason "end_turn") rather than handing us a tool_use to run.
        {
            type = "web_search_20250305",
            name = "web_search",
            max_uses = 5,
        },
    }
end

-- Returns (result_string, summary). result_string is the tool_result content sent
-- back to the model; summary is a short human phrase for the transcript, or nil.
function Tools.execute(name, input, ui)
    local fn = DISPATCH[name]
    if not fn then
        return "Error: unknown tool " .. tostring(name)
    end
    local ok, result, summary = pcall(fn, ui, input or {})
    if not ok then
        logger.warn("BookBuddy: tool error", name, result)
        return "Error while running tool '" .. tostring(name) .. "': " .. tostring(result)
    end
    return result or "", summary
end

return Tools
