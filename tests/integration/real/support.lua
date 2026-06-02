-- luacheck: globals disable_plugins
-- Shared scaffolding for the Tier 2 real-crengine specs (tests/integration/real/
-- *_real.lua, run by `nix run .#test-real`). This file is NOT a *_real.lua spec,
-- so busted's --pattern=_real discovery skips it; specs pull it in by short path
-- (LUA_PATH carries $PLUGIN_DIR/?.lua, so require("tests.integration.real.support")
-- resolves). It centralises the open-a-real-ReaderUI-over-juliet.epub dance the
-- smoke spec first established, so each spec's setup() is one call.
--
-- (disable_plugins is a global injected by koreader's commonrequire.)

local M = {}

-- juliet.epub: the hermetic flake harness points BB_SAMPLE_EPUB at the test-data
-- store path; the in-tree emulator layout is the fallback.
M.sample_epub = os.getenv("BB_SAMPLE_EPUB") or "spec/front/unit/data/juliet.epub"

-- Open a fresh real ReaderUI over an epub with real crengine and return
-- (readerui, Tools). epub_path is optional; it defaults to M.sample_epub (the
-- BB_SAMPLE_EPUB / in-tree juliet.epub), so existing no-arg callers are unaffected
-- while the Tier-3 driver can select a book per scenario. commonrequire/
-- disable_plugins mutate package.loaded, so they run lazily here rather than at
-- module load.
function M.open_book(epub_path)
    require("commonrequire")
    disable_plugins()
    local DocumentRegistry = require("document/documentregistry")
    local ReaderUI = require("apps/reader/readerui")
    local Screen = require("device").screen
    local Tools = require("bbtools")
    local readerui = ReaderUI:new({
        dimen = Screen:getSize(),
        document = DocumentRegistry:openDocument(epub_path or M.sample_epub),
    })
    return readerui, Tools
end

function M.close_book(readerui)
    readerui:closeDocument()
    readerui:onClose()
end

-- Annotations persist to the book's .sdr sidecar under the shared KO_HOME, so a
-- second open_book() of juliet.epub in the same run loads whatever an earlier
-- describe saved. Highlight specs that assert on counts call this in setup() to
-- start from a genuinely empty slate, independent of suite order.
function M.reset_annotations(readerui)
    if readerui.annotation then
        readerui.annotation.annotations = {}
    end
end

-- The reader's current 1-based page, read back through book_context (the same
-- path the model sees), so navigation assertions check the real, post-move state.
function M.current_page(Tools, readerui)
    local text = Tools.execute("book_context", {}, readerui)
    return tonumber(text:match("Current page:%s*(%d+)"))
end

return M
