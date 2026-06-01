-- bbmemory against a REAL on-disk Store in a temp dir. Exercises _resolve's
-- sandboxing (the security boundary) and the view/create/str_replace/insert/
-- delete/rename commands end to end. Construct the Store directly via Memory.new
-- to bypass baseDirForBook(ui), the only KOReader-coupled entry point.
local lfs = require("lfs")

-- Minimal real implementations of the KOReader file helpers bbmemory leans on.
local function makePath(path)
    local cur = ""
    for seg in path:gmatch("[^/]+") do
        cur = cur .. "/" .. seg
        lfs.mkdir(cur)
    end
    return true
end
local function readFromFile(path)
    local f = io.open(path, "rb")
    if not f then
        return nil
    end
    local c = f:read("*a")
    f:close()
    return c
end
local function writeToFile(content, path)
    local f, err = io.open(path, "wb")
    if not f then
        return false, err
    end
    f:write(content)
    f:close()
    return true
end
local function dirname(path)
    return path:match("^(.*)/[^/]*$") or "."
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

describe("bbmemory Store", function()
    local Memory

    setup(function()
        package.loaded["libs/libkoreader-lfs"] = lfs
        package.loaded["docsettings"] = {} -- only baseDirForBook touches it; untested here
        package.loaded["gettext"] = function(s)
            return s
        end
        package.loaded["util"] = {
            makePath = makePath,
            readFromFile = readFromFile,
            writeToFile = writeToFile,
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
            dirname = dirname,
            purgeDir = purgeDir,
        }
        Memory = require("bbmemory")
    end)

    local base, store
    before_each(function()
        -- A fresh empty temp dir per test (os.tmpname gives a file; reuse the name
        -- as our store root, created lazily by the Store on first write/view).
        base = os.tmpname()
        os.remove(base)
        store = Memory.new(base)
    end)
    after_each(function()
        if base and lfs.attributes(base, "mode") == "directory" then
            purgeDir(base)
        end
    end)

    describe("_resolve sandboxing", function()
        it("maps the virtual root to the base dir", function()
            assert.are.equal(base, store:_resolve("/memories"))
        end)

        it("maps a nested path under the base dir", function()
            assert.are.equal(base .. "/notes/a.md", store:_resolve("/memories/notes/a.md"))
        end)

        it("refuses paths outside /memories", function()
            local real, err = store:_resolve("/etc/passwd")
            assert.is_nil(real)
            assert.is_not_nil(err)
        end)

        it("refuses traversal with ..", function()
            local real, err = store:_resolve("/memories/../escape")
            assert.is_nil(real)
            assert.is_not_nil(err:find("'%.%.'"))
        end)

        it("refuses an empty path or an embedded NUL", function()
            assert.is_nil((store:_resolve("")))
            assert.is_nil((store:_resolve("/memories/a\0b")))
        end)
    end)

    describe("command lifecycle", function()
        it("creates, views, edits, inserts, renames and deletes a note", function()
            -- create
            local r = store:execute({ command = "create", path = "/memories/a.md", file_text = "hello\nworld" })
            assert.is_not_nil(r:find("File created successfully", 1, true))

            -- view file (numbered) and view root (listing)
            assert.is_not_nil(store:execute({ command = "view", path = "/memories/a.md" }):find("hello", 1, true))
            assert.is_not_nil(store:execute({ command = "view", path = "/memories" }):find("a.md", 1, true))

            -- str_replace
            assert.is_not_nil(
                store
                    :execute({ command = "str_replace", path = "/memories/a.md", old_str = "hello", new_str = "hi" })
                    :find("has been edited", 1, true)
            )
            assert.is_not_nil(store:execute({ command = "view", path = "/memories/a.md" }):find("hi", 1, true))

            -- insert a line at the top
            assert.is_not_nil(
                store
                    :execute({ command = "insert", path = "/memories/a.md", insert_line = 0, insert_text = "TITLE" })
                    :find("has been edited", 1, true)
            )

            -- rename then delete
            assert.is_not_nil(
                store
                    :execute({ command = "rename", old_path = "/memories/a.md", new_path = "/memories/b.md" })
                    :find("Successfully renamed", 1, true)
            )
            assert.is_not_nil(
                store:execute({ command = "delete", path = "/memories/b.md" }):find("Successfully deleted", 1, true)
            )
        end)

        it("refuses to create over an existing file", function()
            store:execute({ command = "create", path = "/memories/dup.md", file_text = "x" })
            assert.is_not_nil(
                store
                    :execute({ command = "create", path = "/memories/dup.md", file_text = "y" })
                    :find("already exists", 1, true)
            )
        end)

        it("refuses a non-unique str_replace", function()
            store:execute({ command = "create", path = "/memories/m.md", file_text = "dup dup" })
            local r =
                store:execute({ command = "str_replace", path = "/memories/m.md", old_str = "dup", new_str = "x" })
            assert.is_not_nil(r:find("Multiple occurrences", 1, true))
        end)

        it("reports an unknown command", function()
            assert.is_not_nil(store:execute({ command = "frobnicate" }):find("unknown memory command", 1, true))
        end)

        it("routes a _resolve error through execute (path outside /memories)", function()
            local r = store:execute({ command = "view", path = "/outside.md" })
            assert.is_not_nil(r:find("within /memories", 1, true))
        end)
    end)
end)
