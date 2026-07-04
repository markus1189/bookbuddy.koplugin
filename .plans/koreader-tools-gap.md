# Missing high-value tools: what KOReader exposes that BookBuddy doesn't use

Research against koreader/koreader `master` (2026-07-04), cross-checked with the current
tool surface in `bbtools.lua` / `bbmemory.lua`. Line-ish anchors are approximate against
master on that date.

## Current tool surface (baseline)

`grep`, `read`, `get_toc`, `book_context`, `get_highlights`, `create_highlight`,
`edit_highlight_note`, `navigate`, `memory`, `web_search` (server-side), `delegate`,
`ask_user`.

Everything below is a capability KOReader already ships that none of these reach.

## Constraints that shaped the ranking

- Tool executors run **synchronously in the main process** and return a string
  (`bbtools.lua` header comment). A long-blocking call freezes the reader UI, so
  network-backed tools need timeouts and an offline check; the LLM call itself is the
  only thing that runs in the forked subprocess.
- **Spoiler safety** is the product's core promise; each candidate is assessed for it.
- The gateway problem that forced `memory` to be a custom tool (see `bbmemory.lua`)
  applies to `web_search` too: server-side tools only work on Anthropic-compatible
  backends. Client-side lookup tools (dictionary/Wikipedia/translate) work everywhere.

---

## Tier A — high value, low effort, fully headless

### 1. `define` — dictionary lookup (offline, StarDict)

The single biggest gap. KOReader's whole dictionary stack is reachable headlessly:

- `ui.dictionary:startSdcv(word, dict_names, fuzzy_search)`
  (`frontend/apps/reader/modules/readerdictionary.lua` ~L1339) returns a flat array of
  `{ dict, word, definition }` with **no widget and no network** — sdcv runs over the
  user's locally installed dictionaries. Pass
  `ui.dictionary.enabled_dict_names` to respect the user's dictionary config, and
  pre-clean input with the public `ui.dictionary:cleanSelection(text)` (~L1088).
- Called outside a `Trapper:wrap` coroutine, the underlying
  `Trapper:dismissablePopen` falls back to blocking `io.popen` (trapper.lua ~L341) —
  exactly right for a synchronous executor.

Why it matters: "what does this word mean (in this dictionary/in context)" is *the*
e-reader question; the agent currently has to guess or burn a web_search. Spoiler-safe by
construction. Gotchas: `startSdcv` returns raw sdcv output (HTML for `h`-type dicts —
strip tags lightly; the cleanup helper `tidyMarkup` is module-local), fuzzy search on
garbage can take ~10 s uninterruptible, and bypassing `stardictLookup` means no
`WordLookedUp` event — i.e. agent lookups don't pollute lookup history or auto-feed the
vocabulary builder (arguably correct).

### 2. `reading_stats` — pace and time-to-finish (statistics plugin)

The footer already answers "how long left in this chapter"; the agent can't. All data is
reachable via `ui.statistics` (nil if the plugin is disabled — degrade gracefully):

- `getStatsBookStatus()` → `{ days, time, pages }` for the current book (numbers).
- `avg_time` field (seconds/page) + `ui.toc:getChapterPagesLeft(pageno, true)` and
  `ui.document:getTotalPagesLeft(pageno)` → estimated time left in chapter/book —
  the exact computation `readerfooter.lua` (~L322) uses via `getTimeForPages(n)`.
