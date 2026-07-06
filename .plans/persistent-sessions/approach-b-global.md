# Persistent Sessions — B — Global indexed session manager (scoped to per-book MVP)

**Status: implementation-ready.** This is the complete, buildable-from spec. Every design
decision is made; there are no TODOs. Where a reviewer critique was rejected it is marked
`REJECTED:` with a one-line reason. The "indexed" in the title is historical: the MVP ships
**index-free** (a single-shard directory scan replaces the global index; see §1 non-goals and
§3.3). The blob store and all resume/spoiler machinery are in scope.

All file:line anchors below were verified against the working tree on the `claude/audit-fixes`
branch and against `~/repos/clones/koreader`.

> **Anchor drift (re-checked 2026-07-02):** the tree has since grown — every `bbconversation.lua`
> anchor below is ~90–130 lines low (e.g. `:174` → `:260`, `:225` → `:340`, `:623` → `:751`); the
> cited behaviors were re-verified unchanged. New since verification: the `ask_user`
> clarifying-question tool (`bbconversation.lua:287-294`, `:688-697`, `:961-977`) adds a
> **parked-turn** state (coroutine suspended awaiting the reader's answer). A parked turn is not
> resendable, so the `_in_flight`/`_isResendable` firing guard (§5.2) already skips it; a close
> during a parked question loses that turn — the same accepted posture as any in-flight loss (§16).

---

## 1. Summary & goals

A BookBuddy chat survives KOReader restart, book close, and plugin reload. Today the
conversation lives only in a live in-memory `Conversation` instance (`bbconversation.lua:171`)
and is lost on GC — there is no session id, no serialization, no timestamps.

A **session** is a serialized snapshot of:

- the wire `messages[]` array (`bbconversation.lua:174`) — the Anthropic-shaped history that is
  resent every turn; the only correctness-load-bearing structure;
- the `transcript[]` display log (`bbconversation.lua:175`);
- the `usage` accumulator (`bbconversation.lua:221`);
- a metadata header including a **config fingerprint** (§9.3) and a **position snapshot** (§8).

Sessions live in a **device-global, content-hash-sharded blob store** keyed by
`util.partialMD5(ui.document.file)` (verified `frontend/util.lua:1111`), so they survive a book
move/rename. Each blob is **self-describing and self-sufficient**: a session is fully resumable
from its blob alone, with no index.

### In scope (MVP)

- Per-turn **debounced autosave** at clean termini, crash-safe on FAT/exFAT e-reader filesystems.
- **Resume a session for the currently open book** into a live `Conversation` that takes the next turn.
- A **Continue / New** chooser on the primary "Chat about this book" entry, killing invisible forking.
- A per-book **resume picker** (single-shard scan, no global index).
- **Spoiler-safe resume** via history quarantine + live re-anchor (§8) — airtight.
- **Config-drift safety** for `enable_thinking` / `enable_web_search` / `enable_memory` (§9.3).

### Non-goals (deferred — paired with the index that would serve them)

- **Cross-book library** (`showSessionLibrary`, read-only cross-book view) and the **global
  `index.lua`**. The index's only real purpose is zero-blob cross-book browsing; with the library
  gone its reason to exist evaporates. Ships as a clean follow-on *paired with* cross-book resume.
- **Cross-book resume** (asking a follow-up on a non-open book): needs `ReaderUI:showReader`
  orchestration + verified hash→path. Follow-on.
- Multi-device merge, server-side auto-titles, branching/editing, size-based eviction.

---

## 2. Design rationale & the core bet

**Elevator pitch.** Persist each chat as a self-sufficient rapidjson blob under a
content-hash-sharded directory. To resume, scan the open book's one shard directory, show a
picker, load the chosen blob, rebuild a live `Conversation`. No index, no cross-book machinery,
no double-encode.

**The core bet (two load-bearing decisions).** The store mechanics (sharding, atomic write) are
supporting infrastructure. The two decisions the whole feature stands on are:

1. **The live-gate-vs-frozen-belief spoiler model with history quarantine (§8).** A resumed
   conversation carries a *frozen* reading position in its history, but the live tool gate
   recomputes `currentPage(ui)` per call (`bbtools.lua:199,366,406`). The hard case is a
   **backward** resume (reader is now earlier than when the chat happened): the frozen history
   itself becomes a spoiler surface the gate cannot touch. We quarantine it.

2. **The config fingerprint that makes a restored history a *valid* request despite settings
   drift (§9.3).** If the user toggled `enable_thinking` off between save and resume, the stored
   `thinking` blocks in history would 400 the next request. The fingerprint + per-conversation
   overrides reconcile this *before any resend*.

**Why blobs, not a LuaSettings `dump`.** `tool_use.input` for a no-arg tool (`book_context`,
`get_toc`) must re-encode as a JSON **object** `{}`, not an array `[]`, on resend. rapidjson
preserves this across one `decode→encode` (documented at `bbanthropic.lua:2-3`:
"buildBody/decode run in the main process (rapidjson keeps the object/array distinction across
decode→encode so tool_use inputs round-trip correctly)"). We store `messages` as a normal nested
JSON value (single encode) and, on load, run `_normalizeToolInputs` to *re-assert* object-ness
unconditionally (§9.2) — so correctness never hinges on the metatable surviving serialization.

**Why a global store, not the `.sdr` sidecar.** Survives book move/rename via hash, unlike
memory's sidecar (`bbmemory.lua` baseDirForBook). Accepted cost: sessions don't travel with the
book (§16).

---

## 3. Data model

### 3.1 In-memory (already held by `Conversation`, `bbconversation.lua:171-223`)

```lua
-- Conversation fields relevant to persistence (existing):
o.messages   = {}  -- wire array, exact Anthropic shape, resent every turn (:174)
o.transcript = {}  -- display log (:175)
o.usage      = { input = 0, output = 0, cache_read = 0, cache_write = 0 }  -- (:221)
-- selected_text / note carried for the seed (:229-253), title (new)
```

**Wire block types** (`bbconversation.lua` `_split`/`_storeAssistant`):
- `text` — `{ type="text", text=<string> }`
- `thinking` — `{ type="thinking", thinking=<string>, signature=<string> }`
- `tool_use` — `{ type="tool_use", id=<string>, name=<string>, input=<object> }`
- `server_tool_use` — `{ type="server_tool_use", id=<string>, name=<string>, input=<object> }`
- `web_search_tool_result` — `{ type="web_search_tool_result", tool_use_id=<string>, content=… }`
- `tool_result` — `{ type="tool_result", tool_use_id=<string>, content=<string> }` (appended as a
  `{role="user"}` message at `bbconversation.lua` tool loop, the `self.messages[#…+1]` after the
  for-loop).

**Transcript entry shapes** (`bbconversation.lua`): `{role="user"|"assistant"|"tool", text=…,
done=…}`. Memo fields `_md_src`/`_md_out` may be attached by the renderer and **must be
stripped** on serialize (§9.1). `role="tool"` entries (the tool-action lines) carry `.text` and
**must be carried through** (C10).

### 3.2 On-disk session blob (rapidjson, single-encoded)

Path: `…/bookbuddy_sessions/<hh>/<hash>/<session_id>.json`

```json
{
  "schema": 1,
  "session_id": "1717603200-3f9a2c8e1b04a7d2f0c9e3b1",
  "book_hash": "9b1c4e7a0d3f5b8c2e1a6d4f7b0c3e9a",
  "created": 1717603200,
  "last_active": 1717689600,
  "turn_count": 4,
  "title": "Who is the masked figure?",
  "book": {
    "title": "Juliet",
    "author": "Anne Fortier",
    "last_known_path": "/mnt/ebooks/juliet.epub"
  },
  "config_fingerprint": {
    "enable_thinking": true,
    "enable_web_search": true,
    "enable_memory": true,
    "model": "vertex/claude-opus-4-8@eu"
  },
  "position": {
    "xpointer": "/body/DocFragment[12]/body/div/p[7]/text().0",
    "percent": 0.2779,
    "page": 142,
    "page_count": 511,
    "chapter": "Chapter 9",
    "paging_doc": false
  },
  "seed": { "selected_text": "the masked figure at the window", "note": null },
  "usage": { "input": 18240, "output": 3120, "cache_read": 14000, "cache_write": 4000 },
  "messages": [ /* wire array, nested JSON value, single-encoded (NOT a JSON string) */ ],
  "transcript": [
    { "role": "user", "text": "Who is the masked figure?" },
    { "role": "assistant", "text": "Without spoiling ahead..." }
  ]
}
```

**Field table (every field typed):**

| Field | Type | Source / purpose |
|---|---|---|
| `schema` | int | =1. `schema > 1` blob → **ignored entirely** in MVP (logged, not surfaced; §10). |
| `session_id` | string | `os.time() .. "-" .. <24 hex chars>` — **96-bit** random suffix (collision-safe; C8). |
| `book_hash` | string | `Session.bookHash(ui)` (reuses KOReader cached `doc_hash`, else `partialMD5`; §5.2). |
| `created` | int | `os.time()` at first save. |
| `last_active` | int | `os.time()` at each save. May be 0/implausible on RTC-less devices (§5.3, §11). |
| `turn_count` | int | `#transcript` user entries, for display. |
| `title` | string | `Session.titleFromSeed` (first user question, clipped ~60 codepoints; §7.3). |
| `book.title/author` | string | `ui.document:getProps()` (`bbtools.lua:456`), for picker rows + future cross-book. |
| `book.last_known_path` | string | `ui.document.file` at save; advisory only (resume uses hash + open doc). |
| `config_fingerprint` | object | `enable_thinking`/`enable_web_search`/`enable_memory`/`model` at save. **Load-bearing** (§9.3). |
| `position.xpointer` | string\|nil | Precise locator; the **safety-relevant** drift comparison uses this via `compareXPointers` (§8). |
| `position.percent` | number\|nil | Display only. |
| `position.page` | int\|nil | Display only (layout-dependent; **not** used for the safety decision). |
| `position.page_count` | int\|nil | Display only. |
| `position.chapter` | string\|nil | Display only. |
| `position.paging_doc` | bool | True if `currentPage` was nil at snapshot (paging doc). Marks a spoiler-degraded session (§8.4). |
| `seed` | object | `{selected_text, note}` — restored **only** on the empty-history re-seed path (§5.2 C3). |
| `usage` | object | 4 ints restored onto `conv.usage` (§9.5). |
| `messages` | array | Wire history as a **nested JSON value** (single encode). |
| `transcript` | array | Display log; `{role, text}` (and optional `done`). |

**Encoding rule.** `messages` is a normal nested JSON value (single `rapidjson.encode` of the
whole blob). On load, `_normalizeToolInputs` walks every `tool_use`/`server_tool_use` and forces
empty `input` to `rapidjson.object({})` (`bbtools.lua` builds empty-object inputs the same way).
**Double-encoding is removed** — single decode→encode preserves object-ness per
`bbanthropic.lua:2-3`, and `_normalizeToolInputs` is the belt-and-suspenders that makes
correctness not *depend* on the metatable surviving.

### 3.3 No index (MVP)

There is **no `index.lua`**. Listing is a directory scan of the open book's single shard dir
`bookbuddy_sessions/<hh>/<hash>/`, reading only each blob's header. Bounded by
`SESSIONS_PER_BOOK_LIMIT` (≤30 files), lazy, only when the picker opens. A `<id>.hdr.json`
header sidecar (§E in §5.1.1) keeps the scan cheap on weak CPUs. Cutting the index removes the
dangling-entry invariant, `rebuildIndex`, and the Syncthing index-conflict hazard entirely (§12).

---

## 4. On-disk layout

```
<DataStorage:getSettingsDir()>/
├── bookbuddy.lua                       # existing global config (LuaSettings, bbsettings.lua)
└── bookbuddy_sessions/                 # NEW, created lazily (util.makePath on first save)
    └── 9b/                             # shard = book_hash:sub(1,2)
        └── 9b1c4e7a0d3f5b8c2e1a6d4f7b0c3e9a/   # full book_hash
            ├── 1717603200-3f9a2c8e1b04a7d2f0c9e3b1.json      # blob
            ├── 1717603200-3f9a2c8e1b04a7d2f0c9e3b1.hdr.json  # tiny header sidecar (blob minus messages/transcript)
            └── 1717690000-7e1b9d4f22a1c3e5a8b0d6f4.json
```

- Sharding mirrors KOReader's `docsettings.lua` `hsh:sub(1,2)` convention.
- `DataStorage:getSettingsDir()` is the same dir holding `bookbuddy.lua` (bbsettings).
- `util.makePath` on first save (as memory does for its sidecar tree).
- **No index file.**

---

## 5. Module-by-module changes

### 5.1 NEW `bbsession.lua` — public API (index-free)

```lua
local Session = {}

-- ---- Identity --------------------------------------------------------------
function Session.bookHash(ui)        -- -> string|nil. Reuses KOReader's cached doc_hash (§5.2).
function Session.rootDir()           -- -> DataStorage:getSettingsDir() .. "/bookbuddy_sessions"
function Session._shardDir(hash)     -- -> rootDir() .. "/" .. hash:sub(1,2) .. "/" .. hash

-- ---- Listing (single-shard scan, NO global index) --------------------------
function Session.listForBook(hash)   -- -> array of header tables, sorted last_active desc
                                     --    reads *.hdr.json (fallback: blob header); see §5.1.1
function Session.hasResumable(ui)    -- -> bool. Cheap: any non-empty *.json in this book's shard?

-- ---- Blob read/write (single-encode; deep-copied input; FAT-safe) ----------
function Session.serialize(snapshot) -- -> string. snapshot is a DEEP COPY (never the live conv; C7).
function Session.save(conv)          -- -> id|nil, err. Crash-safe write (§5.1.1); prunes to limit.
function Session.load(id, hash)      -- -> {meta, messages, transcript, usage}|nil, err. Normalizes inputs.
function Session.delete(id, hash)    -- removes blob + .hdr sidecar; idempotent.

-- ---- Helpers ---------------------------------------------------------------
function Session.titleFromSeed(messages, transcript)  -- -> string (§7.3)
function Session.snapshotPosition(ui)                 -- delegates to Tools.snapshotPosition(ui) (§5.6)
function Session.configFingerprint(settings)          -- -> {enable_thinking,enable_web_search,enable_memory,model}

local SESSIONS_PER_BOOK_LIMIT = 30   -- module constant, NOT a user setting (nobody tunes it)
return Session
```

#### 5.1.1 `Session.save` — crash-safe on FAT/exFAT

The 5-arg `util.writeToFile(data, filepath, force_flush, lua_dofile_ready, directory_updated)`
(verified `frontend/util.lua:1141`) calls `ffiUtil.fsyncDirectory(filepath)` when
`directory_updated` is true (`util.lua:1156-1157`; `base/ffi/util.lua:597`). Sequence:

1. **Snapshot under a deep copy.** `serialize` receives `snapshot = conv:_snapshotForPersist()`
   (§5.2) — a deep copy of `messages` + cleaned `transcript` + `usage` + meta. **Serialize never
   touches the live conversation** (C7).
2. **Skip empty/aborted.** If the snapshot's `messages` is empty, or `transcript` has no
   `assistant` entry, return `nil` early — no litter from cancelled chats (§12).
3. **Write-new, never rename-over-existing.** Mint a fresh tmp name
   `<id>.json.<rand>.tmp`; write via `util.writeToFile(s, tmp, true, false, false)`
   (`force_flush=true` → file fdatasync); then publish:
   ```lua
   -- FAT/exFAT rename-onto-existing may fail EEXIST. Rename-FIRST (atomic replace on POSIX,
   -- which is the common internal-storage case); remove only in the FAT fallback:
   local ok = os.rename(tmp, final)
   if not ok then
       os.remove(final)                        -- FAT fallback ONLY: brief window with no visible blob
       ok = os.rename(tmp, final)              -- (bytes survive in the fsynced .tmp; see below)
   end
   ```
   On POSIX the rename is atomic-over-destination — no window at all. In the FAT fallback, a
   power-loss between remove and rename leaves **no visible blob**: the data survives only in the
   fsynced `.tmp`, which listing ignores. Two mitigations keep that survivable: (a) tmp GC is
   **age-gated** — a stale `.tmp` is reaped only when older than ~10 minutes AND a live `.json`
   exists for that id, so a crash in the fallback window never gets its sole copy reaped; (b) the
   window only exists on FAT external storage and spans two syscalls. Do **not** claim
   "old or new always intact" in code comments — that holds on POSIX, not in the FAT fallback.
4. **Directory fsync via the header sidecar.** Write the header sidecar `<id>.hdr.json` **last**
   with `directory_updated=true`:
   `util.writeToFile(hdr, hdr_path, true, false, true)` — landing in the same directory triggers
   `fsyncDirectory`, durably persisting both the blob's and the sidecar's dirents. The sidecar's
   successful presence therefore implies the blob dirent is durable.
5. **Prune.** After publish, list `*.json` (non-`.tmp`) in the shard dir; if `> LIMIT`, delete
   the oldest by `last_active` (blob + its `.hdr.json`).

**Crash matrix.** Crash before (3) → stale `.tmp`, ignored by listing (only non-`.tmp` `*.json`
scanned), GC'd on a later save **only when older than ~10 minutes AND a live `.json` exists for
that id** (the age+liveness gate protects the sole-copy `.tmp` from the FAT-fallback window
above). Crash between blob-rename and hdr-write → blob durable, hdr missing → listing falls back
to reading the blob header and rewrites the hdr (§11). Never a corrupt visible state on POSIX; on
FAT the §5.1.1 fallback window applies.

`REJECTED (feasibility-B "write a new blob id per save"):` we keep a **stable id per session** so
resume overwrites rather than forks — using fresh-tmp + remove-then-rename for FAT safety without
id churn. New-id-per-turn would litter the shard dir and break "continue this session."

### 5.2 `bbconversation.lua`

**Cache `book_hash` cheaply.** In `Conversation:new`'s `if o.ui then` block (`bbconversation.lua:191-197`,
where it already clears `_bookbuddy_*` stale state), add:
```lua
o.book_hash  = Session.bookHash(o.ui)   -- computed once
o.session_id = nil                      -- minted on first save
o._dirty     = false                    -- set on ask()/_storeAssistant, cleared on save (C11)
o._in_flight = false                    -- true during a _loop round body (C6)
```
`Session.bookHash` **reuses KOReader's already-computed sidecar hash** to avoid an extra
file-open + 11 seeks on the hot path: resolution order
`o.ui.doc_settings and o.ui.doc_settings.doc_hash` → else `util.partialMD5(o.ui.document.file)`.

