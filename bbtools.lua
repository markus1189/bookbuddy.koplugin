-- Tool specs (Anthropic input_schema) and their executors. Executors run in the
-- main process and call straight into KOReader's document API. They never run in
-- the network subprocess. Every executor returns a plain string for tool_result.

local logger = require("logger")

local Tools = {}

local MAX_RESULT_CHARS = 6000
local MAX_PAGE_SPAN = 20
local DEFAULT_SEARCH_RESULTS = 8
local MAX_SEARCH_RESULTS = 20
local FINDALL_CONTEXT_WORDS = 10
local FINDALL_MAX_HITS = 5000

local function truncate(text, limit)
    limit = limit or MAX_RESULT_CHARS
    if #text > limit then
        return text:sub(1, limit) .. "\n…[truncated]"
    end
    return text
end

local function isRolling(ui)
    return ui.rolling ~= nil
end

local function currentPage(ui)
    if isRolling(ui) then
        return ui.document:getCurrentPage()
    end
    return ui.view and ui.view.state and ui.view.state.page
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
    local res = ui.document:getTextFromXPointers(xp0, xp1)
    return res and res.text or "", start_page, end_page, capped
end

local function tool_search_book(ui, input)
    local query = input.query
    if not query or query == "" then
        return "Error: 'query' is required."
    end
    local max_results = math.min(tonumber(input.max_results) or DEFAULT_SEARCH_RESULTS, MAX_SEARCH_RESULTS)
    local results = ui.document:findAllText(query, true, FINDALL_CONTEXT_WORDS, FINDALL_MAX_HITS, false)
    if not results or #results == 0 then
        return string.format("No matches found for %q.", query)
    end
    local out = {
        string.format("Found %d match(es) for %q (showing up to %d):", #results, query, max_results),
    }
    for i = 1, math.min(#results, max_results) do
        local item = results[i]
        local snippet = table.concat({
            item.prev_text or "",
            item.matched_word_prefix or "",
            item.matched_text or "",
            item.matched_word_suffix or "",
            item.next_text or "",
        })
        snippet = snippet:gsub("%s+", " ")
        out[#out + 1] = string.format("%d. [page %s] …%s…", i, tostring(pageOfResult(ui, item)), snippet)
    end
    return truncate(table.concat(out, "\n"))
end

local function tool_read_page_range(ui, input)
    if not isRolling(ui) then
        return "read_page_range is only supported for reflowable (EPUB) books in this version."
    end
    local start_page = tonumber(input.start_page)
    local end_page = tonumber(input.end_page)
    if not start_page or not end_page then
        return "Error: 'start_page' and 'end_page' are required integers."
    end
    local text, s, e, capped = readPageRangeText(ui, start_page, end_page)
    if not text or text == "" then
        return string.format("No text found on pages %d–%d.", start_page, end_page)
    end
    local header = string.format("Text of pages %d–%d%s:", s, e, capped and " (range capped)" or "")
    return truncate(header .. "\n\n" .. text)
end

local function tool_get_toc(ui, _input)
    local toc = ui.document:getToc()
    if not toc or #toc == 0 then
        return "This book has no table of contents."
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
    return truncate(table.concat(out, "\n"))
end

local function tool_read_chapter(ui, input)
    if not isRolling(ui) then
        return "read_chapter is only supported for reflowable (EPUB) books in this version."
    end
    local toc = ui.document:getToc()
    if not toc or #toc == 0 then
        return "This book has no table of contents to identify chapters."
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
        return string.format("Could not read chapter %d (%s).", idx, entry.title or "")
    end
    local header = string.format("Chapter %d: %s (pages %d–%d%s)",
        idx, entry.title or "", s, e, capped and ", truncated" or "")
    return truncate(header .. "\n\n" .. text)
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
    lines[#lines + 1] = string.format("Current page: %s of %s",
        tostring(currentPage(ui) or "?"), tostring(ui.document:getPageCount() or "?"))
    if ui.toc then
        local ok, title = pcall(function() return ui.toc:getTocTitleOfCurrentPage() end)
        if ok and title and title ~= "" then
            lines[#lines + 1] = "Current chapter: " .. title
        end
    end
    return table.concat(lines, "\n")
end

local DISPATCH = {
    search_book = tool_search_book,
    read_page_range = tool_read_page_range,
    get_toc = tool_get_toc,
    read_chapter = tool_read_chapter,
    book_context = tool_book_context,
}

function Tools.getSpecs()
    local rapidjson = require("rapidjson")
    local function no_args()
        return { type = "object", properties = rapidjson.object({}) }
    end
    return {
        {
            name = "search_book",
            description = "Full-text search the entire book for a string and return matches with surrounding context and their page numbers.",
            input_schema = {
                type = "object",
                properties = {
                    query = { type = "string", description = "Text to search for (literal, case-insensitive)." },
                    max_results = { type = "integer", description = "Maximum matches to return (default 8, max 20)." },
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
            description = "Read the full text of a chapter identified by its number from get_toc (1-based). Reflowable (EPUB) books only.",
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

function Tools.execute(name, input, ui)
    local fn = DISPATCH[name]
    if not fn then
        return "Error: unknown tool " .. tostring(name)
    end
    local ok, result = pcall(fn, ui, input or {})
    if not ok then
        logger.warn("BookBuddy: tool error", name, result)
        return "Error while running tool '" .. tostring(name) .. "': " .. tostring(result)
    end
    return result or ""
end

return Tools
