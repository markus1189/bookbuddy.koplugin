-- bbchats against a REAL on-disk store in a temp dir (mirrors memory_spec's
-- approach: stub only the KOReader seams, exercise real file IO). Covers the
-- save/list/load/delete/clear/prune lifecycle, the index-as-rebuildable-cache
-- fallback, the N-cap eviction, and the two serialization risks the design
-- calls out as required tests: a thinking block's signature must round-trip
-- byte-identical, and an empty content list must serialize as [] (not {}) and
-- reload as a resendable array.
local lfs = require("lfs")
local stubs = require("support.stubs")
local json = stubs.json

local function readFile(path)
    local f = io.open(path, "rb")
    if not f then
        return nil
    end
    local c = f:read("*a")
    f:close()
    return c
end

local function writeFile(content, path)
    local f, err = io.open(path, "wb")
    if not f then
        return false, err
    end
    f:write(content)
    f:close()
    return true
end

local function makePath(path)
    local cur = ""
    for seg in path:gmatch("[^/]+") do
        cur = cur .. "/" .. seg
        lfs.mkdir(cur)
    end
    return true
end

local function purgeDir(dir)
    for name in lfs.dir(dir) do
        if name ~= "." and name ~= ".." then
            local p = dir .. "/" .. name
            if lfs.attributes(p, "mode") == "directory" then
                purgeDir(p)
            else
                os.remove(p)
            end
        end
    end
    lfs.rmdir(dir)
end

