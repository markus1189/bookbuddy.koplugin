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
local MAX_PAGE_SPAN = 20
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
    return string.format("%s is only supported for reflowable (EPUB) books in this version.", tool_name),
        _("EPUB only")
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
    local ok, title = pcall(function() return ui.toc:getTocTitleOfCurrentPage() end)
    if ok and title and title ~= "" then
        return title
    end
    return nil
end

-- Plain-English "page N (Chapter)" for the model-facing tool_result.
local function locationLabel(ui)
    local page = tostring(currentPage(ui) or "?")
    local chapter = currentChapter(ui)
    if chapter then
        return string.format("page %s (%s)", page, chapter)
    end
    return "page " .. page
end

local function pageOfResult(ui, item)
    if isRolling(ui) then
        return ui.document:getPageFromXPointer(item.start)
    end
    return item.start
end

-- Read the text of pages [start_page, end_page] (reflowable engine only).
-- Returns text, clamped_start, clamped_end, capped(boolean).
local function readPageRangeText(ui, start_page, end_page)
    local page_count = ui.document:getPageCount()
    start_page = math.max(1, math.min(start_page, page_count))
    end_page = math.max(start_page, math.min(end_page, page_count))
    local capped = false
    if end_page - start_page + 1 > MAX_PAGE_SPAN then
        end_page = start_page + MAX_PAGE_SPAN - 1
        capped = true
    end
    local xp0 = ui.document:getPageXPointer(start_page)
    local xp1 = ui.document:getPageXPointer(math.min(end_page + 1, page_count))
    local text = ui.document:getTextFromXPointers(xp0, xp1)
    return text or "", start_page, end_page, capped
end

-- Literal, case-insensitive full-text search over the whole book. Each result
-- item carries item.start / item["end"] -- the xpointers (rolling) or page
-- positions (paging) spanning the match -- which is exactly what create_highlight
-- needs, so both tools go through this one call.
local function findPassageMatches(ui, query)
    return ui.document:findAllText(query, true, FINDALL_CONTEXT_WORDS, FINDALL_MAX_HITS, false)
end