**`_snapshotForPersist()` (NEW) — read-only deep copy (C7).**
```lua
-- Returns { messages=<deep copy, normalized, tail-trimmed>, transcript=<cleaned copy>,
--           usage=<copy>, meta=<fresh> }. Operates entirely on COPIES: runs the
-- dangling-tail / web-search-pairing predicates on the COPY so the live conversation
-- is never mutated by a save (C6/C7). Strips _md_src/_md_out from transcript entries;
-- carries role=="tool" entries' .text (C10).
function Conversation:_snapshotForPersist()
```

**`_isResendable()` (NEW) — non-mutating predicate** mirroring `_dropDanglingTail`'s test
(`bbconversation.lua:623-651`) WITHOUT mutating: returns false when the live tail is a dangling
user turn or an assistant turn with an unpaired `tool_use`/`server_tool_use`. Used by the
debounce firing guard.

**Debounced autosave — guard the FIRING, not just the scheduling (C6).** The 3s timer can fire
mid-`_loop` because the coroutine yields to the same UIManager loop (`bbconversation.lua` the
`UIManager:nextTick`+`coroutine.yield()` boundary inside `_loop`).
```lua
local PERSIST_DEBOUNCE_SEC = 3.0
function Conversation:_persist()
    if not (self.settings and self.settings:getConfig().enable_sessions) then return end
    if not self.book_hash then return end
    if not self._dirty then return end                 -- C11: viewing a resumed chat doesn't re-save
    if self._persist_task then return end
    self._persist_task = function()
        self._persist_task = nil
        -- C6: scheduling happens at a clean terminus, but the timer can FIRE mid-_loop.
        -- If not currently resendable, do NOT serialize (and never _dropDanglingTail the
        -- LIVE object) -- reschedule and let the next clean terminus re-arm.
        if self._in_flight or not self:_isResendable() then
            UIManager:scheduleIn(PERSIST_DEBOUNCE_SEC, self._persist_task)  -- re-arm
            return
        end
        local ok, err = pcall(function()
            local id = require("bbsession").save(self)
            if id then self._dirty = false end
        end)
        if not ok then require("logger").warn("BookBuddy: session save failed:", err) end
    end
    UIManager:scheduleIn(PERSIST_DEBOUNCE_SEC, self._persist_task)
end
```
Set `self._in_flight = true` at the top of each `_loop` round body and `= false` at every
exit/terminus, so the firing guard has an explicit flag in addition to the structural predicate.

