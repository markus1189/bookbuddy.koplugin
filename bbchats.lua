-- Per-book chat persistence: saves finished conversations to the open book's
-- .sdr sidecar so they survive viewer-close, book-close, and KOReader restart,
-- and travel with the book (e.g. via Syncthing) exactly like bbmemory does.
--
-- Layout under <sidecar>/bookbuddy_chats/:
--   index.json   [{ id, title, ts_created, ts_updated, turns, usage }, ...]
--   <id>.json    { id, title, ts_*, selected_text, note, messages[], transcript[], usage }
-- The list view reads only index.json (no payload parsing); reopening reads one
-- payload. The index is a rebuildable cache, NOT the source of truth: payloads
-- carry their own id/metadata, so a missing/corrupt index is rebuilt by scanning
-- payloads, and each save writes the payload BEFORE the index so a crash between
-- the two writes leaves a complete chat with a stale index (recoverable), never
-- an index entry pointing at a missing payload.
local DocSettings = require("docsettings")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local rapidjson = require("rapidjson")
local util = require("util")
local ffiUtil = require("ffi/util")
local _ = require("gettext")
local T = ffiUtil.template

local Chats = {}

local INDEX_FILE = "index.json"
-- Default cap on stored chats per book; the user setting max_saved_chats
-- overrides it (see bbsettings).
Chats.DEFAULT_MAX = 20
-- Menu-row titles derive from the first question; clip on codepoint boundaries
-- so a cut can't land inside a multibyte UTF-8 character (same idiom as
-- main.lua's passage preview clip).
local TITLE_MAX_CHARS = 60

-- Chats live beside bookbuddy_memory in the book's sidecar. nil when there is
-- no resolvable sidecar (e.g. no open file), in which case persistence is
-- skipped entirely.
function Chats.baseDirForBook(ui)
    local file = ui and ui.document and ui.document.file
    local sdr = file and DocSettings:getSidecarDir(file)
    if not sdr or sdr == "" then
        return nil
    end
    return sdr .. "/bookbuddy_chats"
end

-- Ids double as payload filenames; refuse anything that could escape the chats
-- directory (path separators, dots) so a corrupted index entry can't make
-- load/delete touch arbitrary files.
local function validId(id)
    return type(id) == "string" and id:match("^[%w%-]+$") ~= nil
end

-- id = <epoch-seconds>-<counter>. os.time() alone collides when two chats reach
-- their first save in the same second (e.g. quick successive one-turn chats);
-- the monotonic suffix disambiguates. Assigned on the FIRST clean save and
-- reused for every later overwrite, so a chat always rewrites its own payload.
local last_id_ts, id_counter = nil, 0
local function newId()
    local ts = os.time()
    if ts == last_id_ts then
        id_counter = id_counter + 1
    else
        last_id_ts, id_counter = ts, 0
    end
    return string.format("%d-%d", ts, id_counter)
end

local function readJson(path)
    local s = util.readFromFile(path)
    if not s or s == "" then
        return nil
    end
    local ok, v = pcall(rapidjson.decode, s)
    if ok and type(v) == "table" then
        return v
    end
    return nil
end

local function writeJson(path, value)
    local ok, s = pcall(rapidjson.encode, value)
    if not ok or type(s) ~= "string" then
        logger.warn("BookBuddy: could not encode chat JSON for", path, s)
        return false
    end
    local wok, werr = util.writeToFile(s, path)
    if not wok then
        logger.warn("BookBuddy: could not write", path, werr)
        return false
    end
    return true
end

