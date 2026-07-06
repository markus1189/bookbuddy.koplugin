# Persistent Sessions — C — Append-only event-log / journal with replay

**Status:** Complete implementation spec (build-from-this; no further design decisions).
**New modules:** `bbjournal.lua`, `bbwire.lua`.
**Touched files:** `bbconversation.lua`, `main.lua`, `bbsettings.lua`, `_meta.lua`.
**Gate:** `nix run .#check` (`stylua --check` + `luacheck` std=luajit + `busted`).

All load-bearing claims in this document were verified against source at
`/home/markus/repos/projects/bookbuddy.koplugin` on 2026-06-05:
- `Anthropic.buildBody` **mutates `messages[]` in place** (strips every block's `cache_control`,
  L60-69; coerces the **last** message's string content to `{{type="text"}}`, L71-79). `bbanthropic.lua:21-83`.
- `Conversation:new` unconditionally resets `o.messages={}`/`o.transcript={}` (L174-175) and clears
  `ui._bookbuddy_last_search/_locators/_loc_seq` (L193-197). `bbconversation.lua:171-223`.
- `ask` seeds `messages[1]` in **three** shapes (book-level, passage+note, passage-only) and appends a
  bare-string user turn thereafter (L226-257). `bbconversation.lua:225-260`.
- usage merge is a running sum of per-call deltas (L483-489). tool_result appended at L580.
- `_storeAssistant(blocks, is_resume)` extends prev assistant on resume (L599-608).
- `_dropDanglingTail` (L620-655) unwinds the in-flight tool round; calls `_trimTranscript` (L665-673)
  which **early-returns when `_clean_transcript_len == nil`** (L667).
- `pairDanglingWebSearch` is called at L528 on the freshly-merged assistant content.
- Spoiler gate reads `currentPage(ui)` **fresh** every call (`bbtools.lua:58-63`, `tool_read` L329/366/381).
  `tool_read`'s forward clamp is `if cur then` (L381) — **nil page = no clamp** (the §8.A hazard).
- `mintLocator` does `seq = seq + 1; locators[seq] = entry` (`bbtools.lua:119-125`).
- `main.lua:166-172` constructs `Conversation` into a `local` and drops the reference (no retention,
  no `onClose`/`onSuspend`). `promptAndStart` already renders `Presets.buttonRows` (L140-175).
- `_meta.lua` version is the string `"1.13.3"`.
- KOReader APIs exist: `util.fsyncOpenedFile(fd, sync_metadata)` (default fdatasync, base/ffi/util.lua:570),
  `util.fsyncDirectory(path)` (L597), `CreDocument:getXPointer()` (current reading xpointer, credocument.lua:884),
  `getPageXPointer`, `getCurrentPage`, `getPageFromXPointer`, `getPageCount`, `compareXPointers`,
  `isXPointerInDocument`. `DocSettings:getSidecarDir(file)` (used in `bbmemory.lua:103`).

> **Anchor drift (re-checked 2026-07-02):** the tree has since grown — every `bbconversation.lua`
> anchor above/below is ~90–130 lines low (e.g. `:174` → `:260`, `:225` → `:340`, `:620` → `:751`,
> `:599` → `:730`; `bbanthropic` mutation block `:60-79` → `:73-92`); the cited behaviors were
> re-verified unchanged. Note `buildBody` also **adds** `cache_control={type="ephemeral"}` to the
> last content block in place each call (`bbanthropic.lua:90-92`) — see §9 (B3). New since
> verification: the `ask_user` clarifying-question tool (`bbconversation.lua:287-294`, `:688-697`,
> `:961-977`) adds a **parked-turn** state (coroutine suspended awaiting the reader's answer). For
> the journal this is just an in-flight round: the `user_turn` + `assistant_blocks` (with the
> `ask_user` tool_use) are journaled but no `tool_result` follows until the reader answers, so a
> crash/close during a parked question is unwound by `_dropDanglingTail` on replay like any
> in-flight round. The tool loop is now a ≥3-way split (memory / ask_user / `Tools.execute`);
> `bb_meta` threading (§5.3a) anchors to the `Tools.execute` branch by name, not by else-position —
> `ask_user` results get the default meta (`{tool="ask_user", at_page=currentPage(ui), spoiler=false}`).

---

## 1. Summary & goals

A BookBuddy chat survives KOReader restart, book close, and plugin reload, and can be **resumed**
into a live, resendable `Conversation` that takes the next turn correctly and **spoiler-safely** in
both directions (reader advanced *or* retreated since the chat was last touched).

Durability is an **append-only per-conversation NDJSON journal** in the book's `.sdr` sidecar
(mirroring `bbmemory`'s sidecar pattern). Live state is reconstructed by **replaying** the journal
through the same alternation/dangling-tail invariants the live loop enforces. A killed app loses at
most the in-flight round.

**In scope**
- Crash-safe incremental persistence (per-event append, no "final dump" moment — there is none).
- Per-book resume picker.
- Airtight spoiler-safety on resume in **both** directions.
- Locator rehydration with xpointer-based staleness.

**Non-goals (explicitly cut)**
- **Compaction.** Resumed sessions resend full history every turn exactly like live ones, which have
  no compaction. It solves a non-problem and carried the worst alternation/thinking-split risk. Cut:
  the `compaction` event, the digest generator, `session_compact_tokens`, the compaction spec.
- **`.index.lua` cache.** Reintroduces a full-rewrite profile + a two-writer race to save microseconds
  scanning ≤20 header lines. The picker scans headers directly.
- **Cross-device merge.** Last-writer-wins files; per-conversation random suffixes prevent shared-file
  interleave; `*.sync-conflict*` files are ignored.
- **Persisting the viewer widget.** Only conversation state is persisted; the viewer is re-rendered.
- Branching / undo / export.

---

## 2. Design rationale & the core bet

**Elevator pitch:** `Conversation` has zero persistence and zero lifecycle hooks
(`main.lua:166` builds it anonymously and drops the reference). There is no moment to "save on close,"
so the only durable design writes **incrementally, per event, append-only** — a journal. Each turn
appends a few independently-decodable NDJSON records to a per-conversation file in the `.sdr` sidecar;
resume replays them through the **same** alternation/dangling-tail logic the live loop enforces.

**The core bet (corrected):** the wire `messages[]` is the source of truth and is resent verbatim every
turn — **but `buildBody` mutates that array in place every call** (`bbanthropic.lua:60-79`): it strips
`cache_control` from every block and coerces the *last* message's string content into
`{{type="text"}}`. So "round-trip is correctness-free via rapidjson" holds **only** if we serialize a
**normalized** form and decode into the **same** normalized form the live path converges to. We do
exactly that (§9). rapidjson preserves the object/array distinction `buildBody` depends on
(`bbanthropic.lua:2-3`), and per-line `pcall(rapidjson.decode)` gives crash tolerance.

**Sub-decisions (chosen, with rejected alternatives):**

- **Checkpointed journal, byte-threshold-gated.** A `checkpoint` (snapshot of resendable `messages[]`)
  is written only when uncheckpointed appended bytes exceed `CHECKPOINT_BYTES` (16 KiB) **or** at
  resume-finalize. Between checkpoints, replay folds events from the last checkpoint forward. Replay
  cost is paid **once, cold, per resume**; checkpoint cost is hot, so we minimize it.
  *Rejected:* per-chain-boundary checkpoints (O(n²) write bomb on a 30-turn chat); pure replay with no
  checkpoints (unbounded cold replay and unbounded `_dropDanglingTail` unwind scope).
- **Reuse `_dropDanglingTail` / web-search pairing; never reimplement** — but wire them correctly (§9).
- **`io.open(path,"ab")` → write → `flush` → `fsync` → `close` per record.** No long-lived fd.
  *Rejected:* caching `self._fh` (no close hook means an fd leak; an open fd over a Syncthing/FAT file
  is the worst write-safety case).
- **Transcript re-derived on replay, not journaled.** The transcript is display-only and never sent to
  the API. This deletes the `transcript_delta` event, halves write volume, and removes the
  mutation-timing trap (the tool-action line is mutated onto the entry *after* creation at
  `bbconversation.lua:572`; journaling a delta at the wrong instant would lose it).
  *Rejected:* journaling `transcript_delta`.
- **No per-mint `locator` events.** Locators live only in checkpoints. A locator minted after the last
  checkpoint but before a crash belongs to the in-flight round, which `_dropDanglingTail` unwinds
  anyway — per-mint events would recover nothing. `bbtools.lua` is untouched.

---

## 3. Data model — exact serialized schema

### 3.1 Physical format

NDJSON: one `rapidjson.encode(event)` per line, `\n`-terminated. rapidjson emits no embedded newlines.
Every record carries `v` (schema version int) and `t` (event type string). `JOURNAL_VERSION = 1`.

### 3.2 Header record (always the first line)

On-disk JSON:
```json
{"v":1,"t":"header","created":1717545600,"book_md5":"a1b2c3","book_title":"Juliet","plugin_version":"1.13.3"}
```
Lua table written:
```lua
{ v = 1, t = "header", created = os.time(), book_md5 = "a1b2c3" or nil,
  book_title = "Juliet", plugin_version = "1.13.3" }
```
| field | type | meaning |
|---|---|---|
| `v` | int | schema version of this record |
| `t` | string | `"header"` |
| `created` | int | `os.time()` at session creation |
| `book_md5` | string\|nil | partial md5 (informational; for cross-device sanity, never gates) |
| `book_title` | string | `ui.document:getProps().title` or basename, for the picker |
| `plugin_version` | string | `_meta.lua` version (informational; **never** conflated with `JOURNAL_VERSION`) |

### 3.3 `user_turn`

A reader question in **normalized wire shape**. `content` is **always** a content-block array (the
post-`buildBody` shape) and `raw_text` carries the **pre-coercion** string (needed for `chain_start`
parity — see §9). `seed=true` only on the first turn.
```json
{"v":1,"t":"user_turn","seed":true,"raw_text":"<book_context>...</book_context>\n\n<highlighted_passage>...</highlighted_passage>\n\n<question>...</question>","content":[{"type":"text","text":"<book_context>...</book_context>\n\n<highlighted_passage>...</highlighted_passage>\n\n<question>...</question>"}]}
{"v":1,"t":"user_turn","raw_text":"and what about the ending?","content":[{"type":"text","text":"and what about the ending?"}]}
```
| field | type | meaning |
|---|---|---|
| `seed` | bool\|absent | `true` only on the first user turn (carries frozen `<book_context>`) |
| `raw_text` | string | the pre-`buildBody` string content |
| `content` | array | normalized block array (`{{type="text",text=...}}`) |

### 3.4 `anchor`

Captured at session creation and at every resume-finalize / re-anchor. Position as an **xpointer** plus
a display page. **Policy/display only — never read by the spoiler gate.**
```json
{"v":1,"t":"anchor","xp":"/body/DocFragment[12]/body/div/p[3]/text().0","page":42,"total":310,"chapter":"Chapter 3"}
```
| field | type | meaning |
|---|---|---|
| `xp` | string\|nil | `ui.document:getXPointer()` (current reading position) |
| `page` | int\|nil | `currentPage(ui)` (may be nil) |
| `total` | int\|nil | `getPageCount()` |
| `chapter` | string\|nil | `toc:getTocTitleOfCurrentPage()` |

### 3.5 `assistant_blocks`

One stream completion's content blocks, verbatim wire shape (object/array preserved including
`thinking.signature`). `extend=true` reproduces `_storeAssistant`'s `is_resume` in-place extension
(`bbconversation.lua:601-604`). Empty `tool_use.input` is re-tagged as an object on **replay** (§9).
```json
{"v":1,"t":"assistant_blocks","extend":false,"blocks":[{"type":"thinking","thinking":"...","signature":"ErcB=="},{"type":"tool_use","id":"toolu_01","name":"grep","input":{"query":"Juliet"}}]}
```

### 3.6 `tool_result`

The wire tool_result array appended at `bbconversation.lua:580`, plus our **`bb_meta`** policy metadata
per result. `bb_meta` is **stored alongside but stripped before resend** (it is not a wire field); it
exists solely so backward-resume can re-gate stale results without re-running tools (§8.C).
```json
{"v":1,"t":"tool_result","results":[{"type":"tool_result","tool_use_id":"toolu_01","content":"3 matches...\nloc:7 ..."}],"bb_meta":[{"tool":"grep","at_page":42,"spoiler":false,"max_referenced_page":47,"max_referenced_xp":"/body/DocFragment[14]/body/div/p[2]/text().0"}]}
```
`bb_meta[i]` fields (aligned by index with `results[i]`; replay re-keys them by
`results[i].tool_use_id` into the conversation-level `bb_meta` map — §5.1/§9):
| field | type | meaning |
|---|---|---|
| `tool` | string | tool name that produced result `i` |
| `at_page` | int\|nil | `currentPage(ui)` at execution time |
| `spoiler` | bool | whether the tool honored `spoiler=true` |
| `max_referenced_page` | int\|nil | highest page this result drew content from (display + fallback oracle) |
| `max_referenced_xp` | string\|nil | xpointer of the furthest position this result drew from — the **primary**, layout-stable re-gate oracle (§8.C); the page int is only the fallback when no xpointer was resolvable |
| `redacted_original` | any\|nil | set by the §8.C re-gate: the original `tool_result` content stashed when the block was redacted to the stub; makes redaction **reversible**. Never present in freshly-journaled records — only in `checkpoint.bb_meta`. |

### 3.7 `usage_delta`

The **per-call usage increment** (the values added at `bbconversation.lua:485-488`), **not** the running
total — so checkpoint-total + replayed-deltas never double-counts (§9).
```json
{"v":1,"t":"usage_delta","input":1200,"output":340,"cache_read":8000,"cache_write":200}
```

### 3.8 `checkpoint`

A snapshot of the full resendable `messages[]` at a byte-threshold boundary or at resume-finalize, with
running `usage`, locator state, and `clean_transcript_len`. Serialized with `cache_control` stripped and
content normalized. Replay loads the **last** checkpoint, then folds only events after it.
```json
{"v":1,"t":"checkpoint","seq":3,"messages":[{"role":"user","content":[{"type":"text","text":"..."}]},{"role":"assistant","content":[{"type":"text","text":"..."}]}],"usage":{"input":12000,"output":3400,"cache_read":80000,"cache_write":2000},"loc_seq":7,"locators":{"1":{"kind":"span","xp":"...","xp_end":"..."}},"clean_transcript_len":4,"bb_meta":{"toolu_01":{"tool":"grep","at_page":42,"spoiler":false,"max_referenced_page":47,"max_referenced_xp":"...","redacted_original":null}}}
```
| field | type | meaning |
|---|---|---|
| `seq` | int | monotonic checkpoint counter (for diagnostics) |
| `messages` | array | full resendable wire history (normalized, no `cache_control`) |
| `usage` | table | running total at checkpoint time |
| `loc_seq` | int | `ui._bookbuddy_loc_seq` at checkpoint time |
| `locators` | object | `ui._bookbuddy_locators` snapshot (`{ [n] = {kind,xp,xp_end?} }`) |
| `clean_transcript_len` | int | `self._clean_transcript_len` at checkpoint time |
| `bb_meta` | object | the conversation-level taint map, keyed by `tool_use_id` (`{tool, at_page, spoiler, max_referenced_page, max_referenced_xp, redacted_original?}`). **Load-bearing for generational safety:** replay starts from the last checkpoint, so without this field every `tool_result` *before* that checkpoint would lose its `bb_meta` after one resume (the forced `finalizeResume` checkpoint) and a second-generation backward resume would find nothing to redact. Carrying the map — including `redacted_original` — in every checkpoint makes taint detection and redaction reversal work at any generation. |

> `locators` keys are **stringified integers** (rapidjson encodes Lua integer keys as JSON object
> string keys). Replay parses them back with `tonumber` (§9).

### 3.9 Schema version & forward-compat

- `v` on every record. Replay **skips unknown event types** and **ignores unknown fields**.
- Any record with `v > JOURNAL_VERSION` ⇒ the whole journal is **non-resumable** (picker greys it
  "newer version"; we never append to it).
- Strictly-lower `v` is migrated forward in memory (§10).

---

## 4. On-disk layout

Mirror `bbmemory.baseDirForBook` exactly (`bbmemory.lua:101-108`):
```
<book>.sdr/
  bookbuddy_memory/                          (existing, untouched)
  bookbuddy_sessions/                        (NEW — created lazily on first append)
    20260605T142233-3f8a.ndjson
    20260605T151210-9c21.ndjson
```

- **Base dir resolver** (new in `bbjournal.lua`), identical shape to memory's: returns `nil` when no
  file is open → caller **skips persistence entirely** (exactly like memory at `bbconversation.lua:203-205`).
  ```lua
  function Journal.baseDirForBook(ui)
      local file = ui and ui.document and ui.document.file
      local sdr = file and DocSettings:getSidecarDir(file)
      if not sdr or sdr == "" then return nil end
      return sdr .. "/bookbuddy_sessions"
  end
  ```
- **File naming:** `os.date("!%Y%m%dT%H%M%S")` + `"-"` + 8 random hex chars
  (`string.format("%08x", math.random(0, 0x7fffffff))`), with `math.randomseed` mixed from
  `os.time()` **plus** sub-second entropy (`os.clock()*1e6` and address digits from
  `tostring({})`) once at module load — an unseeded (or time-only-seeded) LuaJIT stream is
  per-process deterministic, which is exactly wrong for two processes/devices started the same
  second. Name-sort = recency-sort; the random suffix disambiguates same-second starts and keeps
  two devices' files distinct under Syncthing (residual same-second cross-device collision odds
  ≈ 2⁻³¹ — acceptable).
- **`*.sync-conflict*`** filenames are ignored in `list` (logged once).
- **Lazy mkdir:** `bbjournal` `lfs.mkdir`s `bookbuddy_sessions/` on first write, then
  `ffiUtil.fsyncDirectory(<.sdr>)` so the new directory entry is durable (A2).
- KOReader purges/moves `.sdr` on book delete/move; orphaned files under a moved-away `.sdr` are **not**
  GC'd by us (documented limitation, §11).

Who creates what: the **constructor** opens/creates the journal (§5.3); `bbjournal` creates the
directory and files; `main.lua` only reads (picker) and triggers replay.

---

## 5. Module-by-module changes

### 5.1 NEW — `bbjournal.lua`

Requires: `rapidjson`, `lfs`, `DocSettings = require("docsettings")`,
`ffiUtil = require("ffi/util")`, `logger = require("logger")`, `Wire = require("bbwire")`,
`util = require("util")`, `Meta = require("_meta")`.

**Public API:**
```lua
local JOURNAL_VERSION = 1
local CHECKPOINT_BYTES = 16 * 1024

function Journal.baseDirForBook(ui)            -- -> dir | nil
function Journal.create(ui, opts)              -- writes header + anchor; -> writer | nil, reason
function Journal.open(ui, filename)            -- resume append; rewrites torn tail once; -> writer | nil, reason
function Journal.list(ui)                       -- header-scan, newest-first; -> { entry, ... }
function Journal.replay(ui, filename)          -- pure; -> restore | nil, reason
function Journal.delete(ui, filename)          -- -> ok:bool
function Journal.clearAll(ui)                   -- -> count:int
function Journal.prune(ui, keep)               -- -> count_pruned:int (called from create)
```

`opts` for `create`: `{ book_title=string, book_md5=string|nil, anchor=table }`.

**`list` entry shape:**
```lua
{ filename = "20260605T151210-9c21.ndjson",
  title = "Juliet",
  created = 1717545600,
  last_turn_ts = 1717549000,        -- mtime fallback if no per-record ts
  turn_count = 3,                    -- count of user_turn records (header-scan reads only the header;
                                     -- turn_count comes from a cheap full line-count, see note)
  first_question = "What does this passage mean?",   -- <question> extracted from the seed
  anchor = { xp=..., page=42, total=310, chapter="Chapter 3" },
  resumable = true,
  reason = nil }                     -- e.g. "newer_version" | "no_header" when resumable=false
```
> **turn_count / first_question** require more than the header line. To keep the picker cheap, `list`
> reads the **header line** (line 1) for `title`/`created`/`resumable`, plus a bounded scan of the
> **first ~40 lines** to find the seed `user_turn` (for `first_question`) and to count `user_turn`
> records. ≤20 files × ≤40 lines is trivial even on a Kobo. `last_turn_ts` falls back to file mtime.
> `first_question` is codepoint-clipped via `util.splitToChars` (matching `main.lua:116-122`).

**`restore` table (consumed by the constructor, §5.3):**
```lua
{ messages = { ... },                 -- normalized wire history
  usage = { input=, output=, cache_read=, cache_write= },
  locators = { [n] = {kind,xp,xp_end?,stale=true}, ... },
  loc_seq = N,
  clean_transcript_len = N,
  session_anchor = { xp=, page=, total=, chapter= },   -- the LATEST anchor record
  bb_meta = { [tool_use_id] = {tool,at_page,spoiler,max_referenced_page,max_referenced_xp,redacted_original?} },
                                      -- conversation-level taint map: last checkpoint's map merged
                                      -- with post-checkpoint tool_result records (later wins)
  spoiler_consented = bool,           -- derived from bb_meta: any entry with spoiler=true (LEAK-2)
  max_referenced_page = N|nil,        -- derived from bb_meta: highest max_referenced_page (LEAK-1, display)
  seed_index = 1,                     -- index in messages[] of the seed user turn (for in-place rewrite, §8.D)
  had_checkpoint = bool,              -- false => replay started from header (toast honesty, §11/C7)
  truncated = bool }                   -- torn/garbage tail was dropped on read
```

**Writer handle** (open/append/close-per-record; no cached fd):
```lua
writer.path                 -- absolute file path
writer.filename
writer.dir                  -- bookbuddy_sessions dir (for dir fsync)
writer._broken              -- set on any write failure; all appends then no-op
writer._bytes_since_ckpt    -- threshold accounting
writer._needs_dir_fsync     -- true until first append fsyncs the dir entry

function writer:userTurn(content_blocks, raw_text, seed)
function writer:anchor(a)
function writer:assistantBlocks(blocks, extend)
function writer:toolResult(results, meta)
function writer:usageDelta(u)
function writer:checkpoint(snapshot)         -- caller decides when (threshold/finalize)
function writer:bytesSinceCheckpoint()       -- -> int
```

**Durability core (FAT32-safe, A1/A2/A3):**
```lua
local function appendRecord(writer, event)
    event.v = JOURNAL_VERSION
    local line = rapidjson.encode(event)            -- compact, no embedded \n
    local f, err = io.open(writer.path, "ab")
    if not f then error(err) end                    -- caught by safeAppend -> _broken
    f:write(line)
    f:write("\n")
    f:flush()
    ffiUtil.fsyncOpenedFile(f)                       -- fdatasync: data durable
    if writer._needs_dir_fsync then
        ffiUtil.fsyncDirectory(writer.dir)           -- make the dir entry durable (A2)
        writer._needs_dir_fsync = false
    end
    f:close()                                        -- never hold the fd (A3)
    writer._bytes_since_ckpt = writer._bytes_since_ckpt + #line + 1
end
```
*Decision (A4):* fsync-per-record, **not** a `session_fsync` knob. Records are small and infrequent
(a few per turn); the only failure case fsync addresses is power loss. The appends run at the loop's
existing `UIManager:nextTick`/`_flushNow` yields, off the synchronous `Tools.execute` window, so the
fsync stall does not extend the tool-blocking time. If hardware ever shows unacceptable stalls, the
single internal call flips to flush-only — but it is **not** a user setting.

**Crash recovery — truncate-and-stop (A1):**
```lua
local function readRecords(path)
    local records, truncated = {}, false
    local fh = io.open(path, "rb")
    if not fh then return nil, "missing" end
    for line in fh:lines() do
        if line == "" then truncated = true; break end          -- ragged/short final write
        if line:find("\0", 1, true) then truncated = true; break end  -- FAT NUL-fill tail
        local ok, ev = pcall(rapidjson.decode, line)
        if not (ok and type(ev) == "table" and ev.t and ev.v) then
            truncated = true; break                              -- torn/foreign/garbage tail
        end
        records[#records + 1] = ev
    end
    fh:close()
    return records, truncated
end
```
We **do not** "skip one bad line and continue": on FAT a corruption point means bytes after it cannot
be trusted to belong to this file. On `Journal.open` for resume, if `truncated`, the file is **rewritten
once**: temp file → fsync → `os.rename` onto the torn file → fsync the dir. (On Linux vfat,
rename-over-existing *succeeds* but is **not** power-loss-atomic — acceptable here because the
source is already torn: a crash mid-rewrite leaves a torn file that the next open re-runs the same
truncate-and-stop recovery on. Don't call this rename "atomic" in code comments.) The rewrite drops
everything from the corruption point, so the next in-session append can't concatenate onto garbage.
This is the only non-append operation.

**Replay core:**
```lua
function Journal.replay(ui, filename)
    local path = Journal.baseDirForBook(ui)
    if not path then return nil, "no_sidecar" end
    path = path .. "/" .. filename
    local records, t = readRecords(path)
    if not records then return nil, t end                       -- "missing"
    if #records == 0 then return nil, "empty" end
    if records[1].t ~= "header" then return nil, "no_header" end
    for _, r in ipairs(records) do
        if r.v and r.v > JOURNAL_VERSION then return nil, "newer_version" end
    end
    records = migrate(records)                                   -- §10
    local restore = freshRestore()
    local start = lastCheckpointIndex(records)                  -- index of last checkpoint, else nil
    restore.had_checkpoint = (start ~= nil)
    if start then applyCheckpoint(restore, records[start]) else start = 1 end
    for i = start + 1, #records do
        local h = HANDLERS[records[i].t]                         -- unknown types skipped
        if h then h(restore, records[i]) end
    end
    -- Heal orphan web searches on EVERY assistant message, both directions (idempotent).
    for _, m in ipairs(restore.messages) do
        if m.role == "assistant" and type(m.content) == "table" then
            Wire.healWebSearch(m.content)
        end
    end
    restore.truncated = t
    restore.session_anchor = restore.session_anchor or {}
    -- Derive the taint aggregates from the merged bb_meta map (checkpoint ∪ later events):
    for _, meta in pairs(restore.bb_meta) do
        if meta.spoiler then restore.spoiler_consented = true end
        if meta.max_referenced_page then
            restore.max_referenced_page = math.max(restore.max_referenced_page or 0, meta.max_referenced_page)
        end
    end
    return restore
end
```
`_dropDanglingTail` is **not** run inside replay — it is a method on the live `Conversation` and must
use the rehydrated `_clean_transcript_len`. It runs in `finalizeResume` (§5.3/§9).

**Handlers (the canonical replay logic):**
```lua
local HANDLERS = {}

HANDLERS.user_turn = function(r, ev)
    r.messages[#r.messages + 1] = { role = "user",
        content = retagEmptyInputs(ev.content), _raw_text = ev.raw_text, _seed = ev.seed }
    if ev.seed then r.seed_index = #r.messages end
end

HANDLERS.anchor = function(r, ev)
    r.session_anchor = { xp = ev.xp, page = ev.page, total = ev.total, chapter = ev.chapter }
end

HANDLERS.assistant_blocks = function(r, ev)
    local blocks = retagEmptyInputs(ev.blocks)
    local prev = r.messages[#r.messages]
    if ev.extend and prev and prev.role == "assistant" and type(prev.content) == "table" then
        for i = 1, #blocks do prev.content[#prev.content + 1] = blocks[i] end
    else
        r.messages[#r.messages + 1] = { role = "assistant", content = blocks }
    end
end

HANDLERS.tool_result = function(r, ev)
    r.messages[#r.messages + 1] = { role = "user", content = ev.results }
    -- Re-key bb_meta by tool_use_id into the conversation-level map (r.bb_meta), which the
    -- last checkpoint pre-seeded (applyCheckpoint). Keyed by id, not message index, so it
    -- survives tail-drops, redaction, and checkpointing. Aggregates (LEAK-1/LEAK-2) are
    -- derived from r.bb_meta once, after the forward loop.
    for i, res in ipairs(ev.results) do
        local meta = ev.bb_meta and ev.bb_meta[i]
        if meta and res.tool_use_id then r.bb_meta[res.tool_use_id] = meta end
    end
end

HANDLERS.usage_delta = function(r, ev)
    r.usage.input = r.usage.input + (ev.input or 0)
    r.usage.output = r.usage.output + (ev.output or 0)
    r.usage.cache_read = r.usage.cache_read + (ev.cache_read or 0)
    r.usage.cache_write = r.usage.cache_write + (ev.cache_write or 0)
end
-- checkpoint handled by applyCheckpoint, not in the forward loop
```
The `_raw_text`/`_seed` underscore fields are **internal** (consumed by the constructor, then
dropped before resend — see §9). Taint metadata never rides the messages themselves: it lives in
the conversation-level `bb_meta` map (`restore.bb_meta` → `conv._bb_meta`), keyed by
`tool_use_id`, so the wire history stays clean for `buildBody` while the map survives
checkpointing (§3.8). `retagEmptyInputs` re-tags any `tool_use`/`server_tool_use` whose decoded
`input` is an empty table as `rapidjson.object(input)` (§9, C5).

### 5.2 NEW — `bbwire.lua` (tiny, pure)

Move `pairDanglingWebSearch` out of `bbconversation.lua` into `bbwire.lua` and **extend it to heal
reverse-orphans**:
```lua
local Wire = {}
-- Make an assistant content array's web-search blocks self-consistent in BOTH directions:
--  forward orphan: a server_tool_use with no matching web_search_tool_result -> append a synthetic
--                  error result (the existing pairDanglingWebSearch behavior).
--  reverse orphan: a web_search_tool_result whose server_tool_use id is absent in THIS array -> drop it.
-- Idempotent. Heals mid-history orphans a torn/skipped journal can leave that
-- _dropDanglingTail (last-message only) does not.
function Wire.healWebSearch(content) ... end
return Wire
```
`bbconversation.lua` requires `Wire` and calls `Wire.healWebSearch(self.messages[#self.messages].content)`
at the existing site (`bbconversation.lua:528`, replacing the inline `pairDanglingWebSearch` call).
This is the **only** refactor of existing logic; the invariant now has a single copy.

> The live path only ever produced forward-orphans (or reverse-orphans at the message under
> construction). Running `healWebSearch` on **every** restored assistant message closes the
> `validateMessages` gap that the last-message-only `_dropDanglingTail` misses for mid-history records.

### 5.3 `bbconversation.lua`

Add at top: `local Journal = require("bbjournal")`, `local Wire = require("bbwire")`.

Add module-local helper (also used by `_snapshot`):
```lua
local function safeAppend(writer, fn)
    if not writer or writer._broken then return end
    local ok, err = pcall(fn)
    if not ok then
        require("logger").warn("BookBuddy: journal write failed; disabling persistence", err)
        writer._broken = true
    end
end
```

**`Conversation:new(o)` (`:171-223`)** — accept `o.restore` and `o.journal_filename`:
- The existing unconditional resets run **first** (`o.messages={}`/`o.transcript={}` L174-175;
  locator/last-search clear L193-197).
- **Then**, if `o.restore`:
  - `o.messages = restore.messages` (strip the internal underscore fields used by the resume pass into
    `o._restore_meta` before resend — §9 strips them).
  - `o.usage = restore.usage`.
  - `o._clean_transcript_len = restore.clean_transcript_len` (**before** any `_dropDanglingTail` — C3).
  - **Locator merge, never clobber (C9):**
    ```lua
    o.ui._bookbuddy_locators = o.ui._bookbuddy_locators or {}
    for n, entry in pairs(restore.locators or {}) do
        entry.stale = true                                  -- §8.H
        o.ui._bookbuddy_locators[n] = o.ui._bookbuddy_locators[n] or entry
    end
    o.ui._bookbuddy_loc_seq = math.max(o.ui._bookbuddy_loc_seq or 0, restore.loc_seq or 0)
    ```
    Order is load-bearing: this runs **after** the L193-197 clear so it isn't wiped.
  - Stash `o._session_anchor = restore.session_anchor`, `o._bb_meta = restore.bb_meta` (the
    taint map — lives for the whole session and rides every subsequent checkpoint),
    `o._seed_index = restore.seed_index`, `o._is_resumed = true`. (The derived aggregates
    `spoiler_consented`/`max_referenced_page` are consumed by `_assessSpoilerTaint` before
    construction and need not be stashed.)
- **Open the writer:**
  ```lua
  if o.journal_filename then
      o.journal = Journal.open(o.ui, o.journal_filename)        -- resume append (rewrites torn tail)
  elseif o.settings:getConfig().enable_sessions then
      local dir = Journal.baseDirForBook(o.ui)
      if dir then
          o.journal = Journal.create(o.ui, {
              book_title = <title>, book_md5 = <md5-or-nil>,
              anchor = Conversation._captureAnchor(o.ui),       -- header + first anchor
          })
      end
  end
  ```
  `o.journal == nil` ⇒ persistence off; every call site guards via `safeAppend(self.journal, ...)`.

**NEW `Conversation._captureAnchor(ui)`** (static; reuses `book_context`'s page/chapter logic):
```lua
function Conversation._captureAnchor(ui)
    local Tools = require("bbtools")
    return Tools.captureAnchor(ui)   -- { xp, page, total, chapter } (new tiny Tools export, §5.3a)
end
```

**`ask(question)` (`:225-260`)**:
- **Seed turn** (`#self.messages == 0`): build `seed` exactly as today (the three shapes at L228-253),
  then store the message **and** journal it normalized:
  ```lua
  self.messages[#self.messages + 1] = { role = "user", content = seed }   -- unchanged (bare string)
  safeAppend(self.journal, function()
      self.journal:userTurn({ { type = "text", text = seed } }, seed, true)
      self.journal:anchor(Conversation._captureAnchor(self.ui))
  end)
  ```
  > We store the live message as a **bare string** (unchanged behavior) but journal the **normalized
  > array + raw_text**, so the journal matches the post-`buildBody` array while replay can reconstruct
  > the correct string-vs-array state per position (§9).
- **Resume re-anchor** (first post-resume `ask`, i.e. `self._is_resumed and not self._reanchored`):
  before appending the new user turn, run the drift assessment (§8.B) and, if needed, the history
  re-gate (§8.C) and seed `book_context` in-place rewrite (§8.D); set `self._reanchored = true`.
- **Follow-up turn** (else branch, L256): `content = question` (unchanged), then
  ```lua
  safeAppend(self.journal, function()
      self.journal:userTurn({ { type = "text", text = question } }, question, false)
      self.journal:anchor(Conversation._captureAnchor(self.ui))
  end)
  ```

**`_loop` (`:273-...`) — threshold checkpoint**: **before** the round's `buildBody` (which mutates
`self.messages`), if `self.journal and self.journal:bytesSinceCheckpoint() >= CHECKPOINT_BYTES`, take
and write a snapshot. Taking it *before* `buildBody` guarantees no `cache_control` and un-coerced
content:
```lua
if self.journal and not self.journal._broken
   and self.journal:bytesSinceCheckpoint() >= 16 * 1024 then
    safeAppend(self.journal, function() self.journal:checkpoint(self:_snapshot()) end)
end
```

**NEW `Conversation:_snapshot()`**:
```lua
function Conversation:_snapshot()
    return {
        messages = deepcopyStripped(self.messages),     -- removes residual cache_control, normalizes string content
        usage = { input=self.usage.input, output=self.usage.output,
                  cache_read=self.usage.cache_read, cache_write=self.usage.cache_write },
        loc_seq = self.ui._bookbuddy_loc_seq or 0,
        locators = deepcopy(self.ui._bookbuddy_locators or {}),
        clean_transcript_len = self._clean_transcript_len,
        bb_meta = deepcopy(self._bb_meta or {}),        -- taint map incl. redacted_original (§3.8)
    }
end
```
`deepcopyStripped` strips any `cache_control` key and coerces string content to `{{type="text"}}`.
This strip is **required, not defensive**: "snapshot pre-mutation" only means *this* round's
`buildBody` hasn't run yet — the *previous* round's `buildBody` **added**
`cache_control={type="ephemeral"}` to the last content block in place (`bbanthropic.lua:90-92`), so
every post-round-1 snapshot carries exactly one residual marker until stripped (B3).

**usage merge (`:483-489`)**: compute the per-call delta and journal it:
```lua
local u = res.usage
if u then
    local di = u.input_tokens or 0
    local do_ = u.output_tokens or 0
    local dr = u.cache_read_input_tokens or 0
    local dw = u.cache_creation_input_tokens or 0
    self.usage.input = self.usage.input + di
    self.usage.output = self.usage.output + do_
    self.usage.cache_read = self.usage.cache_read + dr
    self.usage.cache_write = self.usage.cache_write + dw
    safeAppend(self.journal, function()
        self.journal:usageDelta({ input = di, output = do_, cache_read = dr, cache_write = dw })
    end)
end
```

**`_storeAssistant(blocks, is_resume)` (`:599-608`)**: after storing, journal with `extend=is_resume`:
```lua
safeAppend(self.journal, function() self.journal:assistantBlocks(blocks, is_resume) end)
```
(Placed at the **end** of `_storeAssistant`, after the existing store, so it journals the exact blocks
stored. The `pairDanglingWebSearch`/`healWebSearch` mutation at `:528` happens *after* `_storeAssistant`
returns; the replay-side `healWebSearch` reproduces it, so journaling the pre-heal blocks is correct.)

**tool_result append (`:580`)**: emit a `tool_result` record with `bb_meta`, and mirror it into
the live conversation-level taint map (so checkpoints carry it — §3.8):
```lua
self.messages[#self.messages + 1] = { role = "user", content = tool_results }
self._bb_meta = self._bb_meta or {}
for i, res in ipairs(tool_results) do
    if tool_meta[i] and res.tool_use_id then self._bb_meta[res.tool_use_id] = tool_meta[i] end
end
safeAppend(self.journal, function() self.journal:toolResult(tool_results, tool_meta) end)
```
`tool_meta[i]` is built in the tool loop (`:565-578`) from values the executor returns. **Threading
`bb_meta` out of `Tools.execute`** (§5.3a): `Tools.execute` already computes `at_page`/`spoiler`/the
read range; we extend its return to carry an optional 3rd value `meta` (`{at_page,spoiler,max_referenced_page}`),
defaulting to `{tool=name, at_page=currentPage(ui), spoiler=false}` when a tool doesn't compute a page
range. No gate logic changes — we only read values the gate already has.

**`_dropDanglingTail` (`:620-655`)**: logic unchanged. Now also the canonical replay-finisher, called
from `finalizeResume` **after** `_clean_transcript_len` is seeded so `_trimTranscript` (`:665-673`)
actually runs (it early-returns on nil — verified L667).

**NEW `Conversation:finalizeResume()`**:
```lua
function Conversation:finalizeResume()
    self:_dropDanglingTail()                 -- _clean_transcript_len already set in :new (C3)
    local dropped = (self._restore_msg_count or #self.messages) - #self.messages
    self:_rederiveTranscript()               -- §9 — rebuild display log from clean messages
    safeAppend(self.journal, function() self.journal:checkpoint(self:_snapshot()) end)  -- clean, bounded tail
    return dropped, (self._restore_had_checkpoint == false)   -- (count, replayed_from_header)
end
```

**NEW `Conversation:_rederiveTranscript()`**: walk the clean `self.messages[]` and rebuild
`self.transcript[]` using the same per-block ordering `_renderAssistantTurn` uses (assistant text,
thinking, tool-action lines with a summary re-derived from the — possibly redacted — `tool_result`
content). Display-only; never sent. Runtime memo fields (`_md_src`/`_md_out`/`done`) are recomputed, not
persisted (C10).

**Remove from `bbconversation.lua`:** the inline `pairDanglingWebSearch` definition (moved to
`bbwire.lua`); the call site at `:528` becomes `Wire.healWebSearch(...)`.

### 5.3a `bbtools.lua` — minimal additions (no gate change)

- **NEW export `Tools.captureAnchor(ui)`**: returns `{ xp = ui.document.getXPointer and
  ui.document:getXPointer() or nil, page = currentPage(ui), total = ui.document:getPageCount(),
  chapter = currentChapter(ui) }`. Reuses the existing `currentPage`/`currentChapter` locals
  (`bbtools.lua:58-76`). Guards every call (nil page allowed).
- **`Tools.execute` return**: add an optional 3rd return value `meta` for `grep`/`read`/`book_context`
  carrying `{ at_page, spoiler, max_referenced_page, max_referenced_xp }`. The page-range tools
  already compute `start_page`/`cur`/the clamp; `max_referenced_page` is the highest page any
  returned passage drew from (for `read`, the end page of the returned chunk; for `grep`, the max
  page across matches; for `book_context`, `currentPage`). `max_referenced_xp` — the **primary**
  re-gate oracle (§8.C) — is the xpointer of the furthest position drawn from: for `read`, the
  `xp_end` the read loop already tracks; for `book_context`, `ui.document:getXPointer()`; for
  `grep`, `doc:getPageXPointer(<max match page>)` when resolvable, else nil (page fallback applies).
  This is **read-only** instrumentation — no behavior change. The instrumentation anchors to the
  `Tools.execute` branch of the tool loop by name (the loop is a ≥3-way split since `ask_user`);
  non-`Tools.execute` results (memory, `ask_user`) get the default meta.

> Comment to add at `captureAnchor`/the `meta` return: *"bb_meta and the anchor are policy/display only;
> the spoiler gate never reads them — it always reads currentPage(ui) fresh. See approach-c-journal.md §8.A."*

### 5.4 `main.lua` — resume UX

- **No blocking pre-dialog.** `promptAndStart` (`:105-186`) keeps opening the question `InputDialog`
  directly (zero added friction on the new-chat path). When `Journal.list(ui)` is non-empty, inject a
  single **"Resume previous chat…"** button into the existing `buttons` array built from
  `Presets.buttonRows` (`:140-142`) — costs **no extra screen refresh**:
  ```lua
  if #Journal.list(self.ui) > 0 then
      table.insert(buttons, 1, { { text = _("Resume previous chat…"),
          callback = function() UIManager:close(dialog); self:resumePicker() end } })
  end
  ```
- **NEW `BookBuddy:resumePicker()`**: a `Menu` (require `ui/widget/menu`) listing sessions newest-first
  from `Journal.list`. Row `text` = `first_question` (clipped) + `"  · "` + `turn_count` + `" turns · "`
  + relative time. Non-resumable rows (`reason == "newer_version"`) shown greyed/`dim` with the reason.
  Footer button **[Clear saved chats]** → `ConfirmBox` → `Journal.clearAll(self.ui)`. Long-press a row →
  `ConfirmBox` → `Journal.delete(self.ui, filename)` then refresh the menu.
- **NEW `BookBuddy:resumeSession(filename)`**:
  ```lua
  function BookBuddy:resumeSession(filename)
      local restore, err = Journal.replay(self.ui, filename)
      if not restore then
          UIManager:show(InfoMessage:new({ text = T(_("Couldn't resume this chat: %1"), tostring(err)) }))
          return
      end
      local taint = self:_assessSpoilerTaint(restore)            -- §8
      if taint.position_unavailable then
          UIManager:show(InfoMessage:new({ text = _(
              "Reading position unavailable — open the book to a page, then reopen this chat.") }))
          return
      end
      if taint.needs_consent then
          self:_confirmTaintedResume(restore, filename, taint)   -- §8.G; calls _doResume on choice
          return
      end
      self:_doResume(restore, filename, taint)
  end
  ```
- **NEW `BookBuddy:_doResume(restore, filename, taint)`**:
  ```lua
  applyHistoryRegate(restore, taint, self.ui)   -- §8.C: symmetric — redacts ahead content,
                                                -- un-redacts stashed content now behind the reader
                                                -- (reveal_all skips redaction and restores stashes)
  local conv = Conversation:new({
      ui = self.ui, settings = self.settings,
      restore = restore, journal_filename = filename,
      resumed = true, resume_taint = taint,
  })
  local dropped, from_header = conv:finalizeResume()
  self._active_conversation = conv                                -- pin against GC (main.lua:166 drops it today)
  conv:_render({ subtitle = _("Resumed chat") })                 -- mandatory subtitle (UX#2)
  if dropped > 0 then
      local msg = from_header and _("Resumed. An interrupted question may have been discarded.")
                              or  _("Resumed. An interrupted question was discarded.")
      UIManager:show(InfoMessage:new({ text = msg, timeout = 3 }))
  end
  ```
- **NEW `BookBuddy:_assessSpoilerTaint(restore)`** and **`_confirmTaintedResume(...)`** — §8.
- **Single-active eviction:** assigning `_active_conversation` simply drops the previous reference; there
  is **no fd to close** (A3), so no leak. Writer state is flushed-and-fsynced per record.

### 5.5 `bbsettings.lua`

Add to `DEFAULTS` (`:14-39`) and `getConfig` (`:61-76`):
```lua
enable_sessions = true,   -- persist + offer resume (default-on; §13)
session_keep    = 20,     -- max session files retained per book (clamp math.max(1, ...))
```
Add a **Sessions** submenu (mirroring "Clear memory" at `:171-206`):
- Toggle `enable_sessions` (checked/unchecked menu item, `setConfig`).
- "Clear saved chats" → `ConfirmBox` → `Journal.clearAll(ui)` (needs `ui`; pass it from the menu
  builder as the memory submenu already does).
- An info line stating `session_keep`.

*Cut:* `session_fsync` (A4), `session_compact_tokens` (compaction cut).

### 5.6 `_meta.lua`

Bump `version` from `"1.13.3"` (three-part dotted) for the release. `JOURNAL_VERSION` is a separate
integer in `bbjournal.lua`; **never** conflated with the plugin version string (B4).

---

## 6. Lifecycle & save points

| Moment (anchor) | Records written |
|---|---|
| `Journal.create` (no restore) | `header` + `anchor` (session start position) |
| `ask` appends user turn | `user_turn` (normalized) + `anchor` |
| `_loop`, **before** `buildBody`, if `bytesSinceCheckpoint() >= CHECKPOINT_BYTES` | `checkpoint` (clean, pre-mutation) |
| `_storeAssistant` | `assistant_blocks{extend=is_resume}` |
| usage merge (`:485-488`) | `usage_delta` (per-call delta) |
| tool_result append (`:580`) | `tool_result` + `bb_meta` |
| `finalizeResume` | `checkpoint` (clean, bounded tail) |

Every append: `open "ab"` → write → `flush` → `fsyncOpenedFile` → (`fsyncDirectory` on first append to a
new file) → `close` (A1/A2/A3). Appends happen at the loop's `_flushNow`/`nextTick` yields, off the
synchronous `Tools.execute` window (A4).

**Crash guarantee:** lose at most the in-flight round (everything up to the last fully-written-and-fsynced
record). FAT torn/NUL/garbage tail → truncate-and-stop recovery (A1); the first append's directory entry
is durable (A2).

**Load trigger:** **only** explicit user resume via the picker. No auto-resume on book open (avoids
surprising the reader and avoids silently answering the position-drift question).

---

## 7. Resume flow (UX + code path)

**Entry:** the question `InputDialog` shows a **"Resume previous chat…"** button (prepended to the
existing preset rows) when `Journal.list(ui)` is non-empty — no modal, no extra refresh. → `resumePicker()`.

**Picker** (header + bounded-scan, newest first):
```
Resume a BookBuddy chat
─────────────────────────
"What does this passage mean?"   3 turns · today 14:22
"Who is the narrator?"           7 turns · today 15:12
"(newer plugin version)"         — greyed
─────────────────────────
[Clear saved chats]   [Cancel]
```
Long-press a row → confirm → `Journal.delete`. "Clear saved chats" → confirm → `Journal.clearAll`.

**Selection → `resumeSession(filename)`:**
1. `Journal.replay` → `restore` (or error → InfoMessage, abort).
2. `_assessSpoilerTaint(restore)` (§8): `position_unavailable` → abort with the "open the book" message;
   `needs_consent` → `_confirmTaintedResume` (one modal); else continue.
3. `_doResume`: apply the symmetric history re-gate (§8.C — redacts ahead content, un-redacts
   stashed content the reader has caught up to; "reveal everything" restores all stashes), construct the
   `Conversation` with `restore`/`journal_filename`, `finalizeResume()` (drop dangling tail →
   re-derive transcript → forced clean checkpoint), pin `_active_conversation`, `_render` with the
   "Resumed chat" subtitle, toast any dropped tail.
4. The viewer's existing Reply button drives `ask` on the live, journal-backed instance
   (`_render`→`_promptFollowup`→`ask`) — **no new turn-taking code**.

---

## 8. SPOILER-SAFETY ON RESUME — airtight, symmetric

The hard problem: reading position captured at session start is frozen in `messages[]`; on resume the
reader may have **advanced** (forward) or **retreated / re-read** (backward). Backward is the *primary*
use of resume and the dangerous one.

### 8.A The live gate is never subverted (verified, kept)

`tool_grep`/`tool_read`/`book_context` read `currentPage(ui)` **fresh** on every call
(`bbtools.lua:58-63`; `tool_read` L329/366/381 — verified). **No journal record reaches `currentPage`.**
`Conversation:new` rehydration touches only `messages/usage/locators/transcript` — never position-into-gate.
**Hard invariant, enforced by construction:** `anchor`/`bb_meta` are policy/display only and are read
**only** by §8.B–§8.G, never by the gate.

**Belt-and-suspenders (nil-page unclamped read):** `tool_read`'s forward clamp is `if cur then`
(`bbtools.lua:381`) — when `currentPage` is nil there is no clamp, and a restored locator makes an
unclamped read more reachable. **Fix:** in `_assessSpoilerTaint`, if `currentPage(ui)` is not a number,
return `position_unavailable=true`; `resumeSession` then refuses to open the session with the message
*"Reading position unavailable — open the book to a page, then reopen this chat."* We do **not** allow a
turn with no live position when restored locators are present. (Stricter than today, deliberately,
because resume pre-loads locators that make this edge reachable.)

### 8.B Drift measured by xpointer, asymmetrically

Page integers are **not** stable across font/margin/screen changes (the reason the codebase uses
xpointers everywhere). Drift is computed with `ui.document:compareXPointers(anchor.xp, live_xp)`:
```lua
local live_xp = ui.document.getXPointer and ui.document:getXPointer()
local cmp = (anchor.xp and live_xp) and ui.document:compareXPointers(anchor.xp, live_xp) or nil
-- compareXPointers(a, b): 1 => b is after a; -1 => b before a; 0 => equal; nil => unresolved
local direction
if cmp == 1 then direction = "forward"
elseif cmp == -1 then direction = "backward"
elseif cmp == 0 then direction = "same"
else direction = "backward" end          -- unresolved => conservative
```
- **`forward`** (reader advanced): low risk. Re-anchor the model's narrative belief (§8.D) so it doesn't
  under/over-disclose relative to its own stated context. No history scrubbing — stored content is
  behind the new position. The narrative re-anchor fires only on a **chapter-or-greater** advance
  (cheap heuristic comparing `anchor.chapter` to `currentChapter(ui)`, else a large page delta), to
  avoid trivial cache invalidation.
- **`backward`** (reader retreated / re-read): **high risk.** Trigger the history re-gate (§8.C),
  transcript re-gate (§8.E), memory note (§8.F), and consent (§8.G) **at any magnitude** — there is no
  symmetric `math.abs` threshold.
- **`same`**: treat as forward with no re-anchor (no drift).

### 8.C History re-gate on resume (the headline fix) — symmetric and REVERSIBLE

On **every** resume (not just backward), re-gate stored tool_results against the live position:
redact those that drew from **ahead** of the reader, and **restore** previously-redacted ones the
reader has since caught up to. The oracle is `bb_meta.max_referenced_xp` compared with the live
xpointer via `compareXPointers` — layout-stable, unlike a raw page comparison (`at_page`/
`max_referenced_page` were recorded under the layout at execution time; a font change between
save and resume shifts page numbers and a page-only predicate could under-redact — the exact
failure mode §8.B exists to avoid). The stored page int is only the fallback when the tool could
not resolve an xpointer.

```lua
-- "Is this result's furthest-drawn-from position ahead of the live position?"
local function isAhead(meta, taint, ui)
    if meta.spoiler then return true end               -- consent does not travel (LEAK-2)
    if meta.max_referenced_xp and taint.live_xp then
        local ok, cmp = pcall(function()
            return ui.document:compareXPointers(taint.live_xp, meta.max_referenced_xp)
        end)
        -- compareXPointers(a,b)==1 <=> b after a (credocument.lua:750-752). nil = invalid xp.
        if ok and cmp ~= nil then return cmp == 1 end  -- max_xp after live => ahead
        -- unresolved xp comparison: fall through to the page fallback
    end
    if meta.max_referenced_page then
        return meta.max_referenced_page > (taint.live_page or 0)
    end
    return true                                        -- no usable metadata => conservative: ahead
end

local function applyHistoryRegate(restore, taint, ui)
    for _, m in ipairs(restore.messages) do
        if m.role == "user" and type(m.content) == "table" then
            for _, block in ipairs(m.content) do
                if block.type == "tool_result" then
                    local meta = restore.bb_meta[block.tool_use_id]
                    if meta then
                        local ahead = not taint.reveal_all and isAhead(meta, taint, ui)
                        if ahead then
                            if meta.redacted_original == nil then
                                meta.redacted_original = block.content  -- stash: reversible
                            end
                            block.content = REDACTION_STUB
                        elseif meta.redacted_original ~= nil then
                            -- reader caught up (or chose reveal): restore the original
                            block.content = meta.redacted_original
                            meta.redacted_original = nil
                        end
                    end
                end
            end
        end
    end
end
```

`REDACTION_STUB` (model-facing, keeps the block structurally valid so alternation/`validateMessages`
still pass):
```
[Earlier in this chat, content from later in the book was shown. It has been hidden because the reader
is now at an earlier point. It will be restored automatically once they reach that point again, or if
they reopen this chat and choose "Reveal everything". Do not reconstruct it from memory.]
```

Effect: resent `messages[]` no longer carries future-page passages the model could re-quote (LEAK-1),
and **`spoiler=true` content is re-gated — consent does not travel forever** (LEAK-2). Because the
original content is stashed in `bb_meta.redacted_original` — which rides every `checkpoint` (§3.8) —
**redaction is reversible at any generation**: the `finalizeResume` checkpoint of the redacted
history does not destroy the payload, a later *forward* resume automatically un-redacts, and
"Reveal everything" (§8.G) works on the Nth resume, not just the first. (Without the stash, the
first backward resume's forced checkpoint would make redaction permanent — replay reads only the
last checkpoint — and the stub's own "will be restored" promise would be false from generation 2 on.)
*Why metadata, not re-running tools:* re-running every historical tool is slow and may itself drift;
`bb_meta.max_referenced_xp` is the position the result *actually* drew from at execution.
*Rejected:* refusing backward resume (too blunt — re-reads are a primary use case); silent
continuation; irreversible stub-only redaction (destroys reader data + lies in the stub).

### 8.D Narrative re-anchor — one authoritative position (LEAK-4)

On re-anchor we **rewrite the seed's `<book_context>` block in place** to the live position **and**
inject a fresh `<book_context>` in the new user turn, so the model sees exactly **one** authoritative
position (matching the system prompt's "get the reader's current page from book_context",
`bbprompts.lua`). The seed is `restore.messages[restore.seed_index]`; its first text block's `text` has
its `<book_context>...</book_context>` span replaced with a freshly rendered `book_context`
(`Tools.execute("book_context", {}, ui)`). **Splice with plain string ops, never patterns**: locate
the span via `string.find(text, "<book_context>", 1, true)` / `string.find(text, "</book_context>",
1, true)` and rebuild with `string.sub` + concatenation. `gsub` is forbidden here twice over — the
seed block also contains the *untrusted* highlighted passage/note (a passage containing pattern
magic must not be matched), and a `%` in a `gsub` replacement string (guaranteed in book_context's
percent-progress line) corrupts the substitution. The splice provably touches only the span between
the two plugin-generated tags. The rewrite rides into the next journaled `checkpoint`, so a
re-resume stays consistent.
*Rejected:* append-only (leaves a contradictory frozen position — the LEAK-4 bug); model-instruction-only.

### 8.E Transcript render re-gate (LEAK-3)

The transcript is **re-derived from the already-redacted `messages[]`** (§9 + §8.C), so redacted results
render as the stub on screen too. The viewer never shows future-page content the history re-gate removed.
Because we re-derive rather than journal the transcript, this falls out for free — there is no separate
transcript stream to leak.

### 8.F Memory-store interaction (LEAK-5)

`bbmemory` has no position gate; spoiler-safety for `/memories` rests on the prompt (`bbprompts.lua`).
On a **backward** resume, the mandated memory `view` at conversation start could surface notes written
at a later page. We can't scrub the model-owned memory tree from the journal, but on backward resume we
**append a one-time system-context note to the seed's context** (in the same in-place rewrite as §8.D):
*"The reader has moved to an earlier point in the book than when earlier notes were taken; treat any
memory note about later events as spoiler-gated and do not surface it unless explicitly asked."* Full
per-note position gating in `bbmemory` is out of scope but the interaction is no longer silent.

### 8.G Explicit consent for tainted resume (LEAK-2/LEAK-3 belt-and-suspenders)

`_assessSpoilerTaint(restore)` returns `needs_consent=true` when `direction == "backward"` **and**
any `restore.bb_meta` entry is ahead of the live position (`isAhead(meta, taint, ui)`, §8.C — the
xpointer oracle, page fallback) **or** `spoiler_consented`. Because `bb_meta` — including
`redacted_original` stashes — survives every checkpoint (§3.8), this assessment and the dialog
below work identically on the first and the Nth resume: **consent and reveal are per-resume
choices, never one-shot**. Then `resumeSession` shows **one** `ButtonDialog`:
> *"This chat discussed content from later in the book. You're now reading an earlier point. Resume with
> that content hidden?"*
> **[Resume hidden]** **[Reveal everything]** **[Cancel]**

- **Resume hidden** → `_doResume` with `taint.reveal_all=false` (applies §8.C/§8.E/§8.F).
- **Reveal everything** → `_doResume` with `taint.reveal_all=true` (no new redaction; any
  `redacted_original` stashes from earlier resumes are restored into the blocks — works at any
  generation; consent re-granted for this session only).
- **Cancel** → abort.

This is the only added modal, only on the genuinely risky path.

**`_assessSpoilerTaint` return shape:**
```lua
{ direction = "forward"|"backward"|"same",
  live_page = N|nil,
  live_xp = string|nil,               -- ui.document:getXPointer() — primary oracle for §8.C isAhead
  position_unavailable = bool,        -- live_page is not a number
  needs_consent = bool,
  reanchor = bool,                    -- forward chapter-or-greater advance, or any backward
  reveal_all = false }                -- set by the consent dialog choice
```

### 8.H Silent xpointer drift to wrong passage (WRONG-BLOCK-1)

`isXPointerInDocument` (`bbtools.lua:342`) catches *missing* xpointers but not ones that still resolve to
*shifted* text after reflow. Restored locators carry this risk and are marked `stale=true` on rehydrate
(§5.3). The existing `tool_read` path already re-validates a `loc:N` xpointer
(`bbtools.lua:342-348`) and degrades to the page start with an explanatory prefix. We **strengthen** this
for resumed sessions: when a `stale` locator is first used, after `isXPointerInDocument` passes, also
compare the recomputed page against the locator's stored anchor page; if they diverge beyond a small
tolerance, drop the locator and tell the model `loc:N` is no longer available (it can re-grep). This
converts a silent wrong-block into an explicit "locator expired." (Implemented as a guarded extension in
the existing `tool_read` `from = loc:N` branch, behind a `if entry.stale then` check so non-resumed
behavior is unchanged.)

**Net posture:** forward resume = re-anchor + automatic un-redaction of anything previously
stashed; backward/re-read resume = history redaction + transcript redaction + memory note +
explicit consent + locator-staleness — all driven by **xpointer** comparison and the **live** gate,
with a **single authoritative** position in the prompt and **per-session (not permanent)** spoiler
consent. Redaction is **reversible** (§8.C): hidden content is never destroyed, only stashed in the
checkpointed taint map. No stored future content reaches the model or the screen without explicit
per-session consent.

---

## 9. Serialization / deserialization round-trip

### Normalization

- **User content is always a block array on the wire after `buildBody`.** We journal the normalized
  array (`content`) **and** the pre-coercion string (`raw_text`). On replay, `chain_start` detection in
  `_loop` keys on the *pending* user turn's content **not being a table** (it's a string at chain-start,
  before `buildBody` coerces it). To keep live and resumed paths byte-identical at the same point:
  - **The last message, if a user turn, is restored as a bare string** (`raw_text`), matching what the
    live loop sees at chain-start before its own `buildBody` runs.
  - **All earlier user turns are restored as normalized arrays**, matching post-`buildBody` live state.

  Concretely, in `Journal.replay` after the forward loop, run a final pass:
  ```lua
  local last = restore.messages[#restore.messages]
  if last and last.role == "user" and last._raw_text then
      last.content = last._raw_text          -- pending turn: bare string (chain_start parity)
  end
  for i = 1, #restore.messages - 1 do
      local m = restore.messages[i]
      if m.role == "user" and m._raw_text and m.content == nil then
          m.content = { { type = "text", text = m._raw_text } }
      end
  end
  -- strip internal underscore fields before they can reach buildBody:
  for _, m in ipairs(restore.messages) do
      m._raw_text, m._seed = nil, nil      -- taint metadata never rides messages: it lives in
  end                                       -- restore.bb_meta (keyed by tool_use_id), so the wire
                                            -- history is clean by construction
  ```
  This makes the rehydrated array byte-identical to the live array's per-position string-vs-table state.

- **Empty `tool_use.input` → object (C5).** rapidjson decodes `{}` as an empty Lua table, which
  re-encodes as `[]` and 400s ("input: Input should be a valid dictionary"). On replay, `retagEmptyInputs`
  walks every `tool_use`/`server_tool_use` and replaces an empty `input` with `rapidjson.object({})` (or
  tags the existing empty table via `rapidjson.object(input)`), so re-encode emits `{}`. The roundtrip
  spec asserts this for a real no-arg tool (`book_context`/`get_toc`/`get_highlights`).

- **`thinking` preserved byte-equal** (`.thinking` + `.signature`) — resend with adjacent tool_use 400s
  without the signature.

- **`cache_control` never serialized (B3).** The `deepcopyStripped` strip is **required, not
  defensive**: snapshots are taken before *this* round's `buildBody`, but the *previous* round's
  `buildBody` **added** `cache_control={type="ephemeral"}` to the last content block in place
  (`bbanthropic.lua:90-92`), so every post-round-1 snapshot carries exactly one residual marker.
  Spec asserts no `cache_control` key survives into stored `messages[]`.

### Pairing / alternation invariants

1. **Web-search pairing both directions (C6):** `Wire.healWebSearch` runs on **every** restored
   assistant message in `Journal.replay` — forward (append synthetic error result for an orphan
   `server_tool_use`) and reverse (drop a `web_search_tool_result` whose `server_tool_use` id is absent).
   Idempotent. Heals mid-history orphans that the last-message-only `_dropDanglingTail` misses.
2. **Dangling tail (C3):** `finalizeResume` runs `_dropDanglingTail` **after** `_clean_transcript_len`
   was seeded from `restore.clean_transcript_len` in `:new`, so `_trimTranscript` (which early-returns on
   nil, `:667`) actually trims. History then ends on a clean assistant turn (or empty).
3. **`pause_turn` extend:** the replay `assistant_blocks` handler concatenates into the previous
   assistant message exactly as `_storeAssistant`'s `is_resume` branch does (`:601-604`) — source-verified
   identical:
   ```lua
   if ev.extend and prev and prev.role=="assistant" and type(prev.content)=="table" then
       for i=1,#ev.blocks do prev.content[#prev.content+1] = ev.blocks[i] end
   else
       r.messages[#r.messages+1] = { role="assistant", content=ev.blocks }
   end
   ```

### `transcript[]` re-derived (B1)

After `finalizeResume` cleans `messages[]`, `_rederiveTranscript` rebuilds the transcript by walking the
clean `messages[]` through the same per-block ordering `_renderAssistantTurn` uses (assistant text,
thinking, tool-action lines with a summary re-derived from the — possibly redacted — `tool_result`
content). Display-only; never sent. Runtime memo fields (`_md_src`/`_md_out`/`done`) are recomputed, not
persisted (C10) — any deep-equal test excludes them.

### `usage[]` (C8)

Restored from the last `checkpoint.usage` (running total at checkpoint time) **plus** replaying only
`usage_delta` events **after** that checkpoint. Because checkpoints are written *before* a round's
`buildBody`/API call and `usage_delta` is the *per-call increment*, no delta after the loaded checkpoint
is already folded into it → no double-count. Spec asserts restored `usage == live usage` byte-equal
across a pause_turn + tool round.

### Locators (C9)

`checkpoint.locators`/`loc_seq` loaded; on rehydrate `_loc_seq = max(existing_ui_seq, restore.loc_seq)`
and locators are **merged** into the shared `ui` table (no clobber of a concurrent chat). Restored
locators are marked `stale` (§8.H); their xpointers are re-validated on use (`isXPointerInDocument` +
drift consistency). rapidjson string object keys are parsed back to integers in `applyCheckpoint`:
```lua
local function applyCheckpoint(restore, ckpt)
    restore.messages = ckpt.messages or {}
    restore.usage = ckpt.usage or { input=0, output=0, cache_read=0, cache_write=0 }
    restore.clean_transcript_len = ckpt.clean_transcript_len
    restore.loc_seq = ckpt.loc_seq or 0
    restore.locators = {}
    for k, entry in pairs(ckpt.locators or {}) do
        restore.locators[tonumber(k) or k] = entry
    end
    restore.bb_meta = ckpt.bb_meta or {}   -- taint map incl. redacted_original stashes (§3.8);
                                           -- post-checkpoint tool_result events overlay onto it
end
```

### Validation

Every restored `messages[]` must pass `tests/support/sse.lua:validateMessages` (§14) — including after
redaction (§8.C); the redaction stub keeps `tool_result` blocks structurally valid.

---

## 10. Migration & versioning

- **First run:** no `bookbuddy_sessions/`; created lazily on first append; no migration.
- `JOURNAL_VERSION = 1` (int), stamped on every record; separate from `_meta.lua` `plugin_version`
  string `"1.13.3"` (B4 — never conflated).
- **Forward-compat:** unknown event types skipped; unknown fields ignored.
- **Future v2:** a `migrators[1]` function transforms a v1 record array to v2 in memory **before**
  `HANDLERS` run (`local function migrate(records) ... end`, called in `replay`). v1 currently is a no-op
  passthrough.
- `v > JOURNAL_VERSION` ⇒ **non-resumable** in the picker, **never appended** (prevents an older plugin
  — e.g. after a downgrade, or a Syncthing-delivered newer file — from corrupting a newer format).
- No pre-feature conversations exist (the feature is net-new).

---

## 11. Error handling & corruption recovery (never crash the chat)

Every persistence op is best-effort, wrapped by `safeAppend` (§5.3). Chat works **exactly as today**
when persistence is broken/off.

| Failure | Handling |
|---|---|
| Torn / NUL-fill / foreign-JSON tail | truncate-and-stop on read (A1); `Journal.open` rewrites the file once (temp + `os.rename` + fsync) so no in-session append concatenates onto garbage. **No skip-and-continue** (unsafe on FAT). |
| Mid-file undecodable record | truncate-and-stop (everything after is untrusted on FAT) → `truncated=true`. |
| Missing file | `replay` → `nil, "missing"`; picker omits it next scan. |
| No checkpoint left (corruption removed them) | replay from header (correct for state), but `_clean_transcript_len` may be nil ⇒ `_dropDanglingTail` unwind is not single-round-bounded (C7). We **detect** this (`had_checkpoint=false`) and the dropped-tail toast reflects it: *"An interrupted question may have been discarded."* Honest, not silent. (`_clean_transcript_len` falls back to `#transcript` after re-derive so `_trimTranscript` does not over-trim.) |
| Header missing | `nil, "no_header"` — a headerless file is untrusted; never synthesized. |
| `io.open` write failure / disk full | `safeAppend` catches → `writer._broken=true` → persistence off, one toast, **chat continues**. |
| Book moved/renamed (default `doc` sidecar location) | sessions don't follow (same tradeoff as memory, `bbmemory.lua:97-108`); orphaned files under the moved-away `.sdr` are not GC'd by us (documented). `hash` sidecar location follows moves. |
| `.sdr` deleted | `replay` → `nil, "missing"`; new chats start fresh; no crash. |
| rapidjson decode failure on a line | treated as torn tail (truncate-and-stop). |

---

## 12. Concurrency & edge cases

- **Two devices via Syncthing:** per-conversation random-suffix files never collide; `*.sync-conflict*`
  ignored; no merge (last-writer-wins per file). The open-fd window is eliminated (A3 — we never hold the
  fd across a Syncthing write window).
- **Same book open twice (menu chat + selection chat):** each `Conversation` gets its own file (distinct
  suffix) → two writers never touch one file. The shared `ui._bookbuddy_locators` is **merged, not
  clobbered**, and `_loc_seq` is `max`-ed on resume (C9), so resume can't regress a concurrent chat's
  seq. (Two simultaneous live chats sharing one `ui` is a pre-existing limitation we **no longer worsen**.)
- **`_active_conversation` lifetime:** exactly one pinned on `BookBuddy`. Replacing it drops the previous
  reference; **no fd to close** (A3) → no leak. Writer state is flushed-and-fsynced per record, so a
  dropped writer loses nothing.
- **Very long sessions:** no compaction (cut). History grows like a live chat's does; checkpoints keep
  cold-replay bounded to the last ≤16 KiB of events. File size is bounded only by retention (next bullet)
  and the chat's own length — acceptable, same as today's in-memory growth.
- **Empty/aborted sessions:** header+anchor only (user cancelled before any assistant turn) = **dead**;
  not shown in the picker (turn_count with ≥1 completed assistant turn is the visibility rule); pruned on
  the next `create`.
- **Retention:** `Journal.prune(keep)` runs on each `create`, keeping the `session_keep` newest
  non-dead files (by name/recency), deleting the rest. Per-current-book only (the moved-book caveat).
- **Multi-book:** each book's `.sdr` has its own `bookbuddy_sessions/`; the picker only ever lists the
  open book's sessions (`baseDirForBook(ui)` resolves to the open document).

---

## 13. Settings & rollout

| key | default | meaning |
|---|---|---|
| `enable_sessions` | `true` | persist + offer resume |
| `session_keep` | `20` | max retained session files per book (clamp `math.max(1, n)`) |

*Cut:* `session_fsync` (A4), `session_compact_tokens` (compaction cut).

**Default-ON.** Journaling spends **zero** API tokens (local disk only), unlike `enable_memory` (off
because it spends tokens every turn). It degrades silently on any error (§11). The only user-visible
change is a "Resume previous chat…" button when prior sessions exist — additive, no friction on the
new-chat path. Disable + "Clear saved chats" live in the Sessions submenu (behind confirms).

---

## 14. Testing plan

All Tier-1 busted, reusing `tests/support/{stubs,sse}.lua`. **`sse.validateMessages` must pass on every
restored `messages[]`** — including after redaction. New specs:

**`tests/journal_roundtrip_spec.lua`**
- Per-event encode→decode deep-equal (object/array preserved).
- **C5:** a no-arg tool's `tool_use` with empty `input` survives a journal cycle and **re-encodes as `{}`
  not `[]`**; `buildBody(restored)` emits no `"input":[]`.
- **C1:** committed user turns restore as normalized arrays; the **pending** (last) user turn restores as
  a bare string; the full restored array deep-equals the live array position-for-position (string-vs-table
  parity), so `chain_start` detection matches.
- **B3:** no `cache_control` key survives into stored/restored `messages[]`.
- `thinking.signature` byte-equal after round-trip.

**`tests/journal_torn_tail_spec.lua`** (FAT semantics, A1)
- Byte-truncated tail → recover all but last, `truncated=true`.
- NUL-padded tail (FAT power-loss sim) → truncate-and-stop at first NUL, recover prefix.
- Foreign-JSON / block-garbage tail → truncate-and-stop (assert prefix kept, garbage dropped; **not**
  skip-and-continue).
- Mid-file corruption → truncate-and-stop (everything after dropped), no crash.
- `Journal.open` on a torn file rewrites it once (temp+rename) then appends cleanly.

**`tests/journal_dangling_spec.lua`** (C3 crux)
- Chain ending `[assistant tool_use][user tool_result]` (crash mid-round) → replay → construct →
  `finalizeResume` → assert `_clean_transcript_len` was seeded, `_trimTranscript` ran (no orphaned
  transcript entries), history ends clean, `validateMessages` passes, next `ask` produces no
  consecutive-user 400.
- Multi-round dangling **with** a checkpoint → unwind bounded to the last round.
- Multi-round dangling **without** a checkpoint → unwinds further; `finalizeResume` reports
  `from_header=true`; toast wording reflects it (C7).

**`tests/journal_websearch_spec.lua`** (C6)
- Reverse-orphan `web_search_tool_result` on a **non-last** message → `Wire.healWebSearch` removes it →
  `validateMessages` passes.
- Forward-orphan `server_tool_use` → synthetic error result added.
- pause_turn: two `assistant_blocks`, second `extend=true` → one merged assistant message; the
  `server_tool_use` + result stay together.

**`tests/journal_usage_spec.lua`** (C8)
- Checkpoint(total) + later `usage_delta`s → restored `usage == live usage` byte-equal across a
  pause_turn + tool round; no double/under-count.

**`tests/journal_locator_spec.lua`** (C9)
- Checkpoint locators/loc_seq → rehydrate **merges** into a pre-populated `ui` table; `_loc_seq == max`;
  a concurrent chat's higher seq is not regressed; a new `mintLocator` returns `max+1` (no collision);
  string object keys parsed back to integers; restored locators marked `stale`.

**`tests/journal_spoiler_resume_spec.lua`** (mandatory, symmetric)
- **Forward:** seed page 10, live page 200 → `tool_grep`/`tool_read` gate against **200** (live, not
  stored); narrative re-anchor rewrites the seed `book_context` in place (one authoritative position,
  LEAK-4); `validateMessages` passes.
- **Backward (LEAK-1):** seed/history drew from page 200, live page 10 → history re-gate redacts those
  tool_results to the stub; restored `messages[]` carries no page-200 payload; `validateMessages` still
  passes (stub keeps structure).
- **Spoiler consent (LEAK-2):** a stored `spoiler=true` result is redacted on backward resume unless
  "Reveal everything" was chosen.
- **Transcript re-gate (LEAK-3):** re-derived transcript shows the redaction stub, not future content.
- **Drift by xpointer (WRONG-BLOCK-3):** a font-size change inflating page numbers but not the xpointer →
  **no** spurious backward trigger; a real xpointer-backward move → triggers re-gate.
- **Position-unavailable (8.A):** live `currentPage` nil + restored locators → `resumeSession` aborts
  with the warning; no unclamped read.
- **Memory note (LEAK-5):** backward resume injects the memory-spoiler note into the seed.
- **Generation-2 taint survival (the checkpoint-permanence trap):** backward resume → redact →
  `finalizeResume` forced checkpoint → replay the journal *again* → `bb_meta` (including
  `redacted_original` stashes and `spoiler` flags) survives via `checkpoint.bb_meta`; a second
  backward resume still detects taint and shows the consent dialog.
- **Reversibility:** after redaction + checkpoint, a **forward** re-resume auto-restores the
  original `tool_result` content (stub gone from wire and re-derived transcript); "Reveal
  everything" chosen on a generation-2 backward resume also restores it.
- **xpointer oracle beats page fallback:** a layout change inflates page numbers
  (`max_referenced_page > live_page`) but `compareXPointers(live_xp, max_referenced_xp) ~= 1`
  (content actually behind the reader) → **not** redacted; with `max_referenced_xp = nil` the page
  fallback applies and redacts; with neither field usable → conservative redact.

**`tests/conversation_spec.lua`** (extend)
- With a recording fake writer injected: assert `user_turn`(normalized)+`anchor` on ask; `checkpoint`
  only when the bytes-threshold is crossed (not every chain); `assistant_blocks` with correct `extend`;
  `tool_result`+`bb_meta`; `usage_delta` as a per-call **delta** (not the running total). Assert **no**
  `transcript_delta` and **no** per-mint `locator` events are emitted (cuts).

**`tests/journal_errors_spec.lua`**
- Missing file → `nil,"missing"`. `v>JOURNAL_VERSION` → `list` marks `resumable=false`,
  `replay` → `nil,"newer_version"`. Headerless → `nil,"no_header"`. Simulated `io.open` failure →
  `writer._broken`, live turn still completes (no throw out of `ask`).

**`tests/support/stubs.lua`** additions
- `DocSettings.getSidecarDir` → a tmp dir; `lfs`/`io.open` tmp harness (luafilesystem is already in the
  dev shell); `ffiUtil.fsyncOpenedFile`/`fsyncDirectory` no-op stubs; a `fake_journal_writer` recorder;
  a `compareXPointers`/`getXPointer`/`isXPointerInDocument` stub for drift tests; `Tools.captureAnchor`
  stub returning controllable `{xp,page,total,chapter}`.

**Tier-2 (opt-in, `tests/integration/real/resume_real.lua`):** real crengine over `juliet.epub`; journal
a couple turns, replay, assert locator xpointers re-validate, **and** assert the **drift** case
(WRONG-BLOCK-1): force a layout change and confirm a restored locator whose xpointer now resolves to
shifted text is treated as stale/expired, not silently read. Not part of `nix run .#check`.

---

## 15. Implementation checklist (ordered, commit-sized; gate after each)

1. **`bbwire.lua`** — move `pairDanglingWebSearch` → `Wire.healWebSearch` (both directions, C6);
   `require` and call it from `bbconversation.lua:528`. Existing specs stay green. (Gate.)
2. **`bbjournal.lua` durability core** — `JOURNAL_VERSION`, `CHECKPOINT_BYTES`, `baseDirForBook`,
   `appendRecord` (open/write/flush/fsync/dir-fsync-once/close, A1-A3), `readRecords`
   (truncate-and-stop incl. NUL/garbage, A1), `create`/`open` (open rewrites torn tail atomically),
   file naming, lazy mkdir. + `journal_roundtrip_spec` + `journal_torn_tail_spec`. (Gate.)
3. **`bbjournal.replay` + restore + HANDLERS** — header check, `user_turn` (normalized + raw_text,
   string-vs-array final pass C1), `assistant_blocks` (extend), `tool_result`+`bb_meta` aggregation,
   `usage_delta` (C8), `checkpoint`/`applyCheckpoint` (string-key parse C9), `retagEmptyInputs` (C5),
   `Wire.healWebSearch` on every assistant message (C6), `migrate` no-op (§10). + `journal_usage_spec`
   + `journal_websearch_spec`. (Gate.)
4. **`bbtools.lua` additions** — `Tools.captureAnchor(ui)`; extend `Tools.execute` to return `meta`
   (`{at_page,spoiler,max_referenced_page}`) for grep/read/book_context (read-only). + assertions in
   `tools` specs that `meta` matches the gate's own numbers. (Gate.)
5. **Wire writes into `bbconversation.lua`** — `safeAppend`; open writer in `:new` (create branch only,
   no restore yet); `_captureAnchor`/`_snapshot` (pre-`buildBody`, stripped, B3); appends at
   ask/threshold-checkpoint/_storeAssistant/tool_result/usage; thread `bb_meta` from the tool loop.
   Fake writer in `conversation_spec`; assert the cuts (no `transcript_delta`/`locator` events). (Gate.)
6. **Resume construction** — `:new` restore branch (messages/usage; locator merge + max-seq C9; seed
   `_clean_transcript_len` C3); `finalizeResume` (drop tail → `_rederiveTranscript` B1 → forced
   checkpoint). + `journal_dangling_spec` + `journal_locator_spec`. (Gate.)
7. **Spoiler-safe resume (§8)** — `_assessSpoilerTaint` (xpointer drift 8.B, position-unavailable 8.A),
   `applyHistoryRegate` (8.C), seed `book_context` in-place rewrite + memory note (8.D/8.F),
   `_rederiveTranscript` re-gate falls out of B1 (8.E), consent dialog (8.G), locator staleness in
   `tool_read` (8.H). + `journal_spoiler_resume_spec`. (Gate.)
8. **`main.lua` UX** — "Resume previous chat…" button on the input dialog (no modal); `resumePicker`
   (confirms on delete/clear); `resumeSession`/`_doResume`/`_confirmTaintedResume`; pin
   `_active_conversation`; mandatory "Resumed chat" subtitle; dropped-tail toast. Cover non-UI
   `resumeSession`/`_assessSpoilerTaint` in a spec. (Gate.)
9. **`bbsettings.lua`** — `enable_sessions`, `session_keep`; Sessions submenu (toggle + confirmed clear).
   + `settings_spec` additions. `Journal.list`/`delete`/`clearAll`/`prune`(on create) + `journal_errors_spec`. (Gate.)
10. **Tier-2 `resume_real.lua`** (drift case incl.). Bump `_meta.lua` `version`. Update `AGENTS.md` /
    `README` (new modules, settings, FAT-durability + backward-resume-redaction notes). (Gate + manual real run.)

*(No compaction commit — cut.)*

---

## 16. Risks, trade-offs, and open questions

**Accepted trade-offs**
- **fsync-per-record latency on cheap eMMC/SD.** Mitigated by tiny records, off-the-tool-path timing, and
  a flippable internal constant. Not a user knob (A4). *Risk if wrong:* a perceptible hitch at each
  record on the slowest devices; the flush-only fallback is one line.
- **No compaction.** A pathologically long single chat grows unbounded in the file (and in memory, as
  today). Acceptable: live chats already do this; retention caps the number of files, not one file's size.
- **Moved/renamed book (default `doc` sidecar) orphans sessions.** Same limitation as memory; documented.
  `hash` sidecar location avoids it.
- **`bbmemory` has no position gate.** Backward resume mitigates via a prompt-level note (§8.F), not a
  hard gate. A determined model could still surface a later-page memory note; this matches today's
  prompt-only protection and is explicitly out of scope to fully fix here.
- **Re-derived transcript loses exact original wording of tool-action summary lines.** Re-derivation
  reconstructs them from `messages[]`; cosmetic-only, never sent to the API.

**Honest residual risks**
- **`max_referenced_xp`/`max_referenced_page` precision (§8.C).** Redaction is only as good as the
  furthest position each tool reports it drew from. If a `grep` summary line references a position
  the metadata under-reports, a sliver could leak on backward resume. Mitigation: the metadata is
  computed from the same data the result is built from; the xpointer oracle removes the
  layout-drift failure mode a raw page comparison would have (a font change between save and
  resume shifts page numbers, and a page-only predicate could under-redact); the consent dialog is
  the backstop for the remainder.
- **xpointer drift heuristics (§8.B/§8.H).** `compareXPointers` direction + a page-tolerance check are
  heuristics; an adversarial reflow could theoretically misclassify. The conservative default (unresolved
  ⇒ backward ⇒ protected) and the consent gate bound the blast radius toward *over*-hiding, never
  *under*-hiding.

**Open questions**
1. **Page-tolerance for stale-locator drop (§8.H):** exact tolerance (proposed: drop if recomputed page
   differs from the locator's stored anchor page by > 1, configurable as an internal constant). Needs one
   real-device calibration run (Tier-2) to settle the number.
2. **`first_question` / `turn_count` scan depth in `list` (§5.1):** capped at the first ~40 lines; a
   session whose seed somehow lands beyond that (it never should — the seed is line 2) would show a blank
   label. Confirm the cap is comfortably above the worst real header+anchor+seed prefix (it is: 3 lines).
3. **Header `book_md5`:** currently informational only. If we ever want the picker to refuse a file whose
   `book_md5` mismatches the open book (defense against a mis-synced sidecar), decide whether to compute
   the full md5 (slow) or keep the partial one KOReader already has. Left informational for now.