- `getTodayBookStats()`, `getCurrentBookStats()` → today/session numbers.
- Period queries return plain tables: `getBooksFromPeriod(begin, end)` ("what did I
  read this month"), `getDatesForBook(id_book)`.
- DB direct (read-only, WAL-safe): `settings/statistics.sqlite3`, tables `book` /
  `page_stat_data`, view `page_stat` (rescaled to current page count — query the view).

Gotchas: call `ui.statistics:insertDB()` first or the live session is missing from the
DB; `rowexec` returns cdata int64 (`tonumber()`); NaN-check `avg_time` for unread books;
prefer the numeric methods over `getCurrentStat()`/`getBookStat()` whose values are
pre-formatted display strings. Spoiler-safe. Pairs beautifully with a "give me a
pep-talk / should I start the next chapter tonight?" conversational flow.

### 3. Enrich `book_context` (near-zero effort)

`getProps()` (frontend/document/document.lua) already returns fields BookBuddy drops:
**`description`** (publisher blurb — excellent grounding), **`language`**, `keywords`,
`series_index`, `identifiers`. Also cheap to add:

- Chapter breadcrumb: `ui.toc:getFullTocTitleByPage(pn)` (full hierarchy, not just the
  leaf title).
- Print-edition page labels when the EPUB has a page map:
  `ui.document:hasPageMap()` / `getPageMapCurrentPageLabel()` /
  `ui.pagemap:getCurrentPageLabel(clean)` — lets the agent (and reader) speak in "real
  book" page numbers.
- Progress guards for spoiler math: `hasNonLinearFlows()` / `getLastLinearPage()` so
  "pages left" doesn't count endnotes.
- Book status/rating: `ui.doc_settings:readSetting("summary")` →
  `{ status = "reading"|"abandoned"|"complete", rating, note }`.

### 4. `bookmarks` — list + create bare page bookmarks

`highlightList()` in bbtools.lua deliberately **skips** bare page bookmarks, and there is
no way to create one. KOReader side:

- Discriminator: annotations without `drawer`/`pos0` are page bookmarks;
  `ui.bookmark:getBookmarkType(bm)` → `"bookmark"|"highlight"|"note"`.
- Create at current page: `ui.bookmark:onToggleBookmark()` (keeps dogear + footer
  consistent); query with `isPageBookmarked`, `getBookmarkedPages()`,
  `getNextBookmarkedPage()` etc. (readerbookmark.lua).

Value: "dog-ear this page", "take me to my last bookmark" — natural companions to
`navigate`. Non-destructive (toggle needs care: only create, never un-toggle silently).

---

## Tier B — high value, medium effort

### 5. `read` (and `create_highlight`) on PDFs — kill the EPUB-only limitation

Today `read`, `create_highlight`, and locators are reflowable-only. mupdf-backed docs
expose per-page text with word boxes:

- `PdfDocument:getPageTextBoxes(pageno)` (pdfdocument.lua ~L101, cached) →
  `boxes[line][word] = {x0,y0,x1,y1, word}`; joining words per line yields the page's
  full text. `Document:getPageText(pageno)` (document.lua ~L594) is the uncached base.
- `koptinterface.getTextFromPositions` / `getWordFromPosition` give pboxes for
  highlight creation on paging docs (the missing pos-table path noted in
  `tool_create_highlight`'s comment).

A page-granular `read` for PDFs (page N → text, spoiler-gate on page number) is
straightforward; grep already works there via `findAllText`. Gotcha: scanned PDFs
return empty native boxes and fall back to slow Tesseract OCR — detect empty results
and say so rather than blocking.

### 6. `wikipedia` — client-side encyclopedia lookup

`frontend/ui/wikipedia.lua` is a plain singleton, no UI:

- `pcall(Wikipedia.searchAndGetIntros, Wikipedia, text, lang)` → `query.pages` keyed by
  pageid (string keys; sort by `page.index`), each with plain-text `extract`.
- `pcall(Wikipedia.getFullPage, Wikipedia, title, lang)` → whole article plain text.
- Language pick: mirror `ReaderWikipedia` fallbacks (`wikipedia_languages` setting →
  book language → UI language → `"en"`).

Why alongside `web_search`: it is client-side (works on any gateway where server-side
`web_search_20250305` doesn't), free, and returns clean plain text. Blocking network
(20 s timeout / 60 s max — don't set a trap widget); check `NetworkMgr:isOnline()` and
return an error string offline. Spoiler note: same exposure as web_search — plot
sections can spoil; the system prompt's spoiler rule already governs what the agent
relays.

### 7. `translate` — passage translation

`require("ui/translator")`, no `ui` needed: `Translator:translate(text, target, source)`
→ string (nil on failure); `Translator:detect(text)` → lang code. Defaults pick target
from settings/UI language and source from the book's language. Uses the unofficial free
Google endpoint (`client=gtx` is load-bearing; can throttle/break without notice —
worth a comment if implemented). Blocking network; same offline handling as Wikipedia.
High value for readers of foreign-language books; spoiler-safe (operates on text the
agent already has).

### 8. `vocabulary` — the reader's saved words

Vocabulary builder stores words in `settings/vocabulary_builder.sqlite3`
(`vocabulary(word PK, title_id, create_time, review_time, due_time, review_count,
prev_context, next_context, streak_count, highlight)` + `title(id, name UNIQUE)`).
The plugin's `db.lua` isn't require-able from outside, but the schema is stable — query
directly (read-only), joining `title.name` against `ui.doc_props.display_title`.

- Read tool: "list my saved words for this book (with context)" → quiz/review flows,
  "explain the words I've been saving". Language-learner catnip.
- Write path exists but is awkward: `Event:new("WordLookedUp", word, title, is_manual)`
  can pop a dialog when the word exists; a direct insert mirroring `insertOrUpdate`
  (`due_time = time + 300`) is the clean headless route. Note `word` is globally
  UNIQUE across books — re-saving rebinds it and resets the streak. Suggest read-only
  first.

### 9. Cross-book tools — history, series, other books' highlights

All headless, no document open needed:

- `require("readhistory").hist` — newest-first `{ time, file, text }` of previously
  opened books.
- `BookList.getBookInfo(file)` (frontend/ui/widget/booklist.lua) →
  `{ been_opened, status, rating, pages, has_annotations, percent_finished }`.
- `DocSettings:open(path):readSetting("annotations")` — **another book's highlights and
  notes** without opening it (each entry: text, note, chapter, pageno, datetime).
  `readSetting("summary")` → its status/rating/review; `"doc_props"` → metadata.
- `ReadCollection` (frontend/readcollection.lua) — collections/favorites, all plain
  tables.
- CoverBrowser's metadata cache (`settings/bookinfo_cache.sqlite3`, or
  `ui.coverbrowser.getDocProps(file)`) for cheap title/author/series of arbitrary
  library files.

Enables: "what did I highlight in book 1 of this series?", "have I read anything else
by this author?", "which book was I reading last month?". This is the strongest
*differentiating* feature in the list — no other reading assistant has the reader's
whole KOReader library. Two cautions: (a) privacy — it sends other books' titles/notes
to the API, so it should probably be a settings-gated tool like subagents; (b) don't
flush `DocSettings` objects opened read-only, and `BookList` caches go stale if sidecars
are edited behind its back.

### 10. `set_book_status` — mark finished / rate / review

Read side is trivial (item 3). Write side: mutate `summary` in `ui.doc_settings` the way
`ReaderStatus:markBook()` (readerstatus.lua ~L212) does, and keep the cache honest via
`BookList.setBookInfoCacheProperty(file, "status", status)`. "Mark this book finished
and note what I thought of it" is a nice end-of-book ritual with the memory tool
alongside. Overwriting an existing rating/review is destructive — follow the
`edit_highlight_note` precedent: append/only-set-when-empty, or confirm via `ask_user`.

---

## Tier C — niche, situational, or better as internal plumbing

- **Footnote following**: `getPageLinks()`, `isLinkToFootnote(src, tgt, flags, max)`,
  `getHTMLFromXPointers(xp0, xp1, flags)` — a `read_footnote` tool for
  endnote-heavy classics/annotated editions. Real value but a narrow audience;
  the HTML-to-text step and link-at-xpointer resolution make it fiddly.
- **`getDocumentFileContent(path)`** — raw access to any EPUB container member (chapter
  XHTML, OPF, NCX). Tempting as a fast whole-chapter read, but it bypasses the
  page-based spoiler gate entirely; if used at all, keep it internal (e.g. to speed up
  `delegate` sweeps) and re-impose the gate at the tool layer. Not a model-facing tool.
- **Exporter plugin** (`plugins/exporter.koplugin`): `exportFilesNotes(files)` is
  semi-headless (still posts InfoMessages, needs the plugin enabled). If "export my
  highlights as markdown" is wanted, serializing `ui.annotation.annotations` directly
  is simpler than reusing it.
- **Images/cover**: `getCoverPageImage()`, `getImageFromPosition()` return BlitBuffers;
  only useful once BookBuddy sends images to the model (vision) — different project.
- **Screenshot** (`Screen:shot(filename)`): no obvious agent story.
- **`getSelectedWordContext(word, n, pos0, pos1)`**: ±n words around a span — handy
  internally for richer grep snippets; not worth a standalone tool. Gotcha: the
  draw_selection/restore dance clobbers crengine's selection.

## Suggested order of attack

1. **`define`** (offline dictionary) — highest value-to-effort ratio in the list.
2. **`book_context` enrichment** (description/language/series_index/breadcrumb/page-map
   labels/status) — an afternoon, immediately improves grounding.
3. **`reading_stats`** — unique-to-e-reader value, pure data plumbing.
4. **PDF `read`** — removes the most-hit limitation of the current tool set.
5. **`vocabulary` (read-only) + `translate`** — the language-learning story.
6. **Cross-book history/series tools** — the differentiator, behind a settings gate.

Each Tier A/B tool slots into the existing pattern: a spec in `Tools.getSpecs()`, an
executor in `DISPATCH`, read-only ones whitelisted in `CHILD_TOOL_NAMES` for subagents
(define, reading_stats, vocabulary, wikipedia are natural child tools; mutators and
network tools stay parent-only per the existing D5/D6 rules — though wikipedia/translate
may deserve child access for research delegation, worth deciding explicitly).