**`flushNowPersist()` (NEW)** — cancel the debounce via `UIManager:unschedule(self._persist_task)`
**and clear `self._persist_task = nil`** (the re-arm path in `_persist` re-schedules the same
closure, so an unschedule without the nil-out would let a re-armed timer fire after document
teardown); only if `_isResendable()` **and** `_dirty`, synchronously
`require("bbsession").save(self)` and clear `_dirty`. If not resendable (a turn genuinely in
flight at close), skip — better to lose the in-flight turn than corrupt it.

**Persist call site — single hook.** Add `self:_persist()` at the **end of `_render()`**
(`bbconversation.lua` `_render`, after `UIManager:show(self.viewer)`). `_render` is the one
function reached at every clean terminus: normal answer, budget-exhausted, empty-200 placeholder,
and pause-limit. **No persist in the pause/tool branches.** Also set `self._dirty = true` in
`ask()` (so a new turn marks dirty) and clear `_in_flight` appropriately.

**Resume constructor `fromSession` (NEW).**
```lua
function Conversation:fromSession(o, loaded)
    Conversation.new(self, o)                 -- clears ui locators (:191-197), builds tool_specs/memory,
                                              -- applies CURRENT settings tool gating, zeroes usage
    self.messages   = loaded.messages         -- already decoded + input-normalized (§9.2)
    self.transcript = loaded.transcript or {}
    self.usage      = loaded.usage or self.usage
    self.session_id = loaded.meta.session_id  -- overwrite, NOT fork
    self.book_hash  = loaded.meta.book_hash
    self.title      = loaded.meta.title
    self._saved_fingerprint = loaded.meta.config_fingerprint
    self:_reconcileConfigDrift(loaded.meta)   -- §9.3 -- MUST run before any resend
    local n_before = #self.messages
    self:_dropDanglingTail()                  -- repair tail
    self:_syncTranscriptToMessages(n_before)  -- C4: keep transcript <= messages, no silent desync
    self:_armResumeReanchor(loaded.meta)      -- §8 -- sets _pending_resume_note OR _reanchor_via_seed
    self._dirty = false                       -- C11: mere load is not dirty
    return self
end
```

**C4 fix — `_dropDanglingTail` on load must not silently desync transcript.** On a fresh
`fromSession`, `_clean_transcript_len` is nil, so `_trimTranscript` no-ops
(`bbconversation.lua:653-666`) even if wire messages were dropped. Add
`_syncTranscriptToMessages(n_before)`:
```lua
-- If _dropDanglingTail removed wire messages (#messages < n_before), trim the
-- transcript back to the entry corresponding to the surviving last assistant turn,
-- so the displayed conversation == the resendable one. If nothing was dropped
-- (the normal saved-at-terminus case), this is a no-op.
function Conversation:_syncTranscriptToMessages(n_before)
```

**C3 fix — empty-after-tail-drop re-enters the seed branch correctly.** If `_dropDanglingTail`
empties `messages` (e.g. a session whose only assistant content was an orphan `server_tool_use`),
then `#self.messages == 0` and the next `ask()` takes the **seed branch**
(`bbconversation.lua:225`). That is the *safe* outcome: it re-seeds with a **fresh**
`book_context` at the **live** position. To preserve original intent, `fromSession` restores
`self.selected_text`/`self.note` from `loaded.meta.seed` **only on this empty-history path**.
`_armResumeReanchor` detects empty history and sets `self._reanchor_via_seed = true` (leaving
`_pending_resume_note = nil`). **Exactly one** of {pending-note, seed-reseed} fires, decided by
`#messages` after tail-drop.