-- Codepoint-safe character split, the subset of KOReader's util.splitToChars
-- that Chats.title leans on.
local function splitToChars(s)
    local chars = {}
    for ch in tostring(s):gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        chars[#chars + 1] = ch
    end
    return chars
end

describe("bbchats store", function()
    local Chats
    local sdr, base, ui

    setup(function()
        package.loaded["libs/libkoreader-lfs"] = lfs
        -- The sidecar dir resolves to the per-test temp dir via this seam.
        package.loaded["docsettings"] = {
            getSidecarDir = function(_, _file)
                return sdr
            end,
        }
        package.loaded["gettext"] = function(s)
            return s
        end
        package.loaded["logger"] = { dbg = stubs.noop, warn = stubs.noop, info = stubs.noop, error = stubs.noop }
        package.loaded["util"] = {
            makePath = makePath,
            readFromFile = readFile,
            writeToFile = writeFile,
            splitToChars = splitToChars,
        }
        package.loaded["ffi/util"] = {
            template = function(fmt, ...)
                local args = { ... }
                return (
                    fmt:gsub("%%(%d+)", function(n)
                        return tostring(args[tonumber(n)] or "")
                    end)
                )
            end,
            purgeDir = purgeDir,
        }
        package.loaded["rapidjson"] = {
            encode = json.encode,
            decode = json.decode,
            array = function(t)
                return setmetatable(t or {}, { __jsontype = "array" })
            end,
            object = function(t)
                return t or {}
            end,
            null = json.null,
        }
        Chats = require("bbchats")
    end)

    before_each(function()
        sdr = os.tmpname()
        os.remove(sdr)
        lfs.mkdir(sdr)
        base = sdr .. "/bookbuddy_chats"
        ui = { document = { file = "/books/test.epub" } }
    end)

    after_each(function()
        if sdr and lfs.attributes(sdr, "mode") == "directory" then
            purgeDir(sdr)
        end
    end)

    local function mkState(question, answer)
        return {
            selected_text = "the passage",
            messages = {
                { role = "user", content = "<question>" .. question .. "</question>" },
                { role = "assistant", content = { { type = "text", text = answer or "A" } } },
            },
            transcript = {
                { role = "user", text = question },
                { role = "assistant", text = answer or "A" },
            },
            usage = { input = 10, output = 20, cache_read = 0, cache_write = 0 },
        }
    end

    -- Overwrite the index with hand-picked ts_updated values, so ordering tests
    -- don't depend on the wall clock (all saves in a test land in the same second).
    local function setIndexTimes(times)
        local index = json.decode(readFile(base .. "/index.json"))
        for _, e in ipairs(index) do
            if times[e.id] then
                e.ts_updated = times[e.id]
            end
        end
        writeFile(json.encode(index), base .. "/index.json")
    end

    describe("save/list/load", function()
        it("assigns an id on first save and reuses it on overwrite", function()
            local state = mkState("Q1")
            local id = Chats.save(ui, state)
            assert.is_not_nil(id)
            assert.are.equal(id, state.id)
            state.messages[#state.messages + 1] = { role = "user", content = "Q2" }
            assert.are.equal(id, Chats.save(ui, state))
            assert.are.equal(1, #Chats.list(ui))
        end)

        it("skips persistence entirely when there is no sidecar", function()
            sdr = nil
            assert.is_nil(Chats.save(ui, mkState("Q")))
            assert.are.same({}, Chats.list(ui))
            assert.is_nil(Chats.load(ui, "1-0"))
        end)

        it("lists metadata newest-first and loads the full payload", function()
            local a, b = mkState("first question"), mkState("second question")
            Chats.save(ui, a)
            Chats.save(ui, b)
            setIndexTimes({ [a.id] = 100, [b.id] = 200 })
            local rows = Chats.list(ui)
            assert.are.equal(2, #rows)
            assert.are.equal(b.id, rows[1].id)
            assert.are.equal("second question", rows[1].title)
            assert.are.equal(1, rows[1].turns)
            local loaded = Chats.load(ui, a.id)
            assert.are.equal("first question", loaded.transcript[1].text)
            assert.are.equal("the passage", loaded.selected_text)
            assert.are.equal(10, loaded.usage.input)
        end)

        it("rebuilds the index from payloads when it is missing or corrupt", function()
            local a = mkState("rebuilt title")
            Chats.save(ui, a)
            os.remove(base .. "/index.json")
            local rows = Chats.list(ui)
            assert.are.equal(1, #rows)
            assert.are.equal("rebuilt title", rows[1].title)
            writeFile("not json", base .. "/index.json")
            assert.are.equal(1, #Chats.list(ui))
        end)

        it("drops index entries whose payload has vanished", function()
            local a, b = mkState("kept"), mkState("gone")
            Chats.save(ui, a)
            Chats.save(ui, b)
            os.remove(base .. "/" .. b.id .. ".json")
            local rows = Chats.list(ui)
            assert.are.equal(1, #rows)
            assert.are.equal(a.id, rows[1].id)
        end)

        it("refuses ids that could escape the chats directory", function()
            assert.is_nil(Chats.load(ui, "../escape"))
            assert.is_nil(Chats.load(ui, "a/b"))
            assert.is_nil(Chats.load(ui, nil))
        end)
    end)

    describe("round-trip fidelity", function()
        it("preserves a thinking block's signature byte-identically", function()
            local state = mkState("Q")
            state.messages[2].content = {
                { type = "thinking", thinking = "reasoning…", signature = "SIGx9/=aa==" },
                { type = "text", text = "A" },
            }
            Chats.save(ui, state)
            local loaded = Chats.load(ui, state.id)
            assert.are.equal("SIGx9/=aa==", loaded.messages[2].content[1].signature)
            assert.are.equal("reasoning…", loaded.messages[2].content[1].thinking)
        end)

        it("serializes an empty content list as [] and reloads it as a resendable array", function()
            local state = mkState("Q")
            -- A plain empty Lua table is ambiguous in JSON; the wire format needs [].
            state.messages[2].content = {}
            Chats.save(ui, state)
            assert.is_not_nil(readFile(base .. "/" .. state.id .. ".json"):find('"content":[]', 1, true))
            local loaded = Chats.load(ui, state.id)
            local content = loaded.messages[2].content
            assert.are.equal(0, #content)
            -- Re-encoding (what buildBody does on the first follow-up) must yield
            -- an array, or the gateway 400s the resend.
            assert.are.equal("[]", json.encode(content))
        end)
    end)

    describe("delete/clear/prune", function()
        it("deletes one chat, leaving the others untouched", function()
            local a, b = mkState("A"), mkState("B")
            Chats.save(ui, a)
            Chats.save(ui, b)
            Chats.delete(ui, a.id)
            local rows = Chats.list(ui)
            assert.are.equal(1, #rows)
            assert.are.equal(b.id, rows[1].id)
            assert.is_nil(Chats.load(ui, a.id))
            assert.is_not_nil(Chats.load(ui, b.id))
        end)

        it("clears all chats for the book", function()
            Chats.save(ui, mkState("A"))
            Chats.save(ui, mkState("B"))
            Chats.clear(ui)
            assert.are.same({}, Chats.list(ui))
        end)

        it("evicts the oldest chats past the cap, never the just-saved one", function()
            local states = {}
            for i = 1, 4 do
                states[i] = mkState("Q" .. i)
                Chats.save(ui, states[i])
            end
            -- Make the just-saved 4th chat the OLDEST by timestamp: prune must
            -- still keep it (the keep_id pin), and evict the next-oldest instead.
            setIndexTimes({
                [states[1].id] = 400,
                [states[2].id] = 100,
                [states[3].id] = 300,
                [states[4].id] = 50,
            })
            Chats.prune(ui, 3, states[4].id)
            local kept = {}
            for _, row in ipairs(Chats.list(ui)) do
                kept[row.id] = true
            end
            assert.are.equal(3, #Chats.list(ui))
            assert.is_true(kept[states[4].id]) -- just-saved survives despite oldest ts
            assert.is_nil(kept[states[2].id]) -- oldest of the rest evicted
            assert.is_nil(Chats.load(ui, states[2].id)) -- payload gone too, not just the entry
        end)

        it("saving past the cap prunes through the threaded max_chats", function()
            local first = mkState("first")
            Chats.save(ui, first, 2)
            local second = mkState("second")
            Chats.save(ui, second, 2)
            setIndexTimes({ [first.id] = 100, [second.id] = 200 })
            local third = mkState("third")
            Chats.save(ui, third, 2)
            local rows = Chats.list(ui)
            assert.are.equal(2, #rows)
            local kept = {}
            for _, row in ipairs(rows) do
                kept[row.id] = true
            end
            assert.is_true(kept[third.id])
            assert.is_nil(kept[first.id])
        end)
    end)

    describe("title and relative time", function()
        it("derives the title from the first user question, codepoint-safe", function()
            local long = string.rep("é", 70) -- 2-byte codepoints: a byte-based cut would split one
            local t = Chats.title({ transcript = { { role = "user", text = long } } })
            assert.are.equal(60 * 2 + 3, #t) -- 60 chars + one 3-byte ellipsis
            assert.is_not_nil(t:find("…$"))
        end)

        it("collapses whitespace and falls back when there is no question", function()
            local t = Chats.title({ transcript = { { role = "user", text = "a\nmulti  line\tq" } } })
            assert.are.equal("a multi line q", t)
            assert.are.equal("Untitled chat", Chats.title({ transcript = {} }))
        end)

        it("renders relative times", function()
            local now = 1000000
            assert.are.equal("just now", Chats.relativeTime(now - 30, now))
            assert.are.equal("5 min ago", Chats.relativeTime(now - 300, now))
            assert.are.equal("2 h ago", Chats.relativeTime(now - 7200, now))
            assert.are.equal("3 d ago", Chats.relativeTime(now - 3 * 86400, now))
            assert.is_not_nil(Chats.relativeTime(now - 30 * 86400, now):match("^%d%d%d%d%-%d%d%-%d%d$"))
        end)
    end)
end)
