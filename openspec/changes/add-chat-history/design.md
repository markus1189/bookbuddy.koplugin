## Context

A `Conversation` (`bbconversation.lua`) holds two parallel structures: `messages` (exact
Anthropic wire format, resent in full every turn) and `transcript` (the human-readable log
rendered into the viewer). It is created as a local in `BookBuddy:promptAndStart`, runs its
turn loop under `Trapper:wrap`, renders into a `ChatViewer`, and is then dropped. Nothing
touches disk. The only persisted plugin state is `bbmemory`, which stores model-curated
notes under `.sdr/bookbuddy_memory/` via raw `util.writeToFile` calls.

The turn loop already maintains a hard invariant for its own correctness: **history always
ends in a resendable state.** `_dropDanglingTail` unwinds any in-flight tool round, and
`_clean_transcript_len` marks the matching point in the human log. This invariant is exactly
the precondition a persistence layer needs — the "safe to save" points are already computed.

## Goals / Non-Goals

**Goals:**
- Conversations survive viewer-close, book-close, and KOReader restart.
- Multiple chats per book, browsable as a list and reopenable into a live conversation.
- Reuse the existing follow-up path so a post-restart reply is identical to an in-session one.
- Bound storage per book (cap at N, default 20).
- Stay consistent with the `bbmemory` precedent: per-book sidecar, syncs with the book.

**Non-Goals:**
- Cross-book or global chat search/index.
- Model-generated chat titles (would cost tokens for cosmetics — titles derive from the
  first question).
- Persisting in-flight (mid-tool-round) turns. A crash during a tool round loses that turn;
  the reader re-asks.
