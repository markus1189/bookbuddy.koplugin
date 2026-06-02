-- Tier 3 fixture generator (.plans/tier3-promptfoo.md): snapshot a .sdr sidecar
-- from the REAL crengine/annotation/memory stack, so promptfoo scenarios can open
-- a book that already has highlights, notes, and BookBuddy memory.
--
-- WHY snapshot instead of hand-writing metadata.<ext>.lua: annotation xpointers
-- (pos0/pos1) are crengine-layout-dependent and the on-disk schema is KOReader's,
-- not ours. Generating against the same pinned epub + koreader the eval uses keeps
-- the fixture faithful; regenerate when either is bumped (same rule as the page
-- anchors). The produced fixture is therefore valid ONLY against that pinned pair.
--
-- Run via `nix run .#eval-seed` (no API key; needs the koreader runtime env, like
-- the driver). Inputs: arg[1] or BB_SAMPLE_EPUB = the book; BB_FIXTURE_OUT = the
-- destination .sdr directory (e.g. tests/eval/fixtures/juliet.sdr); BB_SEED_RECIPE
-- selects which recipe to apply (default inferred from the epub's bare name).

local lfs = require("libs/libkoreader-lfs")
lfs.mkdir(os.getenv("KO_HOME") or ".")
require("ffi/loadlib")

local out_dir = os.getenv("BB_FIXTURE_OUT")
assert(out_dir and out_dir ~= "", "BB_FIXTURE_OUT (destination .sdr dir) must be set")

local epub = (arg and arg[1] ~= "" and arg[1]) or os.getenv("BB_SAMPLE_EPUB")
assert(epub and epub ~= "", "pass an epub as arg[1] or set BB_SAMPLE_EPUB")

local support = require("tests.integration.real.support")
-- Open the real epub directly. The test env's "dir" sidecar location keeps the
-- sidecar under KO_HOME/docsettings (writable) keyed on the epub's absolute path,
-- so we start from an empty sidecar and populate it in place — no epub copy.
local readerui, Tools = support.open_book(epub)

-- A recipe is a list of steps run in order against the open book. grep uses
-- spoiler=true (we are authoring, not reading), so early-page passages resolve
-- regardless of the reader position. create_highlight{search_result=1} consumes
-- the immediately-preceding grep, so each highlight is grep-then-create.
local RECIPES = {
    -- juliet.epub (Romeo and Juliet): two Prologue highlights — one annotated, one
    -- bare (so edit_highlight_note has something to add a note to) — plus a memory
    -- note recording a prior conversation's reader profile.
    juliet = {
        highlights = {
            { query = "In fair Verona", note = "The Chorus sets the scene in Verona." },
            { query = "ancient grudge" }, -- bare highlight, no note
        },
        memory = {
            {
                path = "/memories/reader_profile.md",
                file_text = "# Reader profile\n\n"
                    .. "The reader is reading Romeo and Juliet for the first time.\n"
                    .. "They are tracking the imagery of light and dark, and asked to be\n"
                    .. "reminded about the Chorus/Prologue framing device.\n",
            },
        },
    },
}

local recipe_name = os.getenv("BB_SEED_RECIPE")
if not recipe_name or recipe_name == "" then
    recipe_name = epub:match("([^/]+)%.[%w]+$") or "juliet"
end
local recipe = RECIPES[recipe_name]
assert(recipe, "no seed recipe named " .. tostring(recipe_name))

for _, h in ipairs(recipe.highlights or {}) do
    local found = Tools.execute("grep", { query = h.query, spoiler = true }, readerui)
    assert(found:match("page"), "seed grep found no hit for " .. h.query .. ": " .. tostring(found))
    local res = Tools.execute("create_highlight", { search_result = 1, note = h.note }, readerui)
    assert(res:match("Highlighted"), "seed create_highlight failed for " .. h.query .. ": " .. tostring(res))
    io.write("  + highlight: ", h.query, h.note and (" (note)") or "", "\n")
end

if recipe.memory and #recipe.memory > 0 then
    local Memory = require("bbmemory")
    local base = Memory.baseDirForBook(readerui)
    assert(base, "no resolvable memory dir for this book")
    local store = Memory.new(base)
    for _, m in ipairs(recipe.memory) do
        local res = store:execute({ command = "create", path = m.path, file_text = m.file_text })
        assert(res:match("created successfully"), "seed memory create failed: " .. tostring(res))
        io.write("  + memory: ", m.path, "\n")
    end
end

-- Flush annotations to the sidecar while the document is still live (saveSettings
-- fires SaveSettings -> ReaderAnnotation:onSaveSettings -> doc_settings:flush()).
readerui:saveSettings()

-- Resolve where DocSettings actually wrote (the "dir" location embeds the epub's
-- absolute path under KO_HOME/docsettings); snapshot THAT directory.
local sidecar = support.sidecar_dir(epub)
assert(lfs.attributes(sidecar, "mode") == "directory", "expected populated sidecar at " .. sidecar)

assert(
    os.execute(string.format("rm -rf %q && mkdir -p %q && cp -rL %q/. %q/", out_dir, out_dir, sidecar, out_dir)),
    "failed to copy sidecar to BB_FIXTURE_OUT"
)
io.write("==> wrote fixture ", recipe_name, " -> ", out_dir, "\n")

pcall(support.close_book, readerui)