-- The wire format requires a message's content list to serialize as a JSON
-- array. rapidjson encodes an untagged empty Lua table as {} (object), which
-- the gateway 400s on resend ("content should be a valid list"), so tag empty
-- content tables with rapidjson.array's __jsontype metatable. Run on BOTH save
-- (so the stored payload reads "content":[]) and load (decode returns plain
-- tables, so a reloaded empty list must be re-tagged before buildBody re-encodes
-- it). Non-empty arrays keep their arrayness through positive integer keys.
local function ensureContentArrays(messages)
    if type(messages) ~= "table" then
        return
    end
    for _, msg in ipairs(messages) do
        if type(msg) == "table" and type(msg.content) == "table" and #msg.content == 0 then
            rapidjson.array(msg.content)
        end
    end
end

-- Human title for a stored chat: its first user question, whitespace-collapsed
-- and clipped codepoint-safe. A resumed chat keeps the title it was saved with
-- (the first question never changes).
function Chats.title(state)
    if type(state.title) == "string" and state.title ~= "" then
        return state.title
    end
    local q
    for _, e in ipairs(state.transcript or {}) do
        if e.role == "user" and type(e.text) == "string" and e.text ~= "" then
            q = e.text
            break
        end
    end
    if not q then
        return _("Untitled chat")
    end
    q = q:gsub("%s+", " ")
    local chars = util.splitToChars(q)
    if #chars > TITLE_MAX_CHARS then
        return table.concat(chars, "", 1, TITLE_MAX_CHARS) .. "…"
    end
    return q
end

-- Short "when" label for a list row. `now` is injectable for tests.
function Chats.relativeTime(ts, now)
    ts = tonumber(ts)
    if not ts then
        return ""
    end
    now = now or os.time()
    local d = now - ts
    if d < 60 then
        return _("just now")
    elseif d < 3600 then
        return T(_("%1 min ago"), math.floor(d / 60))
    elseif d < 86400 then
        return T(_("%1 h ago"), math.floor(d / 3600))
    elseif d < 7 * 86400 then
        return T(_("%1 d ago"), math.floor(d / 86400))
    end
    return os.date("%Y-%m-%d", ts)
end

local function countUserTurns(state)
    local n = 0
    for _, e in ipairs(state.transcript or {}) do
        if e.role == "user" then
            n = n + 1
        end
    end
    return n
end

local function indexEntryFor(state)
    return {
        id = state.id,
        title = state.title,
        ts_created = state.ts_created,
        ts_updated = state.ts_updated,
        turns = countUserTurns(state),
        usage = state.usage,
    }
end

local function indexPath(base)
    return base .. "/" .. INDEX_FILE
end

local function payloadPath(base, id)
    return base .. "/" .. id .. ".json"
end