**`_reconcileConfigDrift` / `_effectiveConfig` (NEW) — §9.3.** `_loop` reads its config once at
`bbconversation.lua:274` (`local cfg = self.settings:getConfig()`), feeding `buildBody` at
`bbconversation.lua:342`. Replace that single call with `local cfg = self:_effectiveConfig()`:
```lua
-- Returns settings:getConfig() with per-conversation overrides applied. For a
-- non-resumed conversation no overrides are set, so behavior is unchanged.
function Conversation:_effectiveConfig()
    local cfg = self.settings:getConfig()
    if self._thinking_override   ~= nil then cfg = setmetatable({enable_thinking   = self._thinking_override},   {__index=cfg}) end
    if self._web_search_override ~= nil then cfg = setmetatable({enable_web_search = self._web_search_override}, {__index=cfg}) end
    if self._memory_override     ~= nil then cfg = setmetatable({enable_memory     = self._memory_override},     {__index=cfg}) end
    return cfg
end
```
(Implementation may compose into a single shallow-copy table; the metatable chain above is the
literal semantics: override wins, else fall through to the global config.) The web_search tool
removal at `:182` and memory build at `:203` in `new` use the *current* config; `fromSession`
re-asserts overrides onto `tool_specs` (re-add web_search if saved-on but now-off; rebuild memory
store + spec if saved-on but now-off) — see §9.3.

### 5.3 `main.lua`

**Hold the live conversation; flush on teardown.**
```lua
-- in promptAndStart's Send callback (where `conversation` is constructed):
self._active_conversation = conversation

function BookBuddy:onCloseDocument()
    -- CloseDocument is broadcast BEFORE closeDocument() nulls the document
    -- (readerui.lua: the event is sent before document teardown), so
    -- self.ui.document is still valid here.
    if self._active_conversation then
        self._active_conversation:flushNowPersist()  -- sync, only if resendable + dirty
        self._active_conversation = nil
    end
end
```
`onCloseDocument` covers clean close only; a hard power-off loses the debounce window — accepted
and documented (§16). Strictly better than today (everything lost).

**Primary entry becomes Continue / New.** Replace the single "Chat about this book" callback
(`main.lua:90-101`):
```lua
callback = function()
    if self.settings:getConfig().enable_sessions
       and require("bbsession").hasResumable(self.ui) then
        self:showContinueOrNew(self.ui)   -- ConfirmBox: [Continue last chat] [Start new chat]
    else
        self:promptAndStart(self.ui)      -- unchanged path
    end
end
```
`showContinueOrNew` is a `ConfirmBox`. "Continue last chat" → `resumeSession(<most recent for
book>)`. "Start new chat" → existing `promptAndStart`. This **eliminates invisible forking** (the
real data-loss mode).

**Resume picker (per-book, no library).**
```lua
function BookBuddy:showResumePicker(ui)   -- Menu of Session.listForBook(Session.bookHash(ui))
function BookBuddy:resumeSession(entry)   -- entry is a header table from listForBook
```
Add **one** secondary menu item under "Chat about this book": `"Resume an earlier chat…"`, gated
on `enable_sessions and hasResumable`. **No "All my conversations", no library, no read-only
cross-book view.**

**Resume picker rows — e-ink friendly.** Single-line `Menu` rows in KOReader's native idiom:
`<title>  ·  <relative time>`. No two-line layout, no "was at X% / now at Y%" delta, no inline
emoji/trash glyph. Delete is **long-press → ConfirmBox** only. On RTC-less devices `last_active`
may be 0 (§11); rows fall back to ordering by `created` then `session_id`, and show the title
alone when the timestamp is implausible (`< 10^9`).

**Live session identity in the viewer.** `ChatViewer` shows the session `title` in its title bar
(`bbchatviewer.lua` build, currently `title = _("BookBuddy")`). `_render` passes
`title = self.title and ("BookBuddy — " .. self.title) or _("BookBuddy")`.

### 5.4 `bbsettings.lua`

Add **one** key to `DEFAULTS` and surface it in `getConfig` (mirroring `enable_memory`):
```lua
-- Persistent, resumable chats stored device-globally. Default-ON: sessions spend zero
-- API tokens (unlike enable_memory, which is off because it costs tokens every turn).
-- When off: no blob is written, no menu item shows, _persist no-ops.
enable_sessions = true,
```
Menu: one toggle (mirror the `enable_memory` toggle row). **No** "Rebuild index" action (no
index). **No** `sessions_per_book_limit` setting (`SESSIONS_PER_BOOK_LIMIT` is a code constant).

### 5.5 `bbanthropic.lua` — no logic change

Reuse `Anthropic.decode` (`bbanthropic.lua:85-95`) for the blob; reuse the in-process encode rule
documented at `bbanthropic.lua:2-3`. `Session.serialize` calls `rapidjson.encode` directly. No
new function here.

### 5.6 `bbtools.lua` — minimal

Add `Tools.snapshotPosition(ui)` returning
`{ xpointer, percent, page, page_count, chapter, paging_doc }`, so `bbsession` and the re-anchor
read position the **same way** `book_context` reads it internally. Implement using the existing
private helpers:
```lua
function Tools.snapshotPosition(ui)
    local doc = ui.document
    local page = currentPage(ui)                       -- bbtools.lua:58 (nil for paging docs w/o view.state)
    local xp
    if doc and doc.getXPointer then
        local ok, v = pcall(function() return doc:getXPointer() end)
        if ok then xp = v end
    end
    local pct
    if doc and doc.getCurrentPercent then
        local ok, v = pcall(function() return doc:getCurrentPercent() end)
        if ok then pct = v end
    end
    return {
        xpointer  = xp,
        percent   = pct,
        page      = page,
        page_count = doc and doc.getPageCount and doc:getPageCount() or nil,
        chapter   = currentChapter(ui),                -- bbtools.lua:65
        paging_doc = (page == nil),                    -- §8.4: nil page => paging/degraded
    }
end
```
`tool_book_context` (`bbtools.lua:455-475`) is **refactored to call this internally** so there is
a single position oracle. (It currently reads `currentPage`/`getPageCount`/TOC inline; route them
through `snapshotPosition` and format the label from the returned table.)

`REJECTED (a standalone public `currentPagePublic` accessor):` don't widen the public surface for
one caller; `snapshotPosition` is the single oracle.

---

## 6. Lifecycle & save points

- **Autosave (debounced 3s):** scheduled from `_render()` after every answered turn, only when
  `_dirty`; firing guarded by `_in_flight`/`_isResendable` (C6) — fires only at a genuinely
  resendable moment, else re-arms.
- **Immediate flush:** `flushNowPersist()` on `onCloseDocument`, only if resendable + dirty.
- **Never mid-round; never mutates the live object** (C6/C7) — serialize runs on a deep copy.
- **Atomicity:** fresh-tmp + file fsync + remove-then-rename + directory fsync via
  `writeToFile(..., directory_updated=true)` on the sidecar (§5.1.1). FAT/exFAT safe.
- **What triggers a load:** the user picks Continue/New → Continue, or opens the resume picker
  and taps a row. Nothing loads automatically on book open (only `hasResumable` is queried,
  which is a directory existence/scan check).
- **Debounce-window loss (≤3s) on hard power-off:** real and documented (§16). The common
  e-reader shutdown is power-off, so this is the common loss case, not an edge — still strictly
  better than today (total loss).

---

## 7. Resume flow

### 7.1 Path: tap → live Conversation

```
resumeSession(entry):
  loaded = Session.load(entry.session_id, Session.bookHash(self.ui))
  if not loaded then InfoMessage("This chat couldn't be opened"); return end   -- never crash
  conv = Conversation:fromSession(
           { ui = self.ui, settings = self.settings },
           loaded)
       -- reconciles config drift (§9.3), repairs tail + syncs transcript (C4), arms re-anchor (§8)
  self._active_conversation = conv
  -- §8.4: if loaded.position.paging_doc or live position unresolvable -> ConfirmBox warning
  --       BEFORE the render, and always arm the quarantine note.
  conv:_render()                  -- shows restored transcript (and re-anchor is staged for next ask)
  -- user taps Reply -> ask(q):
  --   #messages>0 : append user turn, PREPENDING _pending_resume_note if armed (§8)
  --   #messages==0: seed branch re-seeds at LIVE position (C3), restored selected_text/note
```