- Editing or branching a stored chat's history. Reopen appends new turns only.
- Encrypting stored chats (they live beside the book's own sidecar data; same trust domain).

## Decisions

### D1 — Persist BOTH `messages` and `transcript` verbatim
The transcript is **not** derivable from `messages`. Client-tool display lines
(`"→ Searched book for \"whales\" — 12 matches"`) are built in `_loop`'s tool branch, and
their friendly summary (`— 12 matches`, `— 480 words`) is computed at execute time and
stored only on the transcript entry. `_renderAssistantTurn` rebuilds only text/thinking/
web_search from `messages` — it never re-emits client-tool lines. So regenerating the
display from the wire history would silently lose those summaries.
*Alternative considered:* store only `messages`, regenerate transcript on load — rejected;
lossy. The two structures each hold what the other lacks, so both are persisted.

### D2 — Sidecar storage: index + per-chat payload
Layout under `.sdr/bookbuddy_chats/`:
```
index.json   [{ id, title, ts_created, ts_updated, position_pct, turns, usage }, ...]
<id>.json    { id, selected_text, note, messages[], transcript[], usage }
```
The list view reads only `index.json` (cheap, no payload parsing). Reopen reads one
`<id>.json`. Each save rewrites that chat's payload and upserts its single index entry.
*Alternative considered:* one self-describing file per chat, list by scanning + parsing each
payload — rejected; parsing every (potentially large) payload to render a list is wasteful
and scales poorly as chats accumulate. The index keeps listing O(1) in payload size.

### D3 — `id` derivation and assignment timing
`id = os.time()` with a small monotonic suffix to disambiguate same-second saves
(`<seconds>-<counter>`). `os.time()` is available in the KOReader runtime (the
"Date unavailable" caveat applies only to Workflow scripts, not the plugin). The id is
assigned on the chat's **first** clean save and reused for every later overwrite, so a chat
overwrites its own payload and never clobbers another's. A chat that never reaches a clean
boundary (turn-1 error) is never assigned an id and never written.

### D4 — Coarse save cadence: `_render` only
`Conversation:_render` is the single terminal render — it fires on normal completion, on
budget exhaustion, and on the empty-reply placeholder path. Hooking `_persist` there means
every persisted chat shows a finished answer. The internal pause-turn checkpoint is *not* a
save point (chosen over the finer alternatives in exploration): a reopened "→ Reading from
page 12…" with no answer is more confusing than re-asking a lost turn, and e-reader chats
are short.

### D4a — Strip derived caches before serializing
Transcript entries carry a `stripMarkdown` memo (`_md_src`/`_md_out`). These are pure caches
keyed on the entry's live `.text`; persist them and they bloat the payload and can mislead on
reload. `_persist` strips them (and any other `_`-prefixed transient) before serialization;
they re-derive on first render after reopen.

### D5 — Resume reuses the existing follow-up path
`Conversation:new` gains an optional `resume_state`. When present it restores
`messages`/`transcript`/`usage`/`id` instead of starting empty, then the caller calls
`_render` to show the viewer in Reply mode. A follow-up runs the *same* `:ask` → `:_loop`
path as an in-session reply: `messages` is non-empty, so `ask` appends the plain question and
resends the full wire history. No separate "resume protocol" — the wire format *is* the
resume format. `selected_text`/`note` are restored for completeness but are cosmetic
post-resume (they only shaped turn 1's seed, which already happened).

### D6 — Pruning on save, newest-N
After each save, `Chats.prune(ui, N)` keeps the N entries with the newest `ts_updated` and
unlinks the rest (payload + index entry), N from `max_saved_chats` (default 20). Eviction by
count, not bytes: count is trivially correct and predictable; a byte budget needs size
accounting and evicts unpredictably mid-chat. Pruning runs after the upsert so the just-saved
chat is never the one evicted.

### D7 — Browse UI mirrors `Settings:showMemory`
A "Chat history" submenu is inserted in `main.lua:addToMainMenu` after "Chat about this
book". Its `sub_item_table` is built from `Chats.list(ui)`: each row `title · relative-time`,
tap → load + resume, long-press → `ConfirmBox` → delete. A trailing "Clear all chats" row
calls `Chats.clear(ui)` behind a `ConfirmBox`, matching the "Clear memory" pattern.

## Risks / Trade-offs

- **[Empty content list serializes as `{}` not `[]`]** → An empty Lua table is ambiguous in
  JSON; `rapidjson` emits `{}` by default, but the wire format requires `[]` for an empty
  content array, and a reopened chat 400s on its first follow-up. → Use `rapidjson`'s
  empty-table-as-array option (or a sentinel) and add a round-trip test on a message whose
  content is an empty list (e.g. a `_dropDanglingTail`-trimmed edge).

- **[Thinking-block `signature` dropped on round-trip]** → Anthropic requires the opaque
  `signature` field intact when a thinking block is resent; losing it rejects the resend. →
  Round-trip the *whole* block (don't cherry-pick fields) and add a test asserting a
  thinking block survives save→load byte-for-byte on its signature.

- **[index.json and a payload disagree]** → Two writes per save (payload then index) can
  diverge if interrupted between them. → Treat `index.json` as a rebuildable cache, not the
  source of truth: payloads carry their own `id`/metadata, so `Chats.list` can fall back to
  scanning payloads if the index is missing/corrupt, and a save rewrites the index entry
  idempotently. Write payload *before* index so a crash leaves a complete chat with a stale
  index (recoverable) rather than an index entry pointing at a missing payload.

- **[Sidecar growth syncs with the book]** → Stored chats travel via Syncthing like memory
  does. → The N-cap bounds it; each payload is plain text and chats are short.

- **[Stale frozen `book_context` seed]** → The seed captures the reading position at turn 1;
  reopening much later shows that frozen context. → Acceptable and arguably correct: the
  spoiler gate binds follow-ups to the *live* position, so a resumed chat can't leak beyond
  where the reader now is. No new exposure surface (the reader already read their own chat).

- **[Larger payloads on long chats]** → Resending full history already happens at runtime;
  persistence only mirrors it to disk. The coarse cadence writes once per completed answer,
  not per delta, so write volume is modest.