-- Rebuild the index by scanning payloads (the fallback for a missing/corrupt
-- index). Payloads are self-describing, so nothing is lost — only the cheap
-- listing cache. The rebuilt index is written back so the next list is O(1) again.
local function rebuildIndex(base)
    local index = rapidjson.array({})
    local ok, iter, dir_obj = pcall(lfs.dir, base)
    if not ok then
        return index
    end
    for name in iter, dir_obj do
        local id = name ~= INDEX_FILE and name:match("^([%w%-]+)%.json$")
        if id then
            local state = readJson(payloadPath(base, id))
            if state and state.id == id then
                index[#index + 1] = indexEntryFor(state)
            end
        end
    end
    writeJson(indexPath(base), index)
    return index
end

-- Read the index, rebuilding from payloads when missing/corrupt, and drop any
-- malformed entries so downstream sorts/compares can assume {id=...} tables.
local function readIndex(base)
    local raw = readJson(indexPath(base))
    if not raw then
        return rebuildIndex(base)
    end
    local index = rapidjson.array({})
    for _, e in ipairs(raw) do
        if type(e) == "table" and validId(e.id) then
            index[#index + 1] = e
        end
    end
    return index
end

-- Newest-first metadata rows for the open book's stored chats. Entries whose
-- payload has vanished (a crash between a delete's two writes) are dropped, so
-- the list never offers a chat that can't be loaded.
function Chats.list(ui)
    local base = Chats.baseDirForBook(ui)
    if not base or lfs.attributes(base, "mode") ~= "directory" then
        return {}
    end
    local index = readIndex(base)
    local rows = {}
    for _, e in ipairs(index) do
        if lfs.attributes(payloadPath(base, e.id), "mode") == "file" then
            rows[#rows + 1] = e
        end
    end
    table.sort(rows, function(a, b)
        return (tonumber(a.ts_updated) or 0) > (tonumber(b.ts_updated) or 0)
    end)
    return rows
end

-- Full payload for one stored chat, ready to feed Conversation:new{resume_state}.
-- Restores the empty-content array tagging decode loses (see ensureContentArrays).
function Chats.load(ui, id)
    local base = Chats.baseDirForBook(ui)
    if not base or not validId(id) then
        return nil
    end
    local state = readJson(payloadPath(base, id))
    if not state or type(state.messages) ~= "table" or type(state.transcript) ~= "table" then
        return nil
    end
    ensureContentArrays(state.messages)
    return state
end

-- Persist one conversation state ({ id?, ts_created?, selected_text, note,
-- messages, transcript, usage }). Assigns an id on the first save, stamps
-- ts_updated, writes the payload then upserts the index entry, and prunes to
-- max_chats. Returns the id, or nil when the book has no sidecar or the write
-- failed. Mutates state (id/ts/title) so the caller can reuse them.
function Chats.save(ui, state, max_chats)
    local base = Chats.baseDirForBook(ui)
    if not base then
        return nil
    end
    util.makePath(base)
    state.id = state.id or newId()
    local now = os.time()
    state.ts_created = tonumber(state.ts_created) or now
    state.ts_updated = now
    state.title = Chats.title(state)
    ensureContentArrays(state.messages)
    -- Payload before index: see the header comment on crash ordering.
    if not writeJson(payloadPath(base, state.id), state) then
        return nil
    end
    local index = readIndex(base)
    local entry = indexEntryFor(state)
    local found = false
    for i, e in ipairs(index) do
        if e.id == state.id then
            index[i] = entry
            found = true
            break
        end
    end
    if not found then
        index[#index + 1] = entry
    end
    writeJson(indexPath(base), index)
    Chats.prune(ui, max_chats, state.id)
    return state.id
end

-- Keep the newest `n` chats by ts_updated and unlink the rest (payload + index
-- entry). keep_id (the just-saved chat) is pinned to the kept set explicitly, so
-- pruning immediately after a save can never evict the chat that triggered it —
-- even if clock skew gave another entry a newer timestamp.
function Chats.prune(ui, n, keep_id)
    local base = Chats.baseDirForBook(ui)
    if not base then
        return
    end
    n = math.max(1, math.floor(tonumber(n) or Chats.DEFAULT_MAX))
    local index = readIndex(base)
    if #index <= n then
        return
    end
    table.sort(index, function(a, b)
        if a.id == keep_id then
            return true
        end
        if b.id == keep_id then
            return false
        end
        return (tonumber(a.ts_updated) or 0) > (tonumber(b.ts_updated) or 0)
    end)
    for i = #index, n + 1, -1 do
        os.remove(payloadPath(base, index[i].id))
        index[i] = nil
    end
    writeJson(indexPath(base), index)
end

-- Remove one stored chat: payload first, then its index entry.
function Chats.delete(ui, id)
    local base = Chats.baseDirForBook(ui)
    if not base or not validId(id) then
        return
    end
    os.remove(payloadPath(base, id))
    local index = readIndex(base)
    for i = #index, 1, -1 do
        if index[i].id == id then
            table.remove(index, i)
        end
    end
    writeJson(indexPath(base), index)
end

-- Remove every stored chat for this book.
function Chats.clear(ui)
    local base = Chats.baseDirForBook(ui)
    if base and lfs.attributes(base, "mode") == "directory" then
        return ffiUtil.purgeDir(base)
    end
    return true
end

return Chats
