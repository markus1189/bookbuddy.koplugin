-- Filesystem-backed store for Anthropic's client-side memory tool.
--
-- The model issues `memory` tool_use blocks with a `command` over a virtual
-- `/memories` directory; we execute them against a real per-book directory on
-- disk and return the protocol's result strings (kept verbatim so the model
-- recognizes them — these are NOT translated). Storage lives in the open book's
-- sidecar (.sdr) directory, so memory travels with the book (e.g. via Syncthing)
-- and is naturally isolated per book.
--
-- Security: the model only ever names paths under /memories. `_resolve` refuses
-- anything outside that root and forbids `..`, so a tool call cannot reach files
-- outside the book's memory directory.
local DocSettings = require("docsettings")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local ffiUtil = require("ffi/util")
local _ = require("gettext")
local T = ffiUtil.template

local VIRTUAL_ROOT = "/memories"
local VIEW_MAX_DEPTH = 2
local MAX_LINES = 999999

local Memory = {}

-- Tool declaration, shaped like the bare server-tool entries in bbtools (no
-- input_schema — the type implies it).
function Memory.spec()
    return { type = "memory_20250818", name = "memory" }
end

-- Human label for the open book, for the management UI header.
function Memory.bookLabel(ui)
    local doc = ui and ui.document
    local props = (doc and doc.getProps and doc:getProps()) or {}
    local file = doc and doc.file
    local title = props.title
    if (not title or title == "") and file then
        title = ffiUtil.basename(file)
    end
    return title or _("this book")
end

-- Memory lives in the open book's sidecar directory, following KOReader's own
-- sidecar-location setting (by default the .sdr next to the book, which syncs).
-- Returns nil when there is no resolvable sidecar (e.g. no open file), in which
-- case the caller skips memory entirely.
function Memory.baseDirForBook(ui)
    local file = ui and ui.document and ui.document.file
    local sdr = file and DocSettings:getSidecarDir(file)
    if not sdr or sdr == "" then
        return nil
    end
    return sdr .. "/bookbuddy_memory"
end

local Store = {}
Store.__index = Store

function Memory.new(base_dir)
    return setmetatable({ base_dir = base_dir }, Store)
end