### 7.2 First post-resume turn is the follow-up branch (the normal case)

`#self.messages > 0` after load → `ask()` appends a plain user turn (`bbconversation.lua:256`),
does **not** re-seed (`:225`). `selected_text`/`note` are read only on the empty-history path
(`:226-253`); restored only there (§5.2 C3). Resume "just works" for follow-ups once `messages`
is populated and config drift reconciled.

`ask()` change for the resume note (the `#messages>0` branch at `:256`):
```lua
else
    local content = question
    if self._pending_resume_note then
        content = self._pending_resume_note .. "\n\n" .. question
        self._pending_resume_note = nil
    end
    self.messages[#self.messages + 1] = { role = "user", content = content }
end
self._dirty = true
```

### 7.3 Auto-title (`Session.titleFromSeed`)

First user transcript entry's `.text` (the raw question), else extract `<question>…</question>`
from `messages[1].content` (the seed, `bbconversation.lua:226-253`), clipped to ~60 codepoints
via `util.splitToChars`. Deterministic, zero model call. Picker rows disambiguate colliding
titles by relative time.

---

## 8. SPOILER-SAFETY ON RESUME — airtight

**Threat model.** The forward direction (reader advanced past session start) is **benign**: the
live gate recomputes `currentPage(ui)` per call (`bbtools.lua:199,366,406`) and would now *allow
more*, never leak. The **backward direction is the primary leak**: the reader resumes a chat that
discussed chapter 9 while now sitting at chapter 2. The frozen history holds
legitimately-obtained-then but now-ahead content: prior `tool_result` quotes from ~page 140,
prior assistant answers, and the stale seed `book_context`. The live gate protects *new* calls;
it does nothing about text already in-context or about the model recapping its own prior answers.
Naively re-anchoring (just asserting an earlier position) makes this **worse**. So:

### 8.1 Four layered mechanisms

1. **Live gate is the single source of truth (unchanged, confirmed).** All new `grep`/`read`
   calls gate on live `currentPage(ui)` (`bbtools.lua:199` grep cap, `:406` read xpointer
   boundary). No restored field feeds them. Forward-leak-proof by construction.

2. **Drift detection by xpointer, not page.** `_armResumeReanchor(meta)` compares the reader's
   **live xpointer** against `meta.position.xpointer` via `doc:compareXPointers` — the same oracle
   `read` trusts (`bbtools.lua:465-466`, whose comment states the convention: `1` means the second
   arg is after the first; verified upstream at `credocument.lua:750-752` / `cre.cpp:2484-2495`).
   Page integers are layout-dependent (font/margin) and produce both spurious re-anchors and missed
   backward moves, so they are **not** used for the safety decision. Outcomes:
   - `compareXPointers(stored, live) == -1` (live is *before* stored — **backward**) → arm the
     **quarantine re-anchor** (8.2).
   - `compareXPointers(stored, live) == 1` or `== 0` (live at/after stored — forward or same) →
     arm a **light position note** only (coherence, no quarantine), or nothing if within the same
     fragment.
   - `compareXPointers` returns **nil** (either xpointer invalid — `credocument.lua:751-752`), the
     xpointer is missing on either side (paging doc), or the call errors → treat as
     **backward/unknown → quarantine** (fail safe).

   > Sign convention is load-bearing and easy to invert: `1` = live **after** stored = **forward**
   > (benign); `-1` = live **before** stored = **backward** (quarantine). The §14 drift specs pin
   > BOTH directions so an inversion cannot pass the suite.