local function tool_search_book(ui, input)
    local query = input.query
    if not query or query == "" then
        return "Error: 'query' is required."
    end
    local max_results = math.min(tonumber(input.max_results) or DEFAULT_SEARCH_RESULTS, MAX_SEARCH_RESULTS)
    local max_page = tonumber(input.max_page)
    local results = findPassageMatches(ui, query)
    if not results or #results == 0 then
        return string.format("No matches found for %q.", query), _("no matches")
    end
    -- Drop hits past max_page to avoid spoilers; the page is still searched, just not revealed.
    local visible, hidden = {}, 0
    for i = 1, #results do
        local item = results[i]
        local page = pageOfResult(ui, item)
        if max_page and page and tonumber(page) and tonumber(page) > max_page then
            hidden = hidden + 1
        else
            item._page = page
            visible[#visible + 1] = item
        end
    end
    if #visible == 0 then
        return string.format(
            "No matches for %q at or before page %d (%d match(es) hidden beyond it to avoid spoilers).",
            query, max_page, hidden), _("all hidden")
    end
    local header = string.format("Found %d match(es) for %q (showing up to %d)", #visible, query, max_results)
    if hidden > 0 then
        header = header .. string.format(", %d hidden beyond page %d to avoid spoilers", hidden, max_page)
    end
    local out = { header .. ":" }
    -- Remember exactly the matches the model sees, in display order, so it can
    -- later highlight one by its number via create_highlight{search_result=N}.
    -- Stashed on the live ui (tools already receive it) and overwritten each search.
    local shown = {}
    for i = 1, math.min(#visible, max_results) do
        local item = visible[i]
        shown[i] = item
        local snippet = table.concat({
            item.prev_text or "",
            item.matched_word_prefix or "",
            item.matched_text or "",
            item.matched_word_suffix or "",
            item.next_text or "",
        })
        snippet = snippet:gsub("%s+", " ")
        out[#out + 1] = string.format("%d. [page %s] …%s…", i, tostring(item._page), snippet)
    end
    ui._bookbuddy_last_search = { query = query, items = shown }
    return truncate(table.concat(out, "\n")), T(_("%1 match(es)"), #visible)
end

local function tool_read_page_range(ui, input)
    local err, summary = rollingOnly(ui, "read_page_range")
    if err then return err, summary end
    local start_page = tonumber(input.start_page)
    local end_page = tonumber(input.end_page)
    if not start_page or not end_page then
        return "Error: 'start_page' and 'end_page' are required integers."
    end
    local text, s, e, capped = readPageRangeText(ui, start_page, end_page)
    if not text or text == "" then
        return string.format("No text found on pages %d–%d.", start_page, end_page), _("no text")
    end
    local header = string.format("Text of pages %d–%d%s:", s, e, capped and " (range capped)" or "")
    return truncate(header .. "\n\n" .. text), T(_("~%1 words"), wordCount(text))
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
        out[#out + 1] = string.format("%d. %s%s (page %s)", i, indent, item.title or "", tostring(item.page or "?"))
    end
    if #toc > limit then
        out[#out + 1] = string.format("…and %d more entries.", #toc - limit)
    end
    return truncate(table.concat(out, "\n")), T(_("%1 entries"), #toc)
end

local function tool_read_chapter(ui, input)
    local err, summary = rollingOnly(ui, "read_chapter")
    if err then return err, summary end
    local toc = ui.document:getToc()
    if not toc or #toc == 0 then
        return "This book has no table of contents to identify chapters.", _("no chapters")
    end
    local idx = tonumber(input.chapter_index)
    if not idx or idx < 1 or idx > #toc then
        return string.format("Error: 'chapter_index' must be between 1 and %d.", #toc)
    end
    local entry = toc[idx]
    local start_page = entry.page or 1
    local page_count = ui.document:getPageCount()
    local end_page = page_count
    for j = idx + 1, #toc do
        if (toc[j].depth or 1) <= (entry.depth or 1) then
            end_page = math.max(start_page, (toc[j].page or page_count) - 1)
            break
        end
    end
    local text, s, e, capped = readPageRangeText(ui, start_page, end_page)
    if not text or text == "" then
        return string.format("Could not read chapter %d (%s).", idx, entry.title or ""), _("no text")
    end
    local header
    if capped then
        header = string.format(
            "Chapter %d: %s spans pages %d–%d. Showing pages %d–%d only (20-page limit); "
                .. "read the rest with read_page_range starting at page %d.",
            idx, entry.title or "", start_page, end_page, s, e, e + 1)
    else
        header = string.format("Chapter %d: %s (pages %d–%d)", idx, entry.title or "", s, e)
    end
    return truncate(header .. "\n\n" .. text), T(_("~%1 words"), wordCount(text))
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
        local ok, title = pcall(function() return ui.toc:getTocTitleOfCurrentPage() end)
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
        if shown >= max_results then break end
        shown = shown + 1
        local a = list[i]
        local text = a.text and a.text ~= "" and a.text:gsub("%s+", " ") or nil
        local note = a.note and a.note ~= "" and a.note:gsub("%s+", " ") or nil
        local entry = string.format("%d. [%s | %s]", i, note and "note" or "highlight", highlightLocation(a))
        if text then entry = entry .. "\n   \"" .. text .. "\"" end
        if note then entry = entry .. "\n   note: " .. note end
        out[#out + 1] = entry
    end
    local header = string.format("%d highlight(s)/note(s) in this book%s:",
        total, shown < total and string.format(" (showing first %d)", shown) or "")
    return truncate(header .. "\n" .. table.concat(out, "\n")), T(_("%1 found"), total)
end

-- Move the reader within the book. Mirrors KOReader's own jump idiom
-- (readertoc.lua:984-990): push the current spot onto ReaderLink's location
-- stack first, so the reader's Back gesture and the menu's forward arrow return
-- here -- then fire the navigation event. The result reports where the reader
-- was so the model can narrate it. Non-destructive, so no confirmation.
local function tool_navigate(ui, input)
    local targets = {}
    if input.page ~= nil then targets[#targets + 1] = "page" end
    if input.percent ~= nil then targets[#targets + 1] = "percent" end
    if input.chapter_index ~= nil then targets[#targets + 1] = "chapter_index" end
    if input.back then targets[#targets + 1] = "back" end
    if #targets == 0 then
        return "Error: provide exactly one of page, percent, chapter_index, or back."
    end
    if #targets > 1 then
        return "Error: provide only one of page, percent, chapter_index, or back (got "
            .. table.concat(targets, ", ") .. ")."
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
    return string.format("Moved from %s to %s. The reader can tap Back to return here.", from, to),
        T(_("→ %1"), to)
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
        return string.format("Error: 'highlight_index' must be a whole number between 1 and %d (see get_highlights).", #list)
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
            ui:handleEvent(Event:new("AnnotationsModified",
                { a, nb_highlights_added = -1, nb_notes_added = 1 }))
        end
    end

    local verb = had_note and "Appended to" or "Added"
    return string.format("%s the note on highlight %d (%s). The note now reads:\n%s",
            verb, idx, highlightLocation(a), new_note),
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
    for i = 1, #list do set[list[i]] = true end
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
        page    = pos0, -- xpointer doubles as the location key for rolling books
        pos0    = pos0,
        pos1    = pos1,
        text    = text,
        drawer  = opts.drawer or (hl and hl.saved_drawer),
        color   = opts.color or (hl and hl.saved_color),
        note    = (opts.note and opts.note ~= "") and opts.note or nil,
        chapter = ui.toc and ui.toc:getTocTitleByPage(pos0) or nil,
    }
    local index = ui.annotation:addItem(item)
    if ui.view and ui.view.footer and ui.view.footer.maybeUpdateFooter then
        ui.view.footer:maybeUpdateFooter()
    end
    ui:handleEvent(Event:new("AnnotationsModified",
        { item, nb_highlights_added = 1, index_modified = index }))
    return item
end

-- Create a new highlight in the book. Positions never come from the model (it only
-- ever sees text); they come from KOReader's own search index. The model either
-- names a match from its most recent search_book call (search_result, the precise
-- path -- those xpointers are reused verbatim), or quotes a verbatim passage (text),
-- which we re-search here, disambiguating repeated hits by occurrence/page. Both
-- paths converge on saveHighlightFromXPointers. Reflowable (EPUB) only for now:
-- paging documents need pos tables + pboxes rather than xpointers.
local function tool_create_highlight(ui, input)
    local err, summary = rollingOnly(ui, "create_highlight")
    if err then return err, summary end
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
    if input.search_result ~= nil then
        local last = ui._bookbuddy_last_search
        if not (last and last.items and #last.items > 0) then
            return "Error: there are no recent search results. Call search_book first, then highlight a match by its number."
        end
        local n = tonumber(input.search_result)
        if not isPositiveInteger(n) or n > #last.items then
            return string.format(
                "Error: 'search_result' must be a whole number between 1 and %d (from your most recent search_book call).",
                #last.items)
        end
        local item = last.items[n]
        pos0, pos1 = item.start, item["end"]
    elseif input.text ~= nil and input.text ~= "" then
        local results = findPassageMatches(ui, input.text)
        if not results or #results == 0 then
            return string.format(
                "No passage matching %q was found to highlight. Use the exact wording from the book, or search_book first.",
                input.text), _("no match")
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
                return string.format("Only %d match(es) for %q%s; cannot highlight occurrence %d.",
                    #matches, input.text, page and (" on page " .. page) or "", occ)
            end
            pos0, pos1 = matches[occ].start, matches[occ]["end"]
        elseif #matches > 1 then
            -- Ambiguous: name the pages and make the model choose rather than guess.
            local pages = {}
            for i = 1, math.min(#matches, 10) do pages[i] = tostring(matches[i]._page) end
            return string.format(
                "Found %d matches for %q (pages %s). Specify 'occurrence' (1-based, in reading order) or narrow with 'page'.",
                #matches, input.text, table.concat(pages, ", ")), _("ambiguous")
        else
            pos0, pos1 = matches[1].start, matches[1]["end"]
        end
    else
        return "Error: provide 'search_result' (a number from your most recent search_book) or 'text' (a verbatim passage to highlight)."
    end

    local item
    item, err = saveHighlightFromXPointers(ui, pos0, pos1,
        { note = input.note, color = input.color, drawer = input.drawer })
    if not item then
        return err
    end
    local snippet = item.text:gsub("%s+", " ")
    local note_part = item.note and ("\nNote: " .. item.note) or ""
    return string.format("Highlighted on %s:\n\"%s\"%s", highlightLocation(item), snippet, note_part),
        _("highlight added")
end

local DISPATCH = {
    search_book = tool_search_book,
    read_page_range = tool_read_page_range,
    get_toc = tool_get_toc,
    read_chapter = tool_read_chapter,
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
            name = "search_book",
            description = "Full-text search the entire book for a string and return matches with surrounding context and their page numbers. Use max_page to hide matches past a given page so the reader is not spoiled by later content.",
            input_schema = {
                type = "object",
                properties = {
                    query = { type = "string", description = "Text to search for (literal, case-insensitive)." },
                    max_results = { type = "integer", description = "Maximum matches to return (default 8, max 20)." },
                    max_page = { type = "integer", description = "Hide matches on pages greater than this (1-based) to avoid spoilers. Omit to search the whole book. The count of hidden matches is reported, but their content is not." },
                },
                required = { "query" },
            },
        },
        {
            name = "read_page_range",
            description = "Read the text of a range of pages to expand context beyond the highlighted passage. Reflowable (EPUB) books only; at most 20 pages per call.",
            input_schema = {
                type = "object",
                properties = {
                    start_page = { type = "integer", description = "First page to read (1-based)." },
                    end_page = { type = "integer", description = "Last page to read (inclusive)." },
                },
                required = { "start_page", "end_page" },
            },
        },
        {
            name = "get_toc",
            description = "Get the book's table of contents as a numbered list of chapters with page numbers and nesting depth.",
            input_schema = no_args(),
        },
        {
            name = "read_chapter",
            description = "Read the text of a chapter identified by its number from get_toc (1-based). Reflowable (EPUB) books only. Long chapters are capped at 20 pages per call; the result reports the chapter's full page range, so read any remainder with read_page_range.",
            input_schema = {
                type = "object",
                properties = {
                    chapter_index = { type = "integer", description = "1-based index of the chapter as listed by get_toc." },
                },
                required = { "chapter_index" },
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
                    max_results = { type = "integer", description = "Maximum highlights/notes to return (default 100, max 500)." },
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
                    highlight_index = { type = "integer", description = "1-based number of the highlight as listed by get_highlights." },
                    note = { type = "string", description = "Note text to add. Appended below any existing note for that highlight." },
                },
                required = { "highlight_index", "note" },
            },
        },
        {
            name = "create_highlight",
            description = "Create a highlight in the book (reflowable/EPUB books only). "
                .. "Provide EITHER search_result -- the number of a match from your most "
                .. "recent search_book call (the reliable way; reuses that match's exact "
                .. "position) -- OR text, a short verbatim passage to find and highlight. "
                .. "If the same text occurs more than once, the result lists the pages and "
                .. "asks you to pick one with occurrence (1-based, in reading order) or page. "
                .. "Optionally attach a note and choose color/drawer; both default to the "
                .. "reader's usual highlight style. After highlighting, tell the reader what "
                .. "you marked and on which page.",
            input_schema = {
                type = "object",
                properties = {
                    search_result = { type = "integer", description = "1-based number of a match from your most recent search_book call." },
                    text = { type = "string", description = "Verbatim passage to find and highlight (use exact wording from the book). Ignored if search_result is given." },
                    occurrence = { type = "integer", description = "Which match of 'text' to highlight when it occurs more than once (1-based, reading order). Defaults to the only/first match." },
                    page = { type = "integer", description = "Restrict the 'text' search to this page (1-based) to disambiguate repeated passages." },
                    note = { type = "string", description = "Optional note to attach to the new highlight." },
                    color = { type = "string", enum = COLOR_LIST, description = "Optional highlight color. Defaults to the reader's saved color." },
                    drawer = { type = "string", enum = DRAWER_LIST, description = "Optional highlight style. Defaults to the reader's saved style." },
                },
            },
            input_examples = {
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