-- Map a virtual /memories path to a real path inside base_dir, or return
-- (nil, error_string) refusing anything that escapes the root.
function Store:_resolve(vpath)
    if type(vpath) ~= "string" or vpath == "" or vpath:find("\0", 1, true) then
        return nil, "Error: invalid path."
    end
    local rest
    if vpath == VIRTUAL_ROOT then
        rest = ""
    elseif vpath:sub(1, #VIRTUAL_ROOT + 1) == VIRTUAL_ROOT .. "/" then
        rest = vpath:sub(#VIRTUAL_ROOT + 2)
    else
        return nil, T("Error: path %1 must be within /memories.", vpath)
    end
    local segs = {}
    for seg in rest:gmatch("[^/]+") do
        if seg == ".." then
            return nil, "Error: path may not contain '..'."
        elseif seg ~= "." then
            segs[#segs + 1] = seg
        end
    end
    if #segs == 0 then
        return self.base_dir
    end
    return self.base_dir .. "/" .. table.concat(segs, "/")
end

local function friendlySize(bytes)
    bytes = bytes or 0
    if bytes >= 1024 * 1024 then
        return string.format("%.1fM", bytes / 1024 / 1024)
    elseif bytes >= 1024 then
        return string.format("%.1fK", bytes / 1024)
    end
    return string.format("%dB", bytes)
end

local function splitLines(s)
    local lines = {}
    local pos, len = 1, #s
    while pos <= len do
        local nl = s:find("\n", pos, true)
        if nl then
            lines[#lines + 1] = s:sub(pos, nl - 1)
            pos = nl + 1
        else
            lines[#lines + 1] = s:sub(pos)
            pos = len + 1
        end
    end
    return lines
end

local function numberedRange(lines, from, to)
    local out = {}
    for i = from, to do
        if lines[i] ~= nil then
            out[#out + 1] = string.format("%6d\t%s", i, lines[i])
        end
    end
    return table.concat(out, "\n")
end

local function lineOfOffset(content, pos)
    local _, n = content:sub(1, pos - 1):gsub("\n", "")
    return n + 1
end

-- Recursively collect entries under a directory, up to VIEW_MAX_DEPTH levels.
local function collectTree(real_dir, vpath_dir, depth, acc)
    if depth > VIEW_MAX_DEPTH then
        return
    end
    local names = {}
    local ok, iter, dir_obj = pcall(lfs.dir, real_dir)
    if not ok then
        return
    end
    for name in iter, dir_obj do
        if name ~= "." and name ~= ".." and name:sub(1, 1) ~= "." and name ~= "node_modules" then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    for _, name in ipairs(names) do
        local rp = real_dir .. "/" .. name
        local vp = vpath_dir .. "/" .. name
        local attr = lfs.attributes(rp) or {}
        acc[#acc + 1] = { vpath = vp, size = attr.size or 0 }
        if attr.mode == "directory" then
            collectTree(rp, vp, depth + 1, acc)
        end
    end
end

function Store:_view(input)
    local vpath = input.path or VIRTUAL_ROOT
    local real, err = self:_resolve(vpath)
    if not real then
        return err
    end
    if real == self.base_dir then
        util.makePath(self.base_dir)
    end
    local mode = lfs.attributes(real, "mode")
    if not mode then
        return T("The path %1 does not exist. Please provide a valid path.", vpath)
    end
    if mode == "directory" then
        local lines = {
            T(
                "Here're the files and directories up to 2 levels deep in %1, excluding hidden items and node_modules:",
                vpath
            ),
            friendlySize(lfs.attributes(real, "size")) .. "\t" .. vpath,
        }
        local acc = {}
        collectTree(real, vpath, 1, acc)
        for _, e in ipairs(acc) do
            lines[#lines + 1] = friendlySize(e.size) .. "\t" .. e.vpath
        end
        return table.concat(lines, "\n")
    end
    local content = util.readFromFile(real) or ""
    local lines = splitLines(content)
    if #lines > MAX_LINES then
        return T("File %1 exceeds maximum line limit of 999,999 lines.", vpath)
    end
    local from, to = 1, #lines
    local range = input.view_range
    if type(range) == "table" and range[1] then
        from = math.max(1, math.floor(range[1]))
        to = range[2] and math.min(#lines, math.floor(range[2])) or #lines
    end
    return T("Here's the content of %1 with line numbers:", vpath) .. "\n" .. numberedRange(lines, from, to)
end

function Store:_create(input)
    local vpath = input.path
    local real, err = self:_resolve(vpath)
    if not real then
        return err
    end
    if lfs.attributes(real, "mode") ~= nil then
        return T("Error: File %1 already exists", vpath)
    end
    util.makePath(ffiUtil.dirname(real))
    local ok, werr = util.writeToFile(input.file_text or "", real)
    if not ok then
        return T("Error: could not create %1: %2", vpath, tostring(werr))
    end
    return T("File created successfully at: %1", vpath)
end

function Store:_strReplace(input)
    local vpath = input.path
    local real, err = self:_resolve(vpath)
    if not real then
        return err
    end
    if lfs.attributes(real, "mode") ~= "file" then
        return T("Error: The path %1 does not exist. Please provide a valid path.", vpath)
    end
    local old_str = input.old_str
    local new_str = input.new_str or ""
    local content = util.readFromFile(real) or ""
    if not old_str or old_str == "" then
        return T("No replacement was performed, old_str `%1` did not appear verbatim in %2.", tostring(old_str), vpath)
    end
    local positions = {}
    local idx = 1
    while true do
        local s_, e_ = content:find(old_str, idx, true)
        if not s_ then
            break
        end
        positions[#positions + 1] = s_
        idx = e_ + 1
    end
    if #positions == 0 then
        return T("No replacement was performed, old_str `%1` did not appear verbatim in %2.", old_str, vpath)
    end
    if #positions > 1 then
        local nums = {}
        for _, pos in ipairs(positions) do
            nums[#nums + 1] = tostring(lineOfOffset(content, pos))
        end
        return T(
            "No replacement was performed. Multiple occurrences of old_str `%1` in lines: %2. Please ensure it is unique",
            old_str,
            table.concat(nums, ", ")
        )
    end
    local at = positions[1]
    local new_content = content:sub(1, at - 1) .. new_str .. content:sub(at + #old_str)
    local ok, werr = util.writeToFile(new_content, real)
    if not ok then
        return T("Error: could not write %1: %2", vpath, tostring(werr))
    end
    local center = lineOfOffset(new_content, at)
    local snippet = numberedRange(splitLines(new_content), math.max(1, center - 4), center + 4)
    return "The memory file has been edited.\n" .. snippet
end

function Store:_insert(input)
    local vpath = input.path
    local real, err = self:_resolve(vpath)
    if not real then
        return err
    end
    if lfs.attributes(real, "mode") ~= "file" then
        return T("Error: The path %1 does not exist", vpath)
    end
    local content = util.readFromFile(real) or ""
    local had_trailing_nl = content:sub(-1) == "\n"
    local lines = splitLines(content)
    local n = #lines
    local insert_line = tonumber(input.insert_line)
    if not insert_line or insert_line < 0 or insert_line > n then
        return T(
            "Error: Invalid `insert_line` parameter: %1. It should be within the range of lines of the file: [0, %2]",
            tostring(input.insert_line),
            tostring(n)
        )
    end
    local text = input.insert_text or ""
    if text:sub(-1) == "\n" then
        text = text:sub(1, -2)
    end
    local ins = splitLines(text)
    if #ins == 0 then
        ins = { "" }
    end
    local result = {}
    for i = 1, insert_line do
        result[#result + 1] = lines[i]
    end
    for i = 1, #ins do
        result[#result + 1] = ins[i]
    end
    for i = insert_line + 1, n do
        result[#result + 1] = lines[i]
    end
    local new_content = table.concat(result, "\n")
    if had_trailing_nl or content == "" then
        new_content = new_content .. "\n"
    end
    local ok, werr = util.writeToFile(new_content, real)
    if not ok then
        return T("Error: could not write %1: %2", vpath, tostring(werr))
    end
    return T("The file %1 has been edited.", vpath)
end

function Store:_delete(input)
    local vpath = input.path
    local real, err = self:_resolve(vpath)
    if not real then
        return err
    end
    local mode = lfs.attributes(real, "mode")
    if not mode then
        return T("Error: The path %1 does not exist", vpath)
    end
    if mode == "directory" then
        ffiUtil.purgeDir(real)
    else
        os.remove(real)
    end
    return T("Successfully deleted %1", vpath)
end

function Store:_rename(input)
    local old_vpath, new_vpath = input.old_path, input.new_path
    local old_real, oerr = self:_resolve(old_vpath)
    if not old_real then
        return oerr
    end
    local new_real, nerr = self:_resolve(new_vpath)
    if not new_real then
        return nerr
    end
    if lfs.attributes(old_real, "mode") == nil then
        return T("Error: The path %1 does not exist", old_vpath)
    end
    if lfs.attributes(new_real, "mode") ~= nil then
        return T("Error: The destination %1 already exists", new_vpath)
    end
    util.makePath(ffiUtil.dirname(new_real))
    local ok, rerr = os.rename(old_real, new_real)
    if not ok then
        return T("Error: could not rename %1: %2", old_vpath, tostring(rerr))
    end
    return T("Successfully renamed %1 to %2", old_vpath, new_vpath)
end

local DISPATCH = {
    view = Store._view,
    create = Store._create,
    str_replace = Store._strReplace,
    insert = Store._insert,
    delete = Store._delete,
    rename = Store._rename,
}

-- Run one memory tool_use; always returns a plain string for the tool_result.
function Store:execute(input)
    input = input or {}
    local fn = DISPATCH[input.command]
    if not fn then
        return "Error: unknown memory command " .. tostring(input.command)
    end
    local ok, res = pcall(fn, self, input)
    if not ok then
        return "Error: memory operation failed: " .. tostring(res)
    end
    return res or ""
end

-- User-facing summary of this book's stored memory, for the menu.
function Memory.summaryText(ui)
    local base = Memory.baseDirForBook(ui)
    local header = T(_("Memory for this book: %1"), Memory.bookLabel(ui))
    if not base or not util.directoryExists(base) then
        return header .. "\n\n" .. _("(no memory stored yet)")
    end
    local files = {}
    util.findFiles(base, function(path)
        files[#files + 1] = path
    end, true)
    table.sort(files)
    if #files == 0 then
        return header .. "\n\n" .. _("(no memory stored yet)")
    end
    local out = { header, "" }
    for _, path in ipairs(files) do
        out[#out + 1] = "### " .. VIRTUAL_ROOT .. "/" .. path:sub(#base + 2)
        out[#out + 1] = util.readFromFile(path) or ""
        out[#out + 1] = ""
    end
    return table.concat(out, "\n")
end

-- Returns true if this book has any stored memory.
function Memory.hasContent(ui)
    local base = Memory.baseDirForBook(ui)
    return base ~= nil and util.directoryExists(base) and not util.isEmptyDir(base)
end

-- Delete this book's memory directory.
function Memory.clear(ui)
    local base = Memory.baseDirForBook(ui)
    if base and util.directoryExists(base) then
        return ffiUtil.purgeDir(base)
    end
    return true
end

return Memory