3. **History quarantine note (the core fix).** When backward, the re-anchor text does not merely
   restate position. It quarantines the prior conversation:
   > `<resume_note>` The reader has returned to this conversation and is now reading **earlier**
   > in the book than when we last spoke. **Everything discussed earlier in this conversation may
   > now be ahead of their current position. Do not restate, summarize, quote, or build on any of
   > it unless the reader explicitly asks or re-establishes that they have reached that point.**
   > Treat the no-spoilers rule as applying to our own prior messages. Memory notes you may recall
   > were written when the reader was further ahead; treat any note describing events past the
   > current position as spoiler-quarantined too. If the reader asks you to continue or recap
   > *this* conversation, that is explicit consent to discuss its prior content with them. Current
   > position follows. `</resume_note>` + fresh `<book_context>` (from `Tools.execute("book_context", {}, ui)`).

   This tells the model the *conversation itself* is now a spoiler surface — the channel naive
   re-anchoring ignores — and folds in memory recall (§8.5) and the explicit-consent carve-out
   (matching `bbprompts.lua`'s existing "unless they explicitly ask" carve-out).

4. **Explicit-consent carve-out.** Resuming a chat that visibly discusses ahead-content is itself
   a signal; the carve-out sentence above prevents wrongful over-blocking of the reader's *own*
   prior chat while defaulting to silence.

### 8.2 Delivered as a mechanism, not a dangling message

The re-anchor is `self._pending_resume_note`, consumed by `ask()` (§7.2) — **never** appended to
`messages` standalone (which would risk two consecutive user turns → 400). Two hard guarantees:

- **Consumption is a precondition of the first post-resume turn.** `_loop`'s entry asserts: for a
  resumed conversation with movement, **either** `_pending_resume_note` was folded into the
  outgoing user content this turn **or** the empty-history seed path ran (which carries fresh live
  position). The note can never be silently dropped on a `Stop`/error/teardown re-entry. Concretely,
  add at the top of `_loop` (before the first resend/buildBody at `:342`):
  ```lua
  assert(not (self._pending_resume_note and self._reanchor_via_seed),
         "BookBuddy: resume note and seed-reseed are mutually exclusive")
  -- If a resumed conv with a pending note reaches _loop with #messages>0, the last
  -- user message MUST contain the note (folded by ask()); otherwise it is a bug.
  ```
- **Empty-history path uses the seed, not the note (C3).** If tail-drop emptied `messages`,
  `_armResumeReanchor` sets `_reanchor_via_seed=true` and leaves `_pending_resume_note=nil`; the
  seed branch re-seeds at the live position. Exactly one mechanism fires.

### 8.3 Wrong-book / no-doc defense-in-depth

`_armResumeReanchor` no-ops when `self.ui.document` is absent **or** its file hash ≠ the
session's `book_hash` — so a re-anchor can never run against the wrong book even if a caller
bypasses the hash gate. (MVP only ever resumes the open book, but the guard is cheap and future-proof.)

### 8.4 Paging docs are a spoiler-degraded class

For paging docs, `currentPage(ui)` returns nil (`bbtools.lua:58-62`: `ui.view.state.page` may be
unset) → `grep`'s cap is nil (`bbtools.lua:199`) → later-page hits can leak (existing weakness).
Persistent sessions would resurface stale chapter-9 chats on such books. **Decision:** when
`meta.position.paging_doc` is true **or** the live position is unresolvable, `resumeSession` shows
a one-time **ConfirmBox** *before the transcript renders*:
> "This book doesn't report a precise reading position; resuming an old chat may surface content
> from ahead. Continue?"

and **always arms the quarantine note** (8.1 fail-safe branch). We do not silently block (some
readers want it), but we never resume a paging-doc session without the quarantine + warning.

### 8.5 Memory recall is in scope

Memory rebuilds **from the `.sdr` sidecar** on resume (the memory store is re-created in
`Conversation:new` at `:203` from `Memory.baseDirForBook`), so a session that progressed to
chapter 9 wrote chapter-9 plot notes; the memory protocol's first action is `view /memories`
(`bbprompts.lua` MEMORY_PROTOCOL), pulling those ahead-notes into context on a backward resume — a
spoiler channel independent of the blob. The quarantine note (8.1 mechanism 3) explicitly
instructs the model to treat ahead-describing memory notes as spoiler-quarantined too. This brings
memory into the re-anchor's scope rather than leaving it orthogonal.

### 8.6 Transcript-display replay is acknowledged, not hidden

`resumeSession`→`_render` redraws the stored transcript, which for a backward resume visibly
contains the prior ahead-discussion *before any model turn*. This is pure UI replay the model
cannot gate. **Decision:** (a) accepted as *reader-initiated* (they chose to reopen a chat they
had); (b) the resume picker and `showContinueOrNew` preview **only titles** (first *question*),
never answer text; (c) when the backward/paging warning (8.4) fires, the ConfirmBox precedes the
transcript render, so the reader consents *before* the transcript is shown.

### 8.7 Why this is airtight

Gate never weakens (1). Backward leak via in-context history is closed by the quarantine note (3)
+ explicit-consent carve-out (4). The note can't be dropped (8.2 precondition). The drift
decision is layout-robust (xpointer, 2). Paging docs are warned + quarantined (8.4). Memory recall
is covered (8.5). Wrong-book re-anchor is impossible (8.3). The one residual is reader-initiated
UI replay, which is consent by construction (8.6).

---

## 9. Serialization / deserialization

### 9.1 Save (`Session.serialize`, on a deep-copied snapshot — C7)

1. Input is `conv:_snapshotForPersist()` — already a deep copy; defensively normalized
   (`_dropDanglingTail` / `pairDanglingWebSearch` predicates run on the **copy**). The live
   conversation is never mutated (C7).
2. Strip `_md_src`/`_md_out` from transcript entries; copy each to `{role, text, done}`. Carry
   `role="tool"` entries' `text` (C10).
2b. Strip any residual `cache_control` from every block of the copied `messages`. This is
   **required, not defensive**: `buildBody` not only strips prior markers, it **adds**
   `cache_control = {type="ephemeral"}` to the last content block in place on every call
   (`bbanthropic.lua:90-92`), so the post-turn history always carries exactly one. Harmless on
   resend (`buildBody` re-strips), but stored blobs must be wire-clean so round-trip specs stay
   byte-stable.
3. `messages` stored as a **nested JSON value** (single encode).
4. `blob = rapidjson.encode({ schema=1, …meta…, config_fingerprint=…, position=…, seed=…,
   usage=…, messages=…, transcript=… })`.
5. Write header sidecar `<id>.hdr.json` = the blob minus `messages`/`transcript` (cheap to scan).

### 9.2 Load (`Session.load`)

1. `env = Anthropic.decode(util.readFromFile(blob_path) or "")`. nil → return `nil, "parse"`
   (UI shows InfoMessage; never crashes).
2. `messages = env.messages` (already a table; single-encoded). Run
   `Session._normalizeToolInputs(messages)`:
   ```lua
   -- Walk every tool_use / server_tool_use; if input is an empty table, replace with
   -- rapidjson.object({}) so it re-encodes as {} not []. Makes empty-input object-ness
   -- UNCONDITIONAL, independent of whether the metatable survived serialization (C1).
   function Session._normalizeToolInputs(messages)
       local rapidjson = require("rapidjson")
       for _, msg in ipairs(messages) do
           if type(msg.content) == "table" then
               for _, b in ipairs(msg.content) do
                   if (b.type == "tool_use" or b.type == "server_tool_use") then
                       if type(b.input) ~= "table" or next(b.input) == nil then
                           b.input = rapidjson.object({})
                       end
                   end
               end
           end
       end
   end
   ```
3. Return `{ meta = <header fields>, messages = messages, transcript = env.transcript,
   usage = env.usage }`.

### 9.3 Config-drift reconciliation (`_reconcileConfigDrift`) — load-bearing

The wire history can 400 if current settings disagree with what produced it. Run **before any
resend** (called from `fromSession` before `_dropDanglingTail`):

- **`enable_thinking` drift (C2 — guaranteed 400 otherwise).** History contains `thinking` blocks
  (with `signature`). If `enable_thinking` is now off, `buildBody` omits `body.thinking`
  (`bbanthropic.lua:53-55`) but messages still carry `thinking` blocks → Anthropic 400 ("thinking
  blocks present but thinking not enabled"). **Decision:** set
  `self._thinking_override = saved_fingerprint.enable_thinking` for the lifetime of the resumed
  session; `_effectiveConfig` (§5.2) makes `buildBody` honor it. Restoring the toggle is cleaner
  than stripping `thinking`+`signature` from history (which would also drop cache-relevant blocks
  and risk the "must begin with thinking before tool_use" rule). Symmetric: if thinking was off at
  save and is on now, the override keeps it off so the first restored assistant turn (lacking a
  leading thinking block before its stored `tool_use`) doesn't trip that rule.

- **`enable_web_search` drift.** History may hold `server_tool_use`/`web_search_tool_result`.
  Paired result blocks are tolerated, so no 400 — but for coherence set
  `self._web_search_override = saved_fingerprint.enable_web_search`. In `fromSession`, if the
  override re-enables web search but `new`'s current-config gate removed it from `tool_specs`
  (`:182`), re-add the `web_search_20250305` spec; if it disables it, remove it. Prevents the
  model re-issuing searches the gateway no-ops.

- **`enable_memory` drift (C12).** History may hold `memory` tool_use/result. Set
  `self._memory_override = saved_fingerprint.enable_memory`; in `fromSession`, if memory was on at
  save but is off now and `self.memory` is nil, rebuild the store as `new` does (`:203-208`,
  `Memory.new(Memory.baseDirForBook(ui))`) and append `Memory.spec()` to `tool_specs`; if it was
  off at save but on now, remove the memory spec. The §8.5 quarantine clause covers the
  stale-ahead-notes spoiler angle.

- **`model` drift.** Recorded for diagnostics; **not enforced** (a different model can resume the
  same history). Logged only.

`REJECTED (UX "just document the thinking-drift cost"):` thinking-drift is a **hard 400**, not a
cost — it must be reconciled.

### 9.4 Round-trip guarantees per block type

- `text`: trivial.
- `thinking`: `{type, thinking, signature}` — `signature` is a plain string, preserved; its
  **placement** (thinking first in the assistant turn, before `tool_use`) is preserved because
  rapidjson keeps array order and we never reorder.
- `tool_use`/`server_tool_use`: `{type, id, name, input}` — `input` object-ness re-asserted on
  load (§9.2).
- `tool_result`/`web_search_tool_result`: id-paired; pairing is preserved by storing the wire
  array verbatim, and `_dropDanglingTail` (run on load) self-heals any orphan tail
  (`bbconversation.lua:623-651`).
- **pause_turn-extended assistant messages** (`_storeAssistant`, `bbconversation.lua:599-608`) are
  normal multi-block assistant messages on disk; they round-trip with no special handling.
  Save-only-at-`_render` means we never snapshot between a pause and its resume.
- **Alternation invariant** (`_dropDanglingTail`): enforced on save (predicate on the copy) and on
  load (`fromSession` calls it), with transcript kept in sync (C4, §5.2).

### 9.5 `usage` restoration — honest semantics

The 4 ints are restored onto `conv.usage` and continue accumulating. **Documented caveat (C5):**
the first post-resume turn has a **cold** prompt cache (the rolling breakpoint at
`bbanthropic.lua` `if messages and #messages > 0` does not survive process restart / the >5min
TTL), so its `cache_read` will be ~0 and `input` full — the running totals diverge from a
never-closed session's warm-cache trajectory. This is a **display** divergence only, not a
correctness or billing error (each turn already bills full resend). `REJECTED (reset usage on
resume):` resetting would hide real prior spend; continuing is the honest sum.

---

## 10. Migration & versioning

- `enable_sessions = true` default (zero token cost — aligned with A and C), but zero disk
  footprint until the first completed turn writes a blob. No legacy sessions exist → no v0→v1
  migration.
- `schema == 1`: full resume.
- `schema > 1` (a newer-device blob arriving via synced settings): **ignored in MVP** (no
  read-only library to show it in); logged, never resumed (can't trust unknown wire fields). The
  `schema` field is kept for the future; the read-only-skew UI is deferred with the library.
- Forward-compat strategy: any new field is **additive** and optional; a v1 reader ignores unknown
  keys (rapidjson decode keeps them but `load` reads only the keys it knows). A breaking wire-shape
  change bumps `schema` and is gated by the §10 ignore rule.

---

## 11. Error handling & corruption recovery

**Principle: a session failure never crashes the chat.** Every `bbsession` call from
`bbconversation`/`main` is `pcall`-wrapped.

| Failure | Handling |
|---|---|
| Blob write fails (disk full / RO / FAT rename) | `save` returns `nil, err`; `_persist` logs, chat continues; turn simply not persisted. Fresh-tmp means a failed rename leaves the old blob intact (§5.1.1). |
| Blob parse failure on load | `Anthropic.decode` nil → `load` returns `nil, "parse"`; UI InfoMessage + offer delete. No crash. |
| Header sidecar missing/corrupt | Listing falls back to reading the blob header; rewrites the sidecar on next save. |
| Book moved/renamed | `book_hash` unchanged → resume still matches when that book is open. |
| Book re-converted (new hash) | Old sessions orphan (different hash). `partialMD5` is *sampled* (head-weighted, `util.lua:1111`), so re-download/re-compress orphans more readily than a full hash would — accepted; no orphan UI in MVP (delete is manual once cross-book lands). |
| `.sdr` deleted | Irrelevant (sessions are not in the sidecar). Memory rebuilds from the sidecar if present, else empty. |
| Stale `loc:N` in restored `tool_use.input` | `ui`-scoped locator table is cleared by `new` (`:191-197`); `read`/`create_highlight` return the existing "stale locator" degrade; model re-greps. Expected. |
| No resolvable `book_hash` | `_persist` no-ops. No blob, no error. |
| RTC unset (id/last_active small or 0) | Listing sorts by `created` → `session_id` fallback; UI hides implausible timestamps (`< 10^9`). |

**Recovery without an index:** each blob is self-sufficient and listing is a live directory scan,
so there is no index to corrupt and **no `rebuildIndex` to run**. A stale/missing header sidecar
self-heals on next listing/save.

---

## 12. Concurrency & edge cases

- **Syncthing (`settings/` not synced by default).** Common case: no conflict. If a user syncs
  `settings/`: blobs are immutable-by-id with **96-bit** random suffixes (C8) → distinct ids
  across devices, no blob conflict. There is **no `index.lua`**, so the index-conflict surface is
  gone entirely (Syncthing produces `.sync-conflict-*` files, which our `*.json` non-`.tmp` scan
  simply ignores). A blob re-saved on two devices for the *same* session id resolves
  last-writer-wins on that one blob (acceptable). Cutting the index removed the only real Syncthing
  hazard.
- **Same book open twice.** Independent `Conversation`s, distinct `session_id`s, independent blobs.
- **Volume.** `SESSIONS_PER_BOOK_LIMIT = 30` (constant); prune oldest-by-`last_active` on save. No
  within-session compaction (it would corrupt resends). Size-based eviction deferred (§16).
- **Empty/aborted sessions.** Not persisted (`save` early-returns if `messages` empty or no
  assistant transcript entry). No litter.
- **Resume-and-view re-saving (C11).** `resumeSession`→`_render`→`_persist` would re-save on mere
  viewing; `_persist` saves only when `_dirty` (set on `ask()`/`_storeAssistant`, cleared on save,
  `false` after `fromSession`). Opening, viewing, and backing out without asking does **not**
  re-save — the re-anchor note lives in `_pending_resume_note`, not in `messages`, so nothing
  changed. Closes the unbounded-growth path.

---

## 13. Settings & rollout

One new key `enable_sessions` (default **true** — sessions spend zero API tokens, unlike memory;
aligned with A and C), one menu toggle. With it off: no menu items, no disk writes, `_persist`
no-ops — zero behavior change. `SESSIONS_PER_BOOK_LIMIT` is a code constant.

---

## 14. Testing plan

Tier-1 busted, reusing `tests/support/stubs.lua` + `tests/support/sse.lua`. New
`tests/bbsession_spec.lua` + additions to `tests/conversation_spec.lua`. Tier-2 real round-trip in
`tests/integration/real/session_real.lua`.

### Test-support additions

- **`tests/support/rapidjson_fake.lua` (NEW)** — a faithful fake that *reproduces* the
  array-vs-object distinction (empty bare table → `[]` unless tagged via an `object` sentinel /
  metatable), so Tier-1 genuinely exercises `_normalizeToolInputs`. The current `json` stub
  encodes `{}` as `{}`, masking the C1 hazard.
- **`assertWireValid(messages)` helper** (added to `tests/support`) — asserts, beyond
  `sse.validateMessages` (which checks only role alternation + tool pairing):
  (a) no `thinking` block when thinking is disabled, and thinking-block-first ordering within an
  assistant turn (C2);
  (b) every `tool_use.input` re-encodes to a non-array (C1) via the `capture_build_body` harness;
  (c) no empty `content` array (C9).
  Every round-trip test asserts **both** `assertWireValid` and `#sse.validateMessages == 0`.

### `tests/bbsession_spec.lua`

- empty-input round-trip → `{}` not `[]` (via fake + `_normalizeToolInputs`).
- `thinking.signature` survives; thinking-placement preserved.
- `tool_use`/`tool_result` + `server_tool_use`/`web_search_tool_result` pairing survive round-trip.
- transcript memo-strip (`_md_src`/`_md_out` removed); `role="tool"` entry text carried (C10).
- **deep-copy:** `serialize` does not mutate the live conv (C7) — assert `conv.messages` identical
  (by deep compare) before/after.
- **fresh-tmp atomic save** leaves no `.tmp`; **re-save of same id replaces, not duplicates** (one
  `*.json` in the shard dir).
- delete idempotent (delete twice, no error; blob + `.hdr` gone).
- prune cap (set `LIMIT=2` via test seam, save 3, oldest by `last_active` gone).
- corrupt blob → `load` returns `nil, "parse"`, no throw.
- `schema = 2` blob → not loaded (returns nil + logs).
- 96-bit id format (`os.time().."-"..24-hex`).
- empty/aborted session (no assistant transcript entry) → not persisted (`save` returns nil, no
  file).
- header sidecar fallback: delete the `.hdr.json`, `listForBook` still returns the entry (reads
  blob header) and rewrites the sidecar.

### `tests/conversation_spec.lua` (additions)

- load-then-ask **appends, not re-seeds** (assert via `capture_build_body` that the new user turn
  is plain `question`, no `<book_context>`).
- **dangling-tail repair on load + transcript stays in sync** (C4) — craft a blob with a dangling
  tool_use tail; assert `#messages` dropped AND `#transcript` boundary matches.
- **empty-after-tail-drop re-seeds at live position with restored `selected_text`** (C3) — blob
  whose only assistant content is an orphan `server_tool_use`; assert next `ask` takes the seed
  branch with a fresh `book_context` and the restored highlighted passage.
- **config-drift: thinking off at resume of a thinking session** → no 400 path; assert
  `_effectiveConfig().enable_thinking == true` and `buildBody` includes `body.thinking`, with no
  orphan thinking-blocks-without-thinking validator failure (C2).
- web_search / memory override honored (`tool_specs` re-includes the saved-on tool).
- **autosave fires only at clean termini AND not while `_in_flight`** (C6) — set `_in_flight` and
  schedule; assert save deferred and re-armed.
- **`_persist` no-save when not dirty** (C11) — `fromSession` then `_render`; assert no file
  written.
- **re-anchor: backward move (xpointer) arms quarantine note, folded into next ask, never
  standalone** (C3 / spoiler-2,3) — stub `compareXPointers(stored, live) == -1` (live BEFORE
  stored); assert the outgoing user content contains the `<resume_note>` quarantine text and
  `validateMessages == 0`.
- **forward move does NOT arm quarantine** — stub `compareXPointers(stored, live) == 1` (live
  AFTER stored); assert no quarantine note (light position note at most). Pins the sign convention
  against inversion.
- **no re-anchor when xpointer unchanged** (`compareXPointers == 0`) — no `_pending_resume_note`.
- **nil oracle (invalid xpointer) quarantines** — stub `compareXPointers` returning nil; assert
  the fail-safe backward branch armed the quarantine.
- **paging-doc (nil position) arms quarantine** (and would warn) — assert quarantine armed when
  `position == nil` / `paging_doc == true`.
- `enable_sessions = false` → no save (assert no file, `_persist` no-ops).

### Tier-2 (`tests/integration/real/session_real.lua`)

Round-trip through the real `rapidjson.so` (the only place the true library runs) to confirm
single-encode preserves object-ness AND `_normalizeToolInputs` works; assert `partialMD5`/cached
`doc_hash` stability across two opens of `juliet.epub`.

### Must-hold global assertion

Every restored/round-tripped `messages` passes **both** `assertWireValid` and
`#sse.validateMessages == 0`.

---

## 15. Implementation checklist (ordered, commit-sized)

1. **Settings:** add `enable_sessions` to `DEFAULTS`/`getConfig` + one menu toggle
   (`bbsettings.lua`). Test: defaults.
2. **`bbtools.lua`:** add `Tools.snapshotPosition`; refactor `tool_book_context`
   (`bbtools.lua:455`) to use it. Test: snapshot fields incl `paging_doc`.
3. **`bbsession.lua` core:** `bookHash` (reuse cached `doc_hash`), `rootDir`, `_shardDir`,
   `serialize` (single-encode, deep-copied input), `save` (fresh-tmp + file fsync +
   remove-then-rename + sidecar `directory_updated=true`, prune, skip-empty), `load`
   (+ `_normalizeToolInputs`), `delete`, header sidecar. Tests: round-trip suite incl C1 fake, C7
   no-mutate, FAT-style re-save, atomicity, prune, schema-2 ignore.
4. **`bbsession.lua` listing:** `listForBook` (single-shard scan via hdr sidecar, fallback to blob
   header), `hasResumable`, `titleFromSeed`, `configFingerprint`. Tests: scan, prune cap,
   header-fallback.
5. **`bbconversation` save path:** cache `book_hash`/`session_id`/`_dirty`/`_in_flight` in `new`
   (`:191-197`); add `_snapshotForPersist`, `_isResendable`, `_persist` (dirty + firing-guarded),
   `flushNowPersist`; set `_in_flight` around `_loop` round body; hook `_persist` into `_render`;
   set `_dirty=true` in `ask()`. Tests: termini-only + not-in-flight + dirty-only.
6. **`bbconversation` resume path:** `fromSession`, `_syncTranscriptToMessages` (C4),
   empty-history seed-restore (C3), `_reconcileConfigDrift` + `_effectiveConfig` + the three
   overrides (C2/C12); route `_loop`'s `cfg` (`:274`) through `_effectiveConfig`. Tests:
   append-not-reseed, tail-repair-sync, config-drift no-400.
7. **Spoiler re-anchor (§8):** `_armResumeReanchor` (xpointer `compareXPointers` trigger,
   book-identity guard), quarantine note + consent + memory clause, `_pending_resume_note` consumed
   in `ask` with the `_loop`-entry precondition assert, paging-doc warning hook in `resumeSession`.
   Tests: backward-arms-quarantine, unchanged-no-arm, paging-quarantine, note-folded-not-standalone,
   validator clean.
8. **`main.lua` UI:** hold `_active_conversation`; `onCloseDocument` flush; `showContinueOrNew`
   (Continue/New), `showResumePicker` (single-line rows, long-press delete), `resumeSession`; one
   secondary menu item gated on `enable_sessions`; session title in ChatViewer title bar via
   `_render`. Manual/Tier-2 smoke.
9. **Tier-2:** `tests/integration/real/session_real.lua` (real rapidjson round-trip + hash
   stability).
10. **Docs:** `AGENTS.md`/`README` — feature, global-store divergence from memory's sidecar,
    debounce-loss-on-power-off caveat, cold-cache-first-turn cost, single-encode +
    `_normalizeToolInputs` comment at the encode site.
11. **Gate:** `nix run .#check` green before each commit.

---

## 16. Risks, trade-offs & open questions (honest residual)

- **Sessions don't travel with the book** (global store). Deliberate; cost of a future unified
  library. A new device loses sessions unless `settings/` is synced.
- **Cross-book library and resume are deferred** (with the index). MVP delivers the core promise
  (survive restart, resume current book). The library earns its e-ink UI only when paired with
  cross-book resume.
- **`partialMD5` is sampled** → re-convert/re-download orphans sessions more readily than a full
  hash would. Accepted; no orphan UI in MVP.
- **Debounce-window loss (≤3s) on hard power-off is the *common* shutdown mode** on e-readers,
  not an edge. Strictly better than today (total loss); real and documented.
- **Cold prompt cache on the first resumed turn** → full-history resend cost + a misleading
  cache-ratio in the usage display (C5). Documented; not surfaced to the reader.
- **Transcript-display replay** on a backward resume shows prior ahead-content before any model
  turn (§8.6). Accepted as reader-initiated; gated behind the paging/backward ConfirmBox where
  applicable; pickers preview only the question title.
- **`schema > 1` skew handling** is minimal (ignore + log) until a v2 exists.
- **Open:** export/copy of a transcript — trivial later.
- **Open:** model-summary or manual re-title for vague first-question titles — deterministic
  default for now.
- **Open:** size-based (not count) eviction for power users with one huge session — count cap is
  the MVP bound.

---

### Critique resolution ledger (one line each)

- **C1** (double-encode unverified/unnecessary): single-encode + unconditional
  `_normalizeToolInputs`; faithful rapidjson fake + Tier-2 real test. Confirmed `bbanthropic.lua:2-3`.
- **C2** (thinking config-drift 400): `config_fingerprint` + `_thinking_override` via
  `_effectiveConfig`, reconciled before resend; thinking-placement asserted.
- **C3** (`_pending_resume_note` vs seed ambiguity): exactly one of {pending-note, empty-history
  seed} fires by `#messages`; standalone form deleted; consumption is a `_loop`-entry precondition.
- **C4** (`_dropDanglingTail` silent desync): `_syncTranscriptToMessages` keeps transcript ==
  messages on load.
- **C5** (usage double-count claim): corrected to honest cold-cache display-divergence caveat;
  keep the continuing sum.
- **C6** (debounce fires mid-`_loop`): guard the firing via `_in_flight` + `_isResendable`, re-arm
  instead of mutate.
- **C7** (serialize mutates live conv): serialize operates on a deep copy (`_snapshotForPersist`).
- **C8** (24-bit id collisions): 96-bit random suffix.
- **C9** (validator insufficient): `assertWireValid` adds thinking/input-object/empty-content checks.
- **C10** (transcript `tool` role): explicitly carried in serialize.
- **C11** (resume-and-view re-saves): `_persist` saves only when `_dirty`.
- **C12** (memory drift + false "rebuilds empty"): memory override + §8.5 quarantine clause;
  corrected the claim (memory rebuilds from the `.sdr` sidecar, `:203`).
- **Spoiler 1–7:** backward reframed as the primary leak; xpointer trigger; quarantine note +
  consent carve-out; note-consumption precondition; paging-doc degraded class + warning;
  memory-recall clause; transcript-replay owned.
- **Feasibility B** (FAT atomicity / dir fsync): fresh-tmp + `force_flush` + remove-then-rename +
  `fsyncDirectory` via `directory_updated=true` (verified `util.lua:1141,1156`).
- **Feasibility C** (over-engineered double-encode): removed (= C1).
- **Feasibility D** (hash recompute on hot path): reuse KOReader's cached `doc_hash`.
- **Feasibility E** (`rebuildIndex` on interactive path): no index; header sidecar keeps scan cheap.
- **Feasibility F** (sync close-save cost / power-off): flush only if resendable + dirty; power-off
  loss documented as the common case.
- **Feasibility G** (re-anchor page trigger / book-identity): xpointer trigger + book-hash identity
  guard inside `_armResumeReanchor`.
- **Feasibility H** (Syncthing index conflicts): index removed → hazard gone; 96-bit ids keep blobs
  conflict-free.
- **Feasibility I** (RTC-less ids, stub masks trap): timestamp-fallback sort + faithful rapidjson
  fake.
- **UX** (over-scope / invisible forking / e-ink density / discoverability): library cut;
  Continue-or-New default; single-line picker rows, long-press delete; session title in viewer;
  limit hardcoded.
- `REJECTED:` "reset usage on resume" (hides real spend); "write new blob id per save" (litters
  dir, breaks continue); "just document thinking-drift cost" (it's a hard 400); "build schema>1
  read-only UI now" (no v2 exists); "standalone public currentPagePublic accessor" (one oracle:
  `snapshotPosition`).

**Files referenced (verified):**
`/home/markus/repos/projects/bookbuddy.koplugin/{bbconversation.lua, bbanthropic.lua, bbtools.lua,
bbmemory.lua, bbsettings.lua, main.lua, bbchatviewer.lua, bbprompts.lua}`;
`/home/markus/repos/clones/koreader/frontend/util.lua` (`partialMD5:1111`, `writeToFile:1141`
5-arg signature → `fsyncDirectory:1156-1157`); `~/repos/clones/koreader/base/ffi/util.lua`
(`fsyncDirectory:597`).
