# Persistent Sessions — A — Per-book sidecar session store

Implementation spec. Self-contained and buildable-from: every design decision is made here.
All file:line anchors were re-verified against source on 2026-06-05 (see §17).

> **Anchor drift + `ask_user` note (2026-07-02).** The working tree has moved since the 2026-06-05
> sweep: `bbconversation.lua` grew ~90–130 lines, so its absolute anchors below are shifted (e.g.
> `Conversation:new` :171 → **:257**, `ask` :225 → **:340**, `_dropDanglingTail` :620 → **:751**;
> in `bbtools.lua`, `tool_book_context` :455 → **:534** and `Tools.execute` :1088 → **:1282-1292**;
> in `bbanthropic.lua`, the `body.thinking` gate :53-54 → **:66-68**, the cache_control strip →
> **:73-82**, the last-message string coercion → **:84-89**). Semantics of every cited behavior
> re-verified to hold; anchors inside passages edited on 2026-07-02 are updated, the rest are
> 2026-06-05-era. Substantive drift: the plugin gained the **`ask_user`** clarifying-question tool
> (`bbconversation.lua:287-294`, `:688-697`, `:961-977`), which **parks the turn** — the loop
> coroutine suspends mid-turn awaiting the reader's answer, with the wire history ending on an
> unanswered `ask_user` `tool_use`. That parked state is **not resumable** (`_isResumableState()`
> is false), so `_persist` and the close flush correctly skip it: a close/crash during a parked
> question loses that turn — accepted, same class as the documented in-flight-turn loss (§6/§12).
> The tool loop is therefore now a **≥3-way split** (memory / ask_user / `Tools.execute`); §5.2's
> mrp-derivation placement is anchored to the `Tools.execute` branch by name, not by else-position.

---

## Changelog

- **2026-07-02 (Round 11)** — eleventh hardening pass (review findings: two data-loss/durability
  defects, one second-generation spoiler leak, one untrusted-text surgery hazard, and a set of
  wiring/feasibility corrections):
  - **§7.3/§9.1/§3.3/§14 (taint metadata now survives every save generation)** — `restore` left
    `_mrp_by_tool_use_id` empty and Step 7b stripped `max_referenced_page` from the decoded blocks,
    so the first post-resume save re-wrote the blob with **no** annotations (and `spoiler_consent`
    revoked) — a later backward resume of that file detected no taint and redacted **nothing**: the
    rewind-with-prior-consent leak reopened at generation 2. `restore` now **harvests** every decoded
    `max_referenced_page` (incl. `SPOILER_SENTINEL`) into `_mrp_by_tool_use_id` **before** Step 7b
    strips it, so `serialize()`'s merge re-emits it; `data.seed` is carried on **every** re-save.
    New §14 generation-2 test.
  - **§5.1/§6/§11/§14 (rename-first replaces remove-first)** — the Round-8 `os.remove(final)`-before-
    rename ran on **all** filesystems, destroying the POSIX atomic-rename-over guarantee §6 still
    claimed: a power-loss between remove and rename left no `final`, a stale-or-absent `.bak`, and a
    `.tmp` that `load`/`list` never read and `prune` would **reap** — total loss. Now `os.rename(tmp,
    final)` is tried **directly** (atomic over the destination on POSIX); only on failure (FAT
    EEXIST) does the fallback free the destination (`final` → `.bak`, else remove) and retry, with
    rollback. The 60s-gated `.bak` refresh becomes a **copy** (`ffiUtil.copyFile`), not a move, so
    `final` survives it. `prune`'s `.tmp` reaper age gate now **always** applies (AND, not OR) — a
    young tmp is never deleted even when its `<id>.json` does not exist yet (a first save in flight).
  - **§5.2/§14 (`_dirty` cleared only on an actually-successful save)** — `_persist` ignored
    `Session.save`'s return, so a failed save (disk full) cleared `_dirty` and every later
    flush no-op'd: silent loss of all subsequent turns. `_persist` now checks the return; a failed
    save leaves `_dirty` true so the close flush retries. §5.3/§6's close-flush rationale
    reconciled with the Round-9 dirty gate: its real value is retrying a previously failed terminal
    save (plus future-proofing), not the "between-turns close" the per-turn saves already cover.
  - **§3.1/§3.2/§8.2 Step 2/Step 7 (seed surgery is span-bounded; the seed is ONE block)** — the
    seed is a **single string** (`ask()` concatenates book_context + highlighted_passage +
    reader_note + question) that `buildBody` coerces to **one** text block — not three blocks as the
    §3.1 example showed. The Step 2/Step 7 gsubs therefore ran over the **untrusted passage text**
    too (a passage containing a literal `"Current chapter:"` line was mutilated). The surgery now
    locates the `<book_context>…</book_context>` span with **plain `find`** and splices via
    `string.sub` + concat; patterns never touch text outside the plugin-generated span. New §14
    passage-with-"Current chapter:"-line assertion.
  - **§8.2 Step 4/§14 (marker de-stacking scans ALL user messages)** — the strip scanned only the
    **last** user message, but the prior `<resume_context>` rides the *first* user turn after the
    previous resume; with ≥2 interleaved questions two conflicting markers stacked — the exact
    hazard the fix claimed closed. Now every user message is scanned; §14 test extended beyond the
    back-to-back case.
  - **§8.2 Step 7/§14 (Rule 2 fallback; `redacted_turn` deleted)** — `redacted_turn` was collected
    but never consumed (message indices have no transcript mapping), and Rule 2 armed **only** off
    Rule-1 tool-line matches — an untagged (foreign/pre-tagging) blob had its wire redacted while
    the transcript still showed the future-page summary AND answer. New conservative fallback: if
    any wire block was redacted but **no** transcript line matched Rule 1, the entire transcript is
    replaced with a single placeholder line. `redacted_turn` deleted.
  - **§7.3 (`_syncTranscriptToMessages` algorithm pinned)** — the load-bearing helper had a
    contract but no algorithm; the transcript-entry → wire-message cursor walk (and its
    pause-extended mapping) is now specified.
  - **§7.3/§8.2/§14 (refused resume no longer wipes the live chat's scratch)** — `resumeSession` ran
    `Conversation.restore` → `new()` (which clears the SHARED `ui._bookbuddy_locators`/`_loc_seq`)
    **before** the taint dialog and the Step 0/0.5 refusals, so a cancelled/refused resume still
    clobbered the live chat's locators — contradicting "leaves the live chat fully intact." Resume
    pre-flight (identity, position, direction, taint) is now a **pure** `Conversation.assessResume`
    over the loaded data; the `Conversation` is constructed only after all refusals and the consent
    choice. Side effect: the Step 0/0.5 refusal now precedes the taint dialog (no more
    offer-then-discard choice).
  - **§3.1/§3.3/§7.3/§8.3/§9.1 (locator high-water mark persisted — LEAK-4 invariant made true)** —
    `new()` resets `ui._bookbuddy_loc_seq`, so post-resume greps re-minted `loc:1..n` and a stale
    `loc:N` in restored history silently resolved to a **different** live passage. The blob now
    carries `loc_seq` (the mint high-water mark at save); `restore` sets the live seq to
    `max(live, stored)`, so stale tokens hit the not-found refusal **permanently**.
  - **§3.3/§7.3/§9.6/§14 (absent `config_fingerprint` fallback)** — a fingerprint-less
    (hand-edited/foreign) blob ran under the live config → the exact §9.6 thinking-400. `restore`
    now **infers** the thinking posture from the presence of `thinking` blocks in the history and
    logs the inference; the "never 400" guarantee is scoped honestly.
  - **§5.1 (seed entropy + wider id random)** — `math.randomseed(os.time())` gave two processes
    launched in the same second identical `_proc`/random sequences, voiding the two-writer tmp
    protection. The seed now mixes `os.time()`, sub-second `os.clock()`, and pointer digits from
    `tostring({})`; `newId`'s random widens to `%06x` (residual cross-device same-second collision
    ~2⁻²⁴ per pair, disclosed).
  - **§8.2 Step 1 (compareXPointers `nil` named)** — `compareXPointers` returns **nil** when either
    xpointer is invalid (`credocument.lua:750-752`); the classify comment now names it (it falls to
    the backward/fail-safe branch by design, no code change).
  - **§5.1/§12/§13 (sync-conflict litter bounded)** — `.sync-conflict-*.json` copies were kept
    forever; `prune` now reaps them after ~30 days (never counted toward the keep cap; never young).
  - **§5.1 (module size honesty)** — the "~170 lines" estimate predates Rounds 5–9 (`.bak`
    lifecycle, rollback, prune sweeps, regex header scan); corrected to ~330.

- **2026-06-05 (Final coherence pass)** — end-to-end reconcile, **no design changes**: re-verified the
  load-bearing file:line anchors against the working tree and the local KOReader clone (all source anchors
  hold except one drifted reference, corrected here) and repaired stale intra-document line pointers left
  by incremental edits.
  - **§11 / §17 (`docsettings.lua` `updateLocation` anchor drift)** — the only drifted SOURCE anchor:
    `DocSettings.updateLocation` is at `docsettings.lua:433` (the metadata/custom-cover copy body at
    `:441-463`), not the stale `:446-461`; also corrected the `:` method-call notation to the actual
    `DocSettings.updateLocation` dot form.
  - **§3.3 / §5.2 / §8.2 Step 7 / §17 (stale "line ~1929" pointers)** — four body/anchor references to the
    `redacted_ids[block.tool_use_id] = true` collection site cited a now-shifted absolute line (~1929; the
    snippet is now ~:2248/:2273). Replaced each with the stable section/"snippet above" reference, since
    intra-document absolute line numbers drift with every edit and the section anchors do not.
  - **§8.2 Step 7 (`ask()` seed-fetch anchor)** — the seed `book_context` fetch in `ask()` is at
    `bbconversation.lua:227`, not `:221`; corrected.
  - **§9.1 `coerceToolUseInput` (`_normalizeToolInputs` bogus source line)** — `_normalizeToolInputs` is a
    NEW `bbconversation` method, so the citation `bbconversation.lua:1819` named a line the source file
    does not have; replaced with a "NEW `bbconversation` method (§7.3)" reference.
  - Confirmed all 17 sections present and sequentially numbered, the §8.2 Step sequence
    (0/0.5/1/2/3/4/5/5b/5c/6/7/7b + §8.2b) complete and ordered, every session-field name
    (`_mrp_by_tool_use_id`, `_resume_consent_reset`, `_resume_notice_shown`, `_reveal_all`, `_resumed`,
    `_resume_note`, `_resume_banner`, `_dirty`, `_session_id`) used consistently, and `_model_override`
    referenced only as deliberately-absent. Verified the core source anchors hold exactly:
    `buildBody` thinking `:53-54` / cache_control strip `:65` / string-rewrite `:74-75` / ephemeral `:78`;
    `numOr0` `bbanthropic.lua:200-202`; `content_block_stop` `:281-285`; `pairDanglingWebSearch` `:73-96`
    (error object `:90`); `_dropDanglingTail` `:620-655` (orphan check `:642`); `_trimTranscript` `:665-673`;
    `_transcriptText` else-branch `:825` → `concat` `:832`; titles `_render :957` / `_ensureStreamingViewer
    :864` / `bbchatviewer.lua:55`; `_renderAssistantTurn` web branch `:800-809`; `_storeAssistant` `:599-608`;
    `currentPage` `bbtools.lua:58`; grep gate `:196-211/:219/:229-243`; read clamp `:369/:381-383`;
    `book_context` `:455-476` (`:464/:466/:472`); `Tools.execute` `:1088-1099`; `writeToFile` 5-arg
    `util.lua:1141`; `fsyncOpenedFile`/`fdatasync` `base/ffi/util.lua:570-583`; `findFiles` recursive-default
    `util.lua:789`; `datetime` `:274/:296`; `textviewer` `:177-184`; `luasettings:backup` `:252-267`;
    `credocument` `:884/:888/:900`.
- **2026-06-05 (Round 10)** — tenth hardening pass (two escape-hatch false-blocks that contradicted the
  reader's own one-tap-earlier choice, one guaranteed re-save 400, one latent string-content walk hazard,
  and one within-the-second id collision):
  - **§8.2 Step 4/Step 7 (rewind redaction now honors `_reveal_all` for the seed + foreign blob)** — the
    seed `book_context` surgery (`if is_backward then`) and the foreign-blob `book_context` fail-safe
    (gated on `is_backward` + `max_referenced_page == nil`) were the **only** two rewind-redaction steps
    NOT gated on `not self._reveal_all`. So a reader who tapped "Reveal everything" still had the seed
    `"Current chapter:"` line and any foreign blob stripped — a false-block contradicting the §8.2
    promise that `_reveal_all` "behaves like a forward/same resume … nothing hidden." Added
    `and not self._reveal_all` to both predicates; Step 7b's `max_referenced_page` wire-hygiene strip
    stays unconditional. New §14 assertion (d) that a reveal-all resume leaves the chapter lines intact.
  - **§8.2 Step 3/Step 6 (the "(spoilers reset)" title-tail + InfoMessage now agree with the reader's
    choice)** — `_resume_consent_reset` was set purely on `data.spoiler_consent == true`, and both the
    title-tail token and the one-shot popup keyed on it alone. A reader who tapped "Reveal everything"
    (explicitly KEEPING later-book discussion) still saw a persistent title and popup asserting the exact
    opposite. Gated both UX surfaces on `_resume_consent_reset and not _reveal_all`; gave the reveal path
    its own honest `" (showing everything)"` banner token. New §14 assertion that a reveal-all resume
    does NOT show "(spoilers reset)".
  - **§9.1 `coerceToolUseInput` (re-save of a restored zero-arg tool no longer 400s)** — the helper
    coerced only `input == nil` → `rapidjson.object({})`, but on restore `_normalizeToolInputs` sets the
    sentinel on the live messages, and `deepCopy` (a plain copy, no metatable preservation) strips the
    object metatable on a re-save, leaving a bare empty `{}` that `coerceToolUseInput` did NOT re-coerce
    → re-encodes as `[]` → 400 on the next resume. Made it treat `nil` OR an empty table identical to
    `_normalizeToolInputs`. New §14 Tier-2 re-serialize round-trip assertion; made the `deepCopy`
    contract's no-metatable-preservation consequence explicit.
  - **§9.1 serialize helpers (string-content short-circuit)** — `messages[].content` is legitimately a
    STRING (the seed before first `buildBody` and every interior follow-up user turn —
    `bbconversation.lua:254/256`; `buildBody` rewrites only the LAST message). `coerceToolResultContent`,
    `coerceToolUseInput`, `dropSignaturelessThinking`, and `mergeReferencedPages` now state they
    short-circuit when `type(content) ~= "table"` (mirroring `stripCacheControl`); load-bearing for
    `dropSignaturelessThinking`'s block-order walk, which must not misclassify a string-content interior
    user turn. Pinned the §14 round-trip test to include such a turn.
  - **§5.1 `Session.newId` (within-the-second id collision)** — `"%d-%x%x"` joined `_seq` and the random
    with no separator/pad, so e.g. (seq=1, rand=0x0a3f) and (seq=0x1a, rand=0x3f) both rendered
    `"…-1a3f"`. Since the id is the filename stem and picker dedup key, a collision silently overwrites a
    chat or merges two rows — a data-loss hazard for a "never lose a chat" feature. Delimited + zero-padded
    to `"%d-%x-%04x"`; updated the §5.1/§15 anchor notes.
- **2026-06-05 (Round 9)** — ninth hardening pass (one guaranteed-400 serialization bug, one
  wrong-direction spoiler gate on the memory channel, one unknown-page fail-safe miss, two
  Syncthing-multi-device hazards, and two A-internal `_persist` robustness gaps stolen from B):
  - **§8.2 Step 7 / §14 LEAK-7 (web-search redaction was emitting an illegal STRING content → 400)** —
    Step 7's web-search branch replaced `web_search_tool_result.content` with a plain **string**, but
    §3.3/§9.1 (`coerceToolResultContent`) state that content is **never** a string on the wire (it is a
    gateway results array or the synthetic error object). A string is the exact corrupt shape the
    serializer is forbidden to produce; `sse.validateMessages` only checks pairing, so Tier-1 passed but
    the real Anthropic/Vertex schema would 400 on the first `buildBody` after any tainted-backward resume
    that web-searched. Replaced the string with the **error OBJECT**
    `{type="web_search_tool_result_error", error_code="unavailable"}` — `pairDanglingWebSearch`'s exact
    shape (`bbconversation.lua:88-91`), which round-trips through rapidjson (§9.2). Fixed the comment and
    the §14 assertion to say error object, not string stub.
  - **§8.2 Step 5b / §8.3 LEAK-6 (memory-quarantine clause armed on the WRONG condition)** — the clause
    was gated on `is_backward`, but the memory store is keyed to the **book**, not the session position,
    and the MEMORY_PROTOCOL injects a start-of-conversation memory view on **every** resume. A session
    saved at p.142 with notes about p.500, resumed after the reader **advanced** to p.200 (a forward move
    → no clause armed), still leaked the p.500 notes. Re-armed the clause on **every memory-enabled
    resume** (independent of `is_backward`, keyed on `cur_page`); Steps 5/5c/7 stay backward-only.
  - **§8.2 Step 7 / §8.3 LEAK-8 (foreign book_context fail-safe missed the "? of N" unknown-page case)** —
    the shape-match arm keyed on `%d+`, but `tool_book_context` (`bbtools.lua:464-466`) emits
    `"Current page: ? of N"` when `currentPage` is nil, so a "?"-page foreign blob with no chapter line
    fell through unredacted on a backward resume. Loosened the page-shape arm to `[%w?]+`.
  - **§5.1 / §12 (two Syncthing multi-device hazards in prune/list)** — (1) the `prune` `.tmp` reaper
    `os.remove`d any stale `*.tmp` even when the strict `<id>.<proc>.<rand>.tmp` stem did **not** match,
    so a Syncthing in-flight `~syncthing~….tmp` partial could be deleted, corrupting a peer's sync pull;
    now only reaps when the plugin's own stem matched. (2) both `list` and `prune` called
    `util.findFiles` without the 3rd arg, which defaults `recursive=true` (`frontend/util.lua:789`), so a
    `.stversions/` or `.sync-conflict` dir in the `.sdr` was descended into; passed `recursive=false`.
  - **§5.2 / §7.3 (`_persist` self-guarding + dirty-tracking, steal Approach B)** — **STEAL-1:** made
    `_persist` self-guarding via an early `if not self:_isResumableState() then return end`, promoting the
    close-path predicate to a universal precondition so the four pinned call sites are scheduling hints,
    not correctness-load-bearing (a refactor can no longer silently persist a dangling tail). **STEAL-2:**
    added `o._dirty=false` in `new()`, set `true` in `ask()` and at `_storeAssistant`, cleared after a
    successful `Session.save`, left `false` by `restore()`, and gated in `_persist` — so a
    resumed-but-unasked session keeps its originally-saved `anchor.xpointer` (protecting a later resume's
    `compareXPointers` backward-drift classification). New §14 assertions.
- **2026-06-05 (Round 8)** — eighth hardening pass (one transcript-side spoiler leak, one invisible-fork
  data-loss mode cross-pollinated from B, and two FAT durability corrections cross-pollinated from C):
  - **§3.1/§3.3/§5.2/§8.2 Step 7 (web-search transcript scrub — a real rewind leak)** — the web-search
    transcript line built by `_renderAssistantTurn` (`bbconversation.lua:800-809`) as
    `{role="tool", text="  → Searched the web for … — N result(s)"}` carried **no** `_tool_use_id` (that
    field was stamped ONLY at the client-tool dispatch loop, `:562`). So on a tainted-backward resume the
    wire `web_search_tool_result` was redacted but the on-screen search-summary line (which can quote a
    spoiling query, e.g. `Searched the web for "how does Moby-Dick end"`) was **never** scrubbed, and a
    web-search-ONLY turn never armed Rule 2 so its trailing answer line also rendered verbatim. Specified a
    **SECOND stamping site**: stamp `transcript[]._tool_use_id = b.id` (the `server_tool_use` id) in that
    `_renderAssistantTurn` branch; confirmed Step 7's web redaction already collects the matching wire
    block's `tool_use_id` into `redacted_ids` (line ~1929, equal to `b.id` by pairing). Now Rule 1 scrubs
    the search line and arms Rule 2 for the answer line. Corrected the §3.3 false claim that "each
    persisted tool entry carries `_tool_use_id`"; added a §14 web-search-only-turn rewind assertion.
  - **§5.3 (primary entry → Continue-or-New; close the invisible-fork data-loss mode, steal B)** — the
    primary "Chat about this book" callback (`main.lua:94-99`) always called `promptAndStart` → always
    minted a fresh session; resume was reachable only via the separate secondary item, so a reader tapping
    the familiar primary entry silently started a forgotten parallel session. Gated the primary callback on
    `enable_sessions and Session.hasContent(self.ui)` → a new `BookBuddy:showContinueOrNew()` ConfirmBox
    ([Continue last chat] → `resumeSession(Session.list(self.ui)[1].id)` / [Start new chat] →
    `promptAndStart(nil)`), else straight through to `promptAndStart(nil)` (zero behavior change when off
    or no sessions). No global store needed — A already has per-book `hasContent`/`list`. New §14 UI test.
  - **§5.1/§6/§11 (durability wording corrected to fdatasync + parent-dir fsync, steal C STEAL-FAT-1)** —
    `writeToFile(json, tmp, true)` passes `force_flush` but not `directory_updated`, so it calls
    `fsyncOpenedFile(file)` with `sync_metadata` nil → **`C.fdatasync`** (data only, NOT metadata,
    `base/ffi/util.lua:579-583`). Corrected the §6/§11 "fsync the file" overclaim to **fdatasync (data) +
    `fsyncDirectory` (rename entry)**, at parity with KOReader's own metadata writes; credited the `.bak`
    as the backstop. Added a one-shot `ffiUtil.fsyncDirectory(parent .sdr)` after the first-ever
    `makePath`, so the new `bookbuddy_sessions/` subdir entry is durable before any file lands in it.
  - **§5.1/§6/§11 (rename rollback + remove-final-first — close a silent unlistable-session loss)** —
    `Session.save` moved `final` → `.bak` (if >60s old) then `os.rename(tmp, final)`; on a `tmp→final`
    failure it removed the tmp and errored but **never restored `final` from `.bak`**, so the live `.json`
    was gone and `list`/`readHeader` (which scan `*.json` only) dropped the row — recoverable only by
    explicit id the picker can no longer offer. Added `os.rename(bak, final)` rollback on that failure
    path; additionally `os.remove(final)` before `os.rename(tmp, final)` when the 60s gate did NOT move
    `final` → `.bak` (converts the FAT-EEXIST hazard into the already-reasoned unlink+rename window). New
    §14 rename-rollback + remove-first assertions. (**Superseded by Round 11:** the unconditional
    remove-first ran on POSIX too and destroyed the atomic replace-over there; the direct rename is
    now tried FIRST and the destination is freed only on failure — the rollback survives unchanged.)

- **2026-06-05 (Round 7)** — seventh hardening pass (two correctness/feasibility defects that made
  earlier-round code emit `nil`/throw, two spoiler-redaction wiring gaps, an over-truncation, and a
  non-disambiguating picker row):
  - **§8.2 Step 0.5 / Step 2 / Step 7 (unassigned `total`)** — the seed re-anchor (Step 2, ~L1637) and the
    rewind seed surgery (Step 7, ~L1859) concatenated a bare `total` that `_reanchorPosition` never
    assigned — a global nil, so both sites emitted `"Current page: 142 of nil"` and baked `"of nil"` into
    the resent wire history (Step 2's post-condition only checks the `cur_page` prefix, so it passed
    silently). Step 0.5 now **captures `local total = ui.document:getPageCount()`** (live; `total_at_save`
    is display-only per §3.1/§3.3 → documented fallback, then `"?"`) alongside `cur_page`, and Step 2/Step 7
    reference that bound local.
  - **§9.0/§9.1 `tagArrays` + §14 + stubs.lua (rapidjson.array nil call)** — `tagArrays` did
    `getmetatable(rapidjson.array({}))`, but the Tier-1 stub (`stubs.lua:234-247`) had **no `array`** field,
    so `serialize()` **threw on every Tier-1 run** (swallowed by `_persist`'s pcall → silent save no-op; the
    round-trip tests errored inside `serialize()`). Chose **option (a)**: add an `array` shim
    (`array = function(t) ... r.__array=true ... end`) to the Tier-1 stub and make `tagArrays` use a
    **pcall-guarded, runtime-detected MT** that no-ops if `array` is absent; pinned the §14 deep-equal helper
    to **value-equality that ignores metatables AND the `__array` marker** so the round-trip baseline no
    longer diverges between the MT-tagged serialize side and the marker-tagged decode side.
  - **§3.1/§3.3 transcript schema + §8.2 Step 7 (dead transcript scrub)** — the rewind transcript scrub
    gated on a `_redacted_on_rewind` field **nothing set**, and the persisted `transcript[]` tool entry had
    no key shared with the id-keyed wire blocks — so the scrub was **dead code** (future-page tool/answer
    lines rendered verbatim after a rewind). Added **`_tool_use_id`** to the persisted `tool` entry
    (stamped by `_loop` as `tool_entry._tool_use_id = tu.id` at `bbconversation.lua:562`; preserved by
    `snapshotTranscript`/`sanitizeTranscript`); Step 7 now **collects `redacted_ids`/`redacted_turn` as it
    redacts wire blocks** and scrubs (Rule 1) any `tool` entry whose `_tool_use_id ∈ redacted_ids` and
    (Rule 2) the trailing `assistant` answer line of any turn that produced a redacted block (the answer
    line has no `tool_use_id`).
  - **§5.2/§3.3 (`had_unbounded_hit` over `shown[]`, not `visible[]`)** — only `shown[]` (the first
    `min(#visible, max_results)` items — `bbtools.lua:229-243`) is rendered into the returned tool_result;
    `visible[]` is the larger superset. Pinned `had_unbounded_hit` to iterate **`shown[]`** so a nil-page
    hit in `visible[9..]` that is never rendered no longer permanently over-redacts that turn on every
    future rewind; amended §5.2/§3.3 wording from "visible" to "rendered/shown."
  - **§9.1 `dropSignaturelessThinking` (interior-orphan over-truncation)** — the interior-truncation trigger
    "an interior assistant message that ALSO carries a tool_use" was too coarse: a message
    `[thinking(signed), tool_use, thinking(no-sig), text]` stays valid after the drop (the `tool_use` still
    has a signed thinking before it) yet the coarse rule truncated all subsequent history. Made the trigger
    **block-order-aware**: truncate only when, after dropping signatureless thinking, a
    `tool_use`/`server_tool_use` has **no signed thinking block preceding it in the same message's content
    order**. Mandated walking block order.
  - **§7.1/§7.2 (non-disambiguating picker row)** — the row led with `p.<page_at_save>`, which is
    reflow-dependent and **constant within a sitting**, so the motivating "asked twice in one sitting" case
    rendered as near-identical rows separated only by clock minutes. Switched the discriminator to
    **`<turn_count> turns · <date_time>`** (turn count is already a header field and is the clearest
    "long vs short chat" signal); dropped the page number from the row; new §14 test that two sessions with
    identical `title_snippet` + `page_at_save` produce distinguishable rows.

- **2026-06-05 (Round 6)** — sixth hardening pass (mid-turn spoiler windows, transcript-side leak, empty-array wire trap, foreign-content 400, two UX self-inflicts, and a consent escape hatch):
  - **§8.2b/8.3 (LEAK-0)** — the per-turn nil-page guard fired only **once per `ask()`** (at `_loop`
    entry), so a page-flip to a no-resolvable-page position **between tool rounds** within one turn reached
    an unclamped `read`/`grep`. The same nil-page check now **re-runs before every gated `read`/`grep`
    `Tools.execute` dispatch** inside the loop, returning the Step-0.5 reason as the tool result; §8.3
    LEAK-0 reworded to "before every gated tool dispatch," not "every later turn."
  - **§8.2 Step 7 / 8.3 (LEAK-8)** — the **seed** `book_context` is never a `tool_result` and has no
    `max_referenced_page`, so Step 7's tool_result/web_search walk could never strip its
    `"Current chapter:"` line (itself a spoiler). Added an **unconditional seed-block string-surgery pass**
    on rewind (strip `Current chapter`, re-anchor `Current page`, independent of Step 2's fail-open
    post-condition), plus a **shape-match fail-safe** for foreign/older-A `book_context` tool_results that
    carry **no** `max_referenced_page`. §8.3 LEAK-8 upgraded from instruction-gated to closed-for-rewind on
    three channels (tool-call, seed, foreign), with the residual disclosed.
  - **§7.3 / §8.2 Step 7 (cross-C §8.E)** — Step 7 redacted only `self.messages`; the persisted
    `transcript[]` rendered by `_render` still showed future-page **tool/answer lines** on screen. Added a
    rewind **transcript scrub** that replaces the backing-redacted entries' text with a **shared
    `REDACTION_STUB`** constant (screen and wire match); new §14 assertion.
  - **§9.0/9.1 (rapidjson empty-array trap)** — an **empty** plain Lua table encodes as `{}` (object), so
    a fully-rolled-back `messages[]` would serialize as `"messages":{}` (malformed wire) and skew the
    deep-equal baseline. Added a `tagArrays` step (and transcript tagging in `snapshotTranscript`) that
    sets the rapidjson **array** metatable so empties encode `[]`; new Tier-2 assertion.
  - **§5.2 (mrp block placement)** — pinned the `mrp`/`had_unbounded_hit` derivation **inside the `else`
    (non-memory `Tools.execute`) branch** where the third return exists; the memory branch records nothing
    and `result`/`summary` are the locals declared before the split (do not re-declare).
  - **§3.3/9.1 (coerceToolResultContent)** — a foreign **non-string** client `tool_result.content`
    (number/arbitrary table) passed `validateMessages` but 400s the real API; coercion now also handles the
    non-`nil` non-array case (`tostring`/`""`); new §14 assertion.
  - **§7.2 (picker self-row)** — the live session auto-saved its own file, so the chat the reader is
    viewing appeared as a tappable picker row (a confusing self-restore). `showResumePicker` now **omits
    the row** whose `_session_id == self.conversation._session_id`; new §14 assertion.
  - **§8.2 Step 6 / 7.1 (spoiler-reset notice clip)** — the `"(spoilers reset)"` token rides the **end**
    of the longest title string, first to be clipped/shrunk on narrow e-ink, and the §14 test asserted only
    string content. Added a **one-shot, tap-to-dismiss `InfoMessage`** on the first consent-revoked resume
    (in addition to the title), driven by a new `_resume_consent_reset` flag set in Step 3; new §14
    assertion.
  - **resumeSession + §8.2 (steal C §8.G)** — A one-way-redacted a rewind with no recovery. Added a
    **"Resume hidden / Reveal everything / Cancel"** `ConfirmBox` on a tainted-backward resume
    (`spoiler_consent` OR max persisted `max_referenced_page > cur_page`); "Reveal everything" sets a
    session-only `_reveal_all` that gates Steps 5/5b/5c/7 redaction (Step 7b's wire-hygiene strip still
    runs). Additive; no storage change. New §14 assertion.
  - **§7.3/9.3/14 (reverse-orphan placeholder is belt-only)** — clarified the empty→placeholder step
    rescues only **non-adjacent-assistant** cases; an interior reverse-orphan between two assistants is
    **refused** by the alternation check regardless. Pinned the §14 setup so the reverse-orphan-only
    message is surrounded by **user** messages (else it refuses), and added the adjacent-assistant
    counter-case.

- **2026-06-05 (Round 5)** — fifth hardening pass (wire-up gaps that made earlier-round fixes dead code, plus feasibility/correctness corrections):
  - **§5.3/7.3/15 (Checklist 0.5)** — the `self.conversation` field the close-flush and resume-replace
    guards read/write is **never created** (`main.lua:166` keeps the conversation as a function-local).
    Added Checklist item **0.5** mandating storing the active conversation on `self.conversation` and
    nulling it on viewer close / on replace; §5.3 and §7.3 now state their guards depend on this wiring.
    New Tier-1/UI test that `onCloseDocument` and `resumeSession` see the live conversation.
  - **§5.2/8.3/15 — nil-page grep fail-safe is now wired** — `Tools.execute` returns only **two** values
    (`bbtools.lua:1088-1099`), so `had_unbounded_hit` was always nil and the §8.3 "now closed for rewind"
    redaction was dead code. Chose **Option (a)**: thread a third return through `Tools.execute`
    (`return result or "", summary, extra`), have `tool_grep` return `had_unbounded_hit` third; updated the
    §17 `Tools.execute` anchor comment and added a checklist line mandating the signature change.
  - **§7.1/8.2 Step 6/14/17 — dropped the subtitle-slot banner** — `TextViewer` forwards only
    `title`/`title_face`/`title_multilines`/`title_shrink_font_to_fit` to its `TitleBar`
    (`textviewer.lua:177-184`), **never `subtitle`**, so the planned persistent subtitle slot is a no-op.
    The resume banner is now folded into the **title STRING** at all three build sites; the §14 test
    asserts the TITLE carries the notice across the `_ensureStreamingViewer` rebuild.
  - **§5.1/6/11/14/17 — `.bak` is now persistent with a 60s freshness gate** — `save` previously
    `os.remove(bak)` at the end, so `.bak` survived only the microsecond between the two renames of ONE
    save and was already gone by the hard-power-off-after-close the design names. Mirror KOReader's
    `LuaSettings:backup` (`luasettings.lua:252-267`): refresh `.bak` from `final` only when `final` is
    older than 60s, and **do not remove it**. Corrected the §6 parity claim; new §14 test for
    power-off-after-close recovery from a stale `.bak`.
  - **§9.1/14 — interior signatureless-thinking orphan** — `dropSignaturelessThinking`'s tail-roll only
    covers the **last** tool round; a signatureless thinking in an **interior** assistant message that
    also carries a `tool_use` leaves an orphan that 400s on resume yet passes Tier-1. Specified
    Option (b): **truncate persisted `messages[]` at the last clean assistant turn before the first
    interior thinking-orphan**; added a §14 Tier-2 test (real rapidjson).
  - **§7.3/14 — reverse-orphan removal can empty an assistant message** — the heal loop can reduce an
    assistant message's content to `{}`, which `_dropDanglingTail` and the alternation checks all pass,
    re-introducing the empty-content 400 on the restore side. `restore` now placeholders any emptied
    assistant message with `{type="text", text="(no response)"}` (mirroring `bbconversation.lua:512`);
    new §14 test.
  - **§9.0/9.1 — `numOr0` source corrected** — the helper inventory and ownership-fix option (b) described
    `numOr0` as `tonumber(x) or 0`, but the real source (`bbanthropic.lua:200-202`) is
    `type(v) == "number" and v or 0` (these diverge on a string-typed usage field). Both now quote the
    actual source so the private-copy option matches live semantics.
  - **§7.1/7.2/16 — picker time-of-day discriminator** — `datetime.secondsToDate` returns **date only**,
    so two same-day chats render identical discriminators (the spec's own "asked twice" example). Switched
    to `datetime.secondsToDateTime(updated, nil, true)` (date+time); page stays the cross-day discriminator.
  - **§5.1/13 — reap `.bak` and stale `.tmp`** — with persistent `.bak`, `Session.delete` now also removes
    `<id>.json.bak`, and `Session.prune` sweeps stale `*.tmp` whose `<id>` stem has no live `.json` (or any
    `.tmp` older than a few minutes), bounding `.sdr` / Syncthing litter.

- **2026-06-05 (Round 4)** — fourth hardening pass (resume-chain drift, two new spoiler channels, merge-heal, close-flush, UX):
  - **§9.1/3.3/14** — `serialize()` snapshots `config_fingerprint` from `self:_effectiveConfig()`, **not**
    the live `getConfig()`: a resumed session must persist the posture its `messages[]` were built under,
    else re-saving a resumed thinking-ON history under a live thinking-OFF records an inconsistent
    fingerprint and a second-generation resume drifts back into the R1 thinking-400. New Tier-1 test pins
    the re-saved fingerprint + twice-resumed `buildBody`.
  - **§7.3/9.1/14** — `restore` calls `_syncTranscriptToMessages()` **unconditionally** (not only when
    its own `_dropDanglingTail` shrank `messages`), so a **serialize-side rollback** (signatureless-
    thinking tool-round rollback) that delivers a short-`messages`/long-`transcript` file no longer leaves
    `_render` showing turns absent from the resendable history. New Tier-1 test.
  - **§8.2 Step 7 / 8.3 (LEAK-7)** — `web_search_tool_result` blocks are now **unconditionally redacted**
    on a backward resume (they carry no per-block page and the floating gate never produced them);
    Step 5c arms a web-search-quarantine marker clause; §8.3 discloses LEAK-7. New Tier-1 spoiler test.
  - **§5.2 / 8.2 Step 7 / 8.3 (LEAK-8)** — `book_context` tool_results are annotated with
    `max_referenced_page` at the §5.2 site (live page or sentinel), so Step 7 redacts the spoiling
    `Current page`/`Current chapter` line on a rewind; the Step 4 marker also says to ignore an earlier
    chapter title. `get_toc`/`get_highlights` named as accepted pre-existing live-gate gaps. New Tier-1 test.
  - **§7.3/9.3/9.4/14** — `restore` heals the **reverse-orphan** `web_search_tool_result` (a block whose
    `server_tool_use` id is absent in the same message) in the same per-message pass — closing a
    merge/hand-edit 400 the forward-only `pairDanglingWebSearch` left (Approach C handles both
    directions). New Tier-1 test.
  - **§9.1/14** — `dropSignaturelessThinking` drops the **whole message** (pair-rolling) when dropping
    thinking leaves zero content blocks, rather than persisting `content={}` (the empty-content 400 the
    live loop guards with a placeholder). New Tier-1 test.
  - **§5.2/5.3/6/15** — added `BookBuddy:onCloseDocument()` close-document flush, gated on
    `conv:_isResumableState()` (fires before document nulling), reversing the §5.2 "no close-time save"
    decision safely; covers the between-turns close/power-off path.
  - **§5.4/14/15** — per-row Delete in "Manage saved chats" is now **ConfirmBox-gated** (matching
    bbmemory's destructive-op pattern); the most likely accidental data-loss path is closed.
  - **§7.1/8.2 Step 6/14/15** — the resume/spoiler-reset banner is threaded into **all three** title
    build sites (`_render`, `_ensureStreamingViewer`, re-applied across `updateText`), so it survives the
    Reply-path streaming-viewer rebuild — making the "persistent home / survives the repaint" claim true.
    New Tier-1 test. (**Superseded by Round 5:** the threading mechanism here was a persistent *subtitle
    slot*, which `TextViewer` cannot forward — Round 5 folds the banner into the **title STRING** instead.)

- **2026-06-05 (Round 3)** — third hardening pass (correctness leaks + cross-pollination from B/C):
  - **§9.1/3.3/14** — `dropSignaturelessThinking` no longer manufactures an orphan-tool_use 400:
    when a signatureless `thinking` would be dropped from a message that **also** carries a
    `tool_use`/`server_tool_use`, `serialize()` rolls the whole trailing tool round back to the last
    clean assistant turn (same `_dropDanglingTail` logic) so the persisted history ends resendable.
  - **§5.2/3.3/7.3/8.2 Step 7b/14** — `max_referenced_page` is **never stored on the live wire block**
    (that block is resent by `buildBody`, which does not strip unknown `tool_result` fields → a
    guaranteed 400 on every multi-turn tool chat, no resume involved). It now lives in a parallel
    side-table keyed by `tool_use_id` that `serialize()` merges into the **deep-copied** persisted
    messages only. The unconditional Step 7b strip now applies only to freshly-decoded persisted blocks.
  - **§5.2/8.3** — grep annotation is **fail-safe to `SPOILER_SENTINEL`** whenever the executed grep
    could have emitted an unbounded (nil-page) visible hit (additive `had_unbounded_hit` read-only
    return from `tool_grep`); closes the nil-page-grep leak the §8.3 airtight claim omitted.
  - **§7.3/9.6/3.3/16** — `model` is **dropped from the enforced override set** (kept in
    `config_fingerprint` for display/diagnostics only): a deprovisioned saved model no longer 400s
    every resumed turn. The overlay now touches only `enable_thinking`/`enable_web_search`/`enable_memory`.
  - **§3.1/3.3/7.3** — added optional `seed = { selected_text, note }` to the v1 schema; `restore`
    re-seeds from it on the empty-history path (tail-heal emptied `messages`) so the original highlight
    is not silently dropped.
  - **§7.3** — `_isResumableState()` reuses the **exact** `_dropDanglingTail` danglingness test (client
    `tool_use` OR orphan `server_tool_use`), not a simplified "no client tool_use" check.
  - **§9 (new helper-ownership note)** — enumerated every referenced helper, its owner module, and the
    `numOr0` ownership fix (it is a `bbanthropic` local; export it or define a private copy in
    `bbconversation`).
  - **§14** — pinned the deep-equal baseline to `serialize()`'s output, not live `self.messages`.
  - **§8.2 Step 4** — strip any prior `<resume_context>` block before arming a fresh marker (no stacked,
    conflicting page numbers on a second resume); pinned that the `_resume_note` wrap affects
    `messages[].content` only — transcript keeps the plain question string.
  - **§7.3** — `restore` syncs the transcript back to the surviving last assistant turn when tail-drop
    removed wire messages (steal B's `_syncTranscriptToMessages`).
  - **§7.3/9.2** — added a **load-side** `_normalizeToolInputs` belt in `restore` (forces empty/absent
    tool inputs to `rapidjson.object({})` regardless of who wrote the file).
  - **§9.6/7.3** — `restore` rebuilds `self.memory` from `Memory.baseDirForBook(self.ui)` when the
    effective posture re-enables memory but `new()` skipped store construction (live config off).
  - **§8.2 (new per-turn guard)/8.3** — added a per-turn fail-closed nil-page guard in `_loop` for
    resumed sessions (Step 0.5 fires once; the `:381` gate itself is unfixed, so the guard backstops
    every later turn). §8.3 wording now names this as a conversation-layer refusal.
  - **§13/5.5/5.1** — added `session_keep` (default 20) retention: `Session.prune(ui, keep)` from
    `Session.save` deletes oldest-by-`updated` beyond the cap.

- **2026-06-05 (Round 2)** — second hardening pass (cross-pollinated from siblings B/C):
  - **§5.2/8.2 Step 7** — `max_referenced_page` is **re-derived in the tool loop** from
    `currentPage(ui)` + `tu.input` (the gate value is never returned via `Tools.execute`), not "read
    from the gate." Specified the exact min-clamp formula and the `SPOILER_SENTINEL` for spoiler reads.
  - **§3.1/3.3/5.2/8.2 Step 7** — spoiler reads are made redactable via the single `max_referenced_page`
    channel (record `SPOILER_SENTINEL = 0x7fffffff`) instead of an unpersisted in-memory flag; Step 7's
    predicate collapses to the single condition `max_referenced_page > cur_page`.
  - **§7.3/8.2/15** — added an **unconditional** `max_referenced_page` strip pass (independent of Step 7 /
    direction); forward/same resumes no longer 400 on the first `buildBody`. (**Relocated in Round 3:** the
    strip now lives at the close of `_reanchorPosition` as **Step 7b**, not in `restore()` — Step 7's
    rewind redaction must read the field first, so `restore` intentionally leaves it on the decoded blocks.)
  - **§7.3** — `sanitizeTranscript` contract pinned: coerce missing/non-string `text` → `""` for
    user/assistant/tool roles (prevents the `:825` nil-concat crash); `:825` else-branch hardened to
    `tostring(turn.text or "")` as defense-in-depth.
  - **§8.2 Step 4 / 8.3** — backward resume on a memory-enabled book appends a **memory-quarantine
    clause** to the resume marker (closes the bbmemory recall channel the airtight claim omitted).
  - **§8.2 Step 1 / 8.3** — equal position (`cmp == 0`) is classified as the **forward/safe** branch
    (same-position resume is provably not a rewind); fixes the spec's own forward/same contradiction.
  - **§5.1/6/11/14** — `.bak` retention in `Session.save`/`Session.load` (FAT power-loss bounds loss to
    one turn, not the whole conversation).
  - **§7.1/7.2/16** — picker rows use `datetime.secondsToDate(updated)` (absolute, in-tree) and restore
    a right-aligned `p.<page_at_save> · <date>` discriminator; dropped the relative-date open question.
  - **§8.2 Step 2** — book_context post-condition built deterministically from the captured `cur_page`
    (string surgery), not by re-running the tool (avoids a spurious belt-drop on mid-turn movement).
  - **§5.2/8.2 Step 0.5/16** — paging docs (PDF/CBZ, no xpointer) are **not persisted** (`_persist`
    skips when `safeXPointer(ui)` is nil) and Step 0.5 distinguishes the no-capability reason string.

- **2026-06-05 (Round 1)** — hardening pass:
  - **§3.1/3.3/5.2/7.3/9.1/14** — Added `config_fingerprint = {enable_thinking, enable_web_search,
    enable_memory, model}` to the v1 schema; `restore` re-asserts the saved posture via
    per-conversation overrides routed through a new `_effectiveConfig()` (closes the toggle-thinking
    -> guaranteed-400 bug in both directions).
  - **§8.2** — Added fail-closed **Step 0.5** to `_reanchorPosition`: a nil live `currentPage`
    refuses the resume instead of arming a `page nil` marker through a wide-open gate.
  - **§5.1/15** — Dropped the nonexistent `ffiUtil.getpid()`; tmp name uses a module-load random
    constant plus a per-write random suffix.
  - **§9.1/3.3/14** — `serialize()` now coerces absent `tool_use`/`server_tool_use` `input` to an
    empty JSON object (zero-arg tool calls never set `input`, so it is ABSENT, not `{}`, in source).
  - **§9.1/9.2/3.1/3.3** — `serialize()` drops signatureless `thinking` blocks (unusable on resend).
  - **§7.3/9.3/11** — `restore` refuses files whose first message is not `user` after tail-heal;
    documented that interior alternation is NOT self-healed (file refused).
  - **§7.3/9.3/11** — `restore` guards `type(data.usage)=="table"` before field access.
  - **§9.1/3.3** — `coerceToolResultContent` scoped to client `tool_result` only; `web_search_tool_result`
    content is never coerced. C3 Tier-2 retargeted to the error-OBJECT round-trip.
  - **§9.1/7.3** — `serialize()` calls `getProps()` once into a local (was twice per save).
  - **§6/11** — Downgraded the absolute atomicity claim for FAT/exFAT rename-over-existing.
  - **§5.1/11** — Read-side NUL sentinel + schema marker in `Session.load`/`readHeader` (FAT torn tail).
  - **§8.1/8.2/3.1** — Added optional per-`tool_result` `max_referenced_page`; backward resume redacts
    future-page `tool_result.content` in-memory; reconciled §8.3/16 (gate does not backstop in-history payload).
  - **§8.2** — Move detection uses `doc:compareXPointers` (not page-int compare); anchor resolution
    wrapped in pcall.
  - **§14** — Documented bbsession_spec's hand-rolled fs/`ffi-util`/`docsettings` shims; moved the
    fsync durability assertion out of Tier-1.
  - **§5.3/7.3/16** — Resume only replaces a live chat at a terminal/clean state.

---

## 1. Summary & goals

A `Conversation` (`bbconversation.lua:171`, `Conversation:new`) currently lives only in memory:
`messages[]` (the exact Anthropic wire history, resent every turn), `transcript[]` (the display
log), and `usage` (`{input, output, cache_read, cache_write}`). All three are garbage-collected
when KOReader restarts, the book is closed, or the plugin reloads. **There is no session id, no
timestamp, no serialization today.** Multi-turn chat survives only inside one live in-memory
instance.

**Persistent sessions (this approach)** persist each conversation as **one JSON file in the open
book's `.sdr` sidecar**, mirroring `bbmemory.lua`'s per-book store. A reader can close a chat and
resume it later — on the same device or a Syncthing-synced one — continuing the next turn against
the full wire history, **spoiler-safe across reading-position drift**.

### Goals

- **Auto-persist** every conversation at clean (resendable) turn boundaries, keyed to the book's `.sdr`.
- **Resume picker** lists only the current book's sessions; restore renders the transcript and
  continues via the existing in-viewer Reply button (`bbconversation.lua:968-1002`).
- **Resendable** round-trip of `messages[]` — preserving `thinking.signature` (signed blocks only;
  signatureless ones are dropped, §9.1), coercing absent `tool_use.input` to an empty object, and
  keeping web-search server-tool pairing — verified against `buildBody`'s in-place mutation
  (`bbanthropic.lua:60-80`) and reconciling a since-toggled thinking/web_search posture (§9.6).
- **Airtight** spoiler safety on resume, covering forward-move over-block, rewind-with-prior-consent
  leak, and cross-device/reflow page-drift (§8).
- **Power-loss-safe** atomic writes (e-reader hard power-off is the real failure mode).
- **Zero new runtime deps** — reuse `rapidjson`, `util`, `ffi/util`, `DocSettings`.

### Non-goals

- No cross-book conversation browser (each `.sdr` lists only its own book's sessions).
- No conversation merge / branching — last-writer-wins per session file.
- No cloud sync, no session-id server protocol, no model-driven session naming.
- No restore of live scratch state (`ui._bookbuddy_locators` is **deliberately reset** — §8 LEAK-4
  depends on this).
- No automatic compaction / pruning of wire history (would alter alternation & web-search pairing).
- No migration chain (one schema version ships; mismatches are skipped — §10).

---

## 2. Design rationale & why this storage model

**Elevator pitch.** The wire `messages[]` is already a pure-data JSON-serializable structure that
`rapidjson` round-trips, and the plugin already self-heals its two *tail* invariants on
load (`_dropDanglingTail` for the dangling-tail case, `pairDanglingWebSearch` for orphan server tool
calls). So persistence is mostly *write the table to the book's sidecar; read it back; let the existing
self-healing run.* **But the self-healers heal only specific shapes** — they do **not** repair a
leading non-user message or interior alternation breaks (Syncthing merges), nor do they reconcile a
since-toggled thinking/web_search posture against the resent history. Those gaps are closed explicitly
(§9.3 refuse-unrestorable, §9.6 posture-reconciliation), so "let the self-healing run" is the common
path, not the whole story. We copy `bbmemory.lua`'s per-book `.sdr` sidecar pattern verbatim, which
means sessions inherit the reader's existing sidecar-location setting and Syncthing sync for free.

**The core bet (validated):** serializing the wire history is enough to resume, because the API is
stateless — every turn already resends the full history. The three things that make the bet
non-trivial, all verified against source, are folded into the design:

1. `buildBody` **mutates `self.messages` in place** (`bbanthropic.lua:60-80`): it clears every
   `cache_control`, sets one `cache_control={type="ephemeral"}` on the last block of the last
   message, and — when the last message's content is a *string* — rewrites it in place to
   `{{type="text", text=…}}`. ⇒ The serializer **must strip `cache_control`**, and the spoiler
   re-anchor (§8) **must treat the seed as a block array**, not a string (the seed is rewritten to
   an array on the very first `buildBody` and stays one forever after).
2. `serialize()` **must not call `_dropDanglingTail`** — it unconditionally calls `_trimTranscript`
   (`bbconversation.lua:654`), which truncates the transcript to `_clean_transcript_len` (pinned at
   chain-start during tool rounds, `:367-370` region). At a terminal post-tool render that would
   **delete every tool line and the final answer** from the persisted transcript. ⇒ Removed from
   serialize; defensiveness moves to `restore` (load time), where it cannot harm the persisted file.
3. On `restore`, **pairing must run before dropping** — `_dropDanglingTail` treats an orphan
   `server_tool_use` as dangling and drops the whole tail message (`:642-645`). Running it before
   `pairDanglingWebSearch` would delete a perfectly resumable final answer that merely carries an
   unpaired web search. ⇒ Order fixed (§9).

**Why a per-file dir scan and not an `index.json`:** an index is a second source of truth that
desyncs under partial Syncthing sync. Scanning the directory (as `bbmemory.summaryText` does) is
self-healing and the counts are tiny. Bounded picker cost is handled by a header-decode cap (§5).

---

## 3. Data model — exact serialized schema (v1)

### 3.1 Concrete Lua table (what `Conversation:serialize()` returns / `Conversation.restore` consumes)

```lua
{
    schema_version = 1,                  -- integer; if ~= 1 on load, file is skipped (§10)
    id            = "1717689600-3a7c",   -- plugin-generated; also the filename stem (§4)
    created       = 1717689600,          -- os.time() at first save
    updated       = 1717689830,          -- os.time() at most recent save

    -- CONFIG POSTURE at save time (§9.6). Additive metadata; no storage-model change. restore()
    -- re-asserts this for the resumed session's lifetime so a since-toggled enable_thinking/
    -- enable_web_search cannot 400 the resent history (thinking blocks vs body.thinking mismatch).
    config_fingerprint = {
        enable_thinking   = true,
        enable_web_search = true,
        enable_memory     = false,
        model             = "claude-opus-4-8",
    },

    book = {
        title   = "Moby-Dick",
        authors = "Herman Melville",
        ident   = "9f8c1d2e…",           -- IDENTITY KEY: util.partialMD5(file) (§8 guard); nil if unreadable
        file    = "/mnt/onboard/Moby-Dick.epub", -- advisory only (differs across devices)
    },

    -- DEVICE-STABLE spoiler anchor (§8). xpointer is reflow/device-independent;
    -- page fields are display-only and NEVER used for a gate or move-detection decision.
    -- xpointer is always present in a PERSISTED file: _persist skips paging docs whose
    -- safeXPointer(ui) is nil (§5.2), so a saved session always has a resolvable anchor.
    anchor = {
        xpointer      = "/body/DocFragment[12]/body/div/p[7]/text().142",
        page_at_save  = 142,             -- integer, display only (reflow-dependent)
        total_at_save = 610,             -- integer, display only
    },

    spoiler_consent = false,             -- true iff the model ever ran grep/read with spoiler=true (§8)
    title_snippet   = "Why does Ahab hate the whale so much?", -- codepoint-safe 60-char prefix
    turn_count      = 4,                 -- count of role=="assistant" wire messages (display)

    -- Original seed material (§7.3). Purely additive metadata; lets restore re-seed at the live
    -- position with the original highlight if tail-heal emptied messages (e.g. a session whose only
    -- assistant content was an orphan server_tool_use, so #messages == 0 after _dropDanglingTail).
    -- Round 11: restore ALWAYS rehydrates self.selected_text/self.note from this field (not only on
    -- the empty-history path), so every re-save of a resumed session carries it forward — the field
    -- no longer decays to nil at generation 2. It is CONSUMED (used to re-seed) only when tail-heal
    -- emptied messages, exactly as before.
    seed = {
        selected_text = "Call me Ishmael…",   -- self.selected_text at save (the highlighted passage)
        note          = nil,                   -- self.note at save, if any
    },

    -- Locator mint high-water mark (§8.3 LEAK-4, Round 11). ui._bookbuddy_loc_seq at save time.
    -- restore sets the live seq to max(live, stored) AFTER new() cleared the locator scratch, so a
    -- post-resume grep never re-mints a loc:N that a stale token in the restored history already
    -- names — stale tokens hit the not-found refusal PERMANENTLY, not just until the first grep.
    loc_seq = 7,

    usage = { input = 5120, output = 880, cache_read = 4096, cache_write = 1024 },

    messages = {
        -- WIRE history; exact Anthropic shape; cache_control stripped from every block.
        {
            role = "user",
            -- The seed is ONE text block, not one block per tag: ask() concatenates ALL tags into a
            -- single string (bbconversation.lua:340-360) and buildBody coerces that string to ONE
            -- {type="text"} block (bbanthropic.lua:84-89). The untrusted <highlighted_passage> /
            -- <reader_note> text therefore lives in the SAME block as the plugin-generated
            -- <book_context> — which is why the §8.2 seed surgery MUST be span-bounded (Step 2/7).
            content = {
                { type = "text", text = "<book_context>Title: Moby-Dick\nCurrent page: 142 of 610…</book_context>\n\n<highlighted_passage>Call me Ishmael…</highlighted_passage>\n\n<question>Why does Ahab hate the whale?</question>" },
            },
        },
        {
            role = "assistant",
            content = {
                { type = "thinking", thinking = "The reader asks…", signature = "Ev0BCkY…" }, -- signature MANDATORY
                { type = "tool_use", id = "toolu_01A", name = "grep", input = { query = "Ahab", max_page = 142 } },
            },
        },
        {
            role = "user",
            content = {
                -- max_referenced_page: optional read-only annotation (§8). RE-DERIVED in the tool loop
                -- from currentPage(ui) + tu.input (the gate's clamp is never returned via
                -- Tools.execute — §5.2); a spoiler-true read (or a grep that emitted any unbounded /
                -- nil-page visible hit) records SPOILER_SENTINEL (0x7fffffff) since JSON has no
                -- infinity. Drives backward-resume redaction (single channel: any block with
                -- max_referenced_page > cur_page redacts — §8.2 Step 7).
                --
                -- CRITICAL: this field is NEVER stored on the LIVE wire block (the block at
                -- bbconversation.lua:574-578 that buildBody resends every turn — buildBody nulls only
                -- cache_control, NOT unknown tool_result fields, so a live-block annotation would 400
                -- every multi-turn tool chat). It is held in a parallel SIDE-TABLE keyed by
                -- tool_use_id and merged by serialize() into the DEEP-COPIED persisted messages only
                -- (§5.2). So it appears here in the on-disk shape but never on self.messages. On
                -- restore it is stripped from the freshly-decoded persisted blocks before any buildBody
                -- (unconditional Step 7b — §7.3), and Step 7 additionally redacts content on a rewind.
                { type = "tool_result", tool_use_id = "toolu_01A", content = "p.81: …\np.110: …", max_referenced_page = 110 },
            },
        },
        {
            role = "assistant",
            content = { { type = "text", text = "Ahab lost his leg to the whale…" } },
        },
    },

    transcript = {
        -- DISPLAY log; _md_src/_md_out live-cache keys stripped.
        { role = "user",      text = "Why does Ahab hate the whale?" },
        { role = "thinking",  done = true },                        -- no text field
        -- tool entries carry _tool_use_id (= the matching wire id) so the rewind transcript scrub
        -- (§8.2 Step 7) can map a redacted wire block to its on-screen line. Stamped at TWO sites: the
        -- client-tool dispatch line (= tu.id, bbconversation.lua:562) AND the web-search summary line
        -- (= the server_tool_use b.id, _renderAssistantTurn at bbconversation.lua:800-809; §3.3/§5.2).
        { role = "tool",      text = "Searching for \"Ahab\" — 5 matches", _tool_use_id = "toolu_01A" },
        { role = "assistant", text = "Ahab lost his leg to the whale…" },
    },
}
```

### 3.2 On-disk JSON (`1717689600-3a7c.json`)

```json
{
  "schema_version": 1,
  "id": "1717689600-3a7c",
  "created": 1717689600,
  "updated": 1717689830,
  "book": {
    "title": "Moby-Dick",
    "authors": "Herman Melville",
    "ident": "9f8c1d2e3b4a5c6d",
    "file": "/mnt/onboard/Moby-Dick.epub"
  },
  "anchor": {
    "xpointer": "/body/DocFragment[12]/body/div/p[7]/text().142",
    "page_at_save": 142,
    "total_at_save": 610
  },
  "spoiler_consent": false,
  "title_snippet": "Why does Ahab hate the whale so much?",
  "turn_count": 4,
  "usage": { "input": 5120, "output": 880, "cache_read": 4096, "cache_write": 1024 },
  "messages": [
    {
      "role": "user",
      "content": [
        { "type": "text", "text": "<book_context>Title: Moby-Dick\nCurrent page: 142 of 610</book_context>\n\n<highlighted_passage>Call me Ishmael</highlighted_passage>\n\n<question>Why does Ahab hate the whale?</question>" }
      ]
    },
    {
      "role": "assistant",
      "content": [
        { "type": "thinking", "thinking": "The reader asks", "signature": "Ev0BCkY" },
        { "type": "tool_use", "id": "toolu_01A", "name": "grep", "input": { "query": "Ahab", "max_page": 142 } }
      ]
    },
    {
      "role": "user",
      "content": [
        { "type": "tool_result", "tool_use_id": "toolu_01A", "content": "p.81\np.110" }
      ]
    },
    {
      "role": "assistant",
      "content": [ { "type": "text", "text": "Ahab lost his leg to the whale" } ]
    }
  ],
  "transcript": [
    { "role": "user", "text": "Why does Ahab hate the whale?" },
    { "role": "thinking", "done": true },
    { "role": "tool", "text": "Searching for \"Ahab\" — 5 matches" },
    { "role": "assistant", "text": "Ahab lost his leg to the whale" }
  ]
}
```

### 3.3 Field typing & invariants

- `schema_version` — integer, exactly `1` for v1. Gates the loader (§10).
- `id` — string `"<os.time>-<hex>"`; also the filename stem. Unique per conversation.
- `created` / `updated` — `os.time()` integers (seconds). `updated` re-stamped every save.
- `config_fingerprint` — table `{enable_thinking, enable_web_search, enable_memory, model}`,
  populated from **`self:_effectiveConfig()`** at save time (NOT the live `getConfig()` — a resumed
  session must persist the posture its `messages[]` were built under, else a chain of resumes drifts
  back into the R1 thinking-400; §9.1). Additive metadata; absent in hand-edited
  files. **Round 11 — absent-fingerprint fallback:** when the field is missing, `restore` **infers**
  the thinking posture from the history itself — any `thinking` block present ⇒
  `_thinking_override = true`, none ⇒ `false` — and logs the inference (§7.3/§9.6). Without this, a
  fingerprint-less blob ran under the **live** config, reproducing the exact §9.6 thinking-400 the
  field exists to prevent. Web-search/memory posture for such blobs follows the live config
  (disclosed residual: a fingerprint-less blob carrying web-search pairs resumed under live
  web_search-OFF is instruction-risk only — the pairs still resend; the tool is just not offered).
  `restore` re-asserts **`enable_thinking`/`enable_web_search`/`enable_memory`** for the resumed
  session's lifetime so a since-toggled posture cannot 400 the resent history (§9.6). Read through
  `_effectiveConfig()`. **`model` is recorded for display/diagnostics ONLY and is NOT enforced** — it
  is the riskiest, least-justified override (a deprovisioned saved model would 400 every resumed turn
  with no escape), and the wire shape does not depend on it the way thinking/web_search do. The
  resumed session always runs against the reader's **live** model (§9.6, §16).
- `book.title` / `book.authors` — strings from `ui.document:getProps()`; `"(unknown)"` sentinel when
  absent (matches `tool_book_context`, `bbtools.lua:458-459`).
- `book.ident` — `util.partialMD5(file)` (`koreader/frontend/util.lua:1111`), the same primitive
  KOReader's `hash`-mode sidecar uses; `nil` if the file is unreadable.
- `book.file` — absolute path; **advisory only** (differs across devices; never used for identity).
- `anchor.xpointer` — string from `ui.document:getXPointer()` (`credocument.lua:884`); the **only**
  spoiler-relevant stored position. Non-cre (image/PDF) docs have no xpointer, so `_persist` never
  writes a session for them (§5.2); a persisted file therefore always carries a resolvable xpointer.
  (A hand-edited/synced file with a nil/absent xpointer fails Step 0.5 / Step 1's fail-safe — §8.2.)
- `anchor.page_at_save` / `anchor.total_at_save` — integers, **display only**, explicitly NOT used
  for any gate or move-detection decision (reflow-dependent, incommensurable across devices).
- `spoiler_consent` — boolean; `true` once the model ran `grep`/`read` with `input.spoiler == true`.
- `title_snippet` — string, **codepoint-safe** ≤60-char prefix of the first question (via
  `util.splitToChars`, not byte `:sub`).
- `turn_count` — integer count of `role=="assistant"` wire messages.
- `seed` — optional table `{ selected_text, note }`, populated in `serialize()` from
  `self.selected_text`/`self.note`. Additive metadata; absent in pre-Round-3 / hand-edited files.
  **Round 11:** `restore` **always** rehydrates `self.selected_text`/`self.note` from it when
  present (so every re-save carries the field forward — no generation-2 decay), but **consumes** it
  (re-seeds) only on the empty-history path (when `_dropDanglingTail` left `#self.messages == 0`),
  to re-seed at the live position with the original highlight (§7.3).
- `loc_seq` — optional integer (Round 11): the live `ui._bookbuddy_loc_seq` mint high-water mark at
  save time (`0`/absent when no locator was ever minted). `restore` sets the live seq to
  `max(live, stored)` so post-resume mints never collide with stale `loc:N` tokens in the restored
  history (§7.3, §8.3 LEAK-4). Absent in pre-Round-11 blobs — those keep the old
  first-grep-collision residual, disclosed in §8.3.
- `usage.{input,output,cache_read,cache_write}` — integers; coerced through `numOr0` on restore (§9).
- `messages[].content` — `string` **or** array of block tables. Block field round-trip contract:
  - `text{ text }`
  - `thinking{ thinking, signature }` — **`signature` mandatory**; resent verbatim; dropping it 400s.
    A thinking block whose `signature` is nil/empty (truncated stream, signature-stripping gateway) is
    **dropped on serialize** (`dropSignaturelessThinking` — §9.1), never persisted.
  - `tool_use{ id, name, input }` — `input` is a decoded JSON **object**. **`input` may be ABSENT in
    source**: a zero-arg call (`get_toc`, `book_context`, `get_highlights`) gets no
    `input_json_delta`, so `content_block_stop` never assigns `.input` (`bbanthropic.lua:282`).
    `serialize()` **coerces** an absent `input` to an empty JSON object (`rapidjson.object({})` — §9.1);
    do not rely on the live parser having set `{}`.
  - `server_tool_use{ id, name, input }` — same absent-`input` coercion as `tool_use`.
  - `web_search_tool_result{ tool_use_id, content }` — `content` is **string-or-table**; the table
    case is either the synthetic error object `{type="web_search_tool_result_error", error_code=…}`
    from `pairDanglingWebSearch` or a gateway results array. **Never coerced** — left verbatim (§9.1).
  - `tool_result{ tool_use_id, content [, max_referenced_page] }` — `content` a **string** (or a
    content-block array). Coerced on serialize for client tool_result only (§9.1): `nil` → `""`, and a
    **non-string, non-array** `content` (number/foreign-table from a hand-edited/synced/foreign-client
    file) → `tostring(...)`/`""`, so it never 400s the real API. `max_referenced_page` is an optional read-only integer
    annotation (§8) for backward-resume redaction; **not a wire field**. It is **never written onto the
    live `self.messages` block** (a live-block annotation would 400 every multi-turn tool chat —
    `buildBody` does not strip unknown `tool_result` fields, §5.2): it is held in a parallel side-table
    keyed by `tool_use_id` and merged only into the **deep-copied persisted** messages by `serialize()`.
    On restore it is therefore present on the freshly-decoded persisted blocks and is stripped from them
    before any resend (unconditional Step 7b pass — §7.3). It is **re-derived in the tool loop** from
    `currentPage(ui)` + `tu.input` (§5.2), not read from the gate. A spoiler-true grep/read — **and any
    grep that emitted an unbounded (nil-page) RENDERED/SHOWN hit** (computed over `shown[]`, the rendered
    set, not the larger `visible[]` — §5.2) — records the sentinel
    `SPOILER_SENTINEL = 0x7fffffff` (the single redaction channel — see below).
- `SPOILER_SENTINEL` — module constant `0x7fffffff`, the large integer recorded as `max_referenced_page`
  for any **spoiler-true** grep/read, for a grep whose page bounds are all unknown, **and for a grep
  that emitted any unbounded (nil-page) RENDERED/SHOWN hit** (over `shown[]`, the rendered set — not the
  larger `visible[]`; a nil-page hit that is never shown cannot leak and must not arm the sentinel —
  §5.2). The grep gate shows nil-page hits regardless of cap (`bbtools.lua:219`), so a non-spoiler grep
  can still surface content physically past the reader in the rendered output;
  the sentinel makes such a shown hit redactable on rewind (§5.2/§8.3). JSON has no
  infinity, so this finite integer stands for "references content past the reader's position." Step 7's
  rewind predicate is the single condition `max_referenced_page > cur_page`, so a sentinel-valued block
  redacts on **any** rewind — including a resumed session where the old in-memory `spoiler` flag is gone
  (closes the rewind-with-prior-consent leak across restore). **Round 11 — and across every SAVE
  GENERATION:** `restore` **harvests** every decoded `max_referenced_page` (sentinel included) into
  `self._mrp_by_tool_use_id` *before* Step 7b strips the field from the blocks (§7.3), so a
  resume→ask→re-save chain re-emits the annotations via `serialize()`'s merge. Without the harvest,
  the first post-resume save wrote a blob with **no** annotations (and `spoiler_consent` revoked) —
  a later backward resume of that file detected no taint and redacted nothing, silently reopening
  this exact leak at generation 2.
  - **`cache_control` is NEVER persisted** (stripped in `serialize()` — §9).
- `transcript[]` entries: `{role="user"|"assistant", text=string}`, `{role="thinking", done=bool}`
  (no `text`), `{role="tool", text=string [, _tool_use_id=string]}`. Live-cache keys `_md_src`/`_md_out`
  stripped. The optional **`_tool_use_id`** on a `tool` entry is the matching wire id, persisted by
  `snapshotTranscript`. It is the **redaction key** the rewind transcript scrub (§8.2 Step 7) uses to
  map a redacted wire block to its on-screen `tool` line. It is stamped at **two** sites — the field is
  NOT universal across `tool` entries, so the scrub must tolerate its absence (a `tool` line with no
  `_tool_use_id` simply is not matched by Rule 1):
  - **Client-tool dispatch line** — stamped by `_loop` as `tool_entry._tool_use_id = tu.id`
    (`bbconversation.lua:562`, the client-tool dispatch loop). Maps to the wire `tool_result` block of
    the same `tu.id`.
  - **Web-search summary line** — the `"  → Searched the web for … — N result(s)"` entry produced by
    `_renderAssistantTurn`'s `server_tool_use`/`web_search` branch (`bbconversation.lua:800-809`)
    carries **no** id as written; §5.2 adds `transcript[].​_tool_use_id = b.id` (the `server_tool_use`
    id) at that branch. The matching wire `web_search_tool_result` block's `tool_use_id` equals that
    same `b.id` by pairing, so the rewind redaction's `redacted_ids` (which collects the redacted wire
    block's `tool_use_id` in §8.2 Step 7) lines up with this stamped transcript line — Rule 1
    scrubs the search summary, and because that arms Rule 2's `turn_was_redacted`, the trailing answer
    line that quotes the web result is scrubbed too. (Before this second stamping site, a web-search
    summary line — which can carry a spoiling query, e.g. `Searched the web for "how does Moby-Dick
    end"` — and a web-search-ONLY turn's answer line both rendered verbatim on a rewind: a real
    transcript-side leak.)

  The trailing **`assistant`** answer line has **no** `tool_use_id` and is redacted by a separate rule
  (the trailing assistant line of any turn in which a wire block was redacted on a backward resume —
  §8.2 Step 7 Rule 2).

### 3.4 Forward-compat strategy

`CURRENT_SCHEMA = 1`. Every file carries `schema_version`. **If `schema_version ~= 1` (or absent),
`load` returns `nil` and the file is silently omitted from the picker.** No migration chain, no
disabled/greyed picker rows. This is deliberate: a one-version format with zero deployed files does
not justify a migration subsystem. A future breaking change reintroduces migration **only** when a
real installed base exists. Unknown-version files are **never auto-deleted** (they may be future
versions synced from another device).

---

## 4. On-disk layout

```
<book>.sdr/                                  ← DocSettings:getSidecarDir(file)
├── metadata.epub.lua
├── bookbuddy_memory/                        ← existing (bbmemory.lua:107)
└── bookbuddy_sessions/                      ← NEW (this feature)
    ├── 1717689600-3a7c.json                 ← one file per conversation
    ├── 1717689830-91ff.json
    └── 1717690012-0b2e.18432.a3f9.tmp       ← unique staging name during a write (§6)
```

- **Base dir** mirrors `bbmemory.baseDirForBook` (`bbmemory.lua:101-108`) exactly:
  `DocSettings:getSidecarDir(file) .. "/bookbuddy_sessions"`, replicating the `sdr == ""` → `nil`
  guard (verified: `getSidecarDir` returns `""`, not `nil`, for an empty/missing path). `Session.dir(ui)`
  returns `nil` when there is no resolvable sidecar (no open document), and every entry point no-ops.
- **Lazy creation** via `util.makePath` on the first write only; never create the dir empty
  (KOReader purges empty sidecar subdirs).
- **No `index.json`** — `list` scans the directory (mirrors `bbmemory.summaryText`).
- **Who creates what:** the plugin creates `bookbuddy_sessions/` and the `*.json` / `*.tmp` files.
  KOReader owns `<book>.sdr/` and `metadata.*.lua`.

---

## 5. Module-by-module changes

### 5.1 NEW `bbsession.lua` (~330 lines — honest count after the Rounds-5–9 `.bak` lifecycle, rename fallback, prune sweeps, and regex header scan; `bbmemory`-shaped; **no `_resolve` sandbox** — ids are plugin-generated, never model-supplied)

Public API:

```lua
local Session = {}

function Session.dir(ui)            -- -> string|nil   (sidecar dir + "/bookbuddy_sessions"; nil if no sdr)
function Session.newId()           -- -> string       ("<os.time>-<hex>"; per-process seq for uniqueness)
function Session.save(ui, data, keep) -- -> boolean, err (atomic + fsync; lazy makePath; stamps updated; prunes to keep)
function Session.load(ui, id)      -- -> table|nil, err (schema gate + shape check + usage coercion)
function Session.list(ui)          -- -> array        (header-only decode, sorted updated desc, conflicts filtered)
function Session.prune(ui, keep)   -- -> nil          (delete oldest-by-updated beyond keep; called from save)
function Session.delete(ui, id)    -- -> boolean
function Session.clear(ui)         -- -> boolean      (purge the whole bookbuddy_sessions dir)
function Session.hasContent(ui)    -- -> boolean      (any listable session exists)

return Session
```

Module-level constants:

```lua
local CURRENT_SCHEMA      = 1
local LIST_DECODE_CAP     = 256 * 1024 -- bytes; above this, list() uses a regex header scan
local SUBDIR              = "bookbuddy_sessions"
local DEFAULT_SESSION_KEEP = 20        -- §13 retention cap; mirrors bbsettings DEFAULTS.session_keep
```

Requires (all already available at runtime):

```lua
local DocSettings = require("docsettings")
local util        = require("util")          -- makePath, writeToFile, readFromFile, findFiles, partialMD5, splitToChars
local ffiUtil     = require("ffi/util")      -- purgeDir, basename, dirname, template, copyFile (`base/ffi/util.lua:214` — the .bak refresh copy, Round 11)
local rapidjson   = require("rapidjson")
local logger      = require("logger")
local lfs         = require("libs/libkoreader-lfs") -- attributes("modification") for the .bak 60s freshness gate (§5.1)
```

**`Session.dir(ui)`** — replicate `bbmemory.baseDirForBook`:

```lua
function Session.dir(ui)
    local file = ui and ui.document and ui.document.file
    local sdr = file and DocSettings:getSidecarDir(file)
    if not sdr or sdr == "" then
        return nil
    end
    return sdr .. "/" .. SUBDIR
end
```

**`Session.newId`** — monotonic-ish, collision-resistant within a process:

```lua
local _seq = 0
function Session.newId()
    _seq = _seq + 1
    -- DELIMITED + zero-padded random: a bare "%x%x" join (seq..rand, no separator/pad) collides within
    -- the same os.time() second -- e.g. (seq=1, rand=0x0a3f) and (seq=0x1a=26, rand=0x3f) BOTH render
    -- "...-1a3f". The id is the filename stem AND the picker dedup key, so a collision silently
    -- overwrites another chat's file or merges two rows -- a data-loss hazard for a "never lose a chat"
    -- feature. The "-%06x" separates the two fields and pins the random to 6 hex digits (Round 11 --
    -- widened from 4: with the mixed seed below, the residual CROSS-DEVICE collision -- two devices
    -- minting an id in the same second with the same _seq -- is ~2^-24 per such pair; disclosed).
    return string.format("%d-%x-%06x", os.time(), _seq, math.random(0, 0xffffff))
end
```
(Seeding, **Round 11**: `math.randomseed(os.time())` alone gives two KOReader processes launched in
the same second — the exact two-instance case the unique tmp name exists for — **identical** `_proc`
values and identical random sequences, voiding the two-writer staging protection. Seed once at module
load by **mixing** clock and address entropy:
`math.randomseed(os.time() + math.floor((os.clock() % 1) * 1e6) + ((tonumber(tostring({}):match("0x(%x+)"), 16) or 0) % 2^20))`
— `os.clock()` contributes sub-second digits and `tostring({})` contributes per-process heap-address
digits, so same-second launches diverge. Then `local _proc = math.random(0, 0xffffff)` — the
staging-name constant used by `save` above.)

**`Session.save(ui, data)`** — atomic + power-loss-safe (verified `util.writeToFile`
signature `writeToFile(data, filepath, force_flush, lua_dofile_ready, directory_updated)`,
`koreader/frontend/util.lua:1141`). **Precision (Round 8):** `force_flush=true` calls
`ffiUtil.fsyncOpenedFile(file)` with `sync_metadata` **nil** (`util.lua:1153`), which is
`C.fdatasync` — file **data** only, **not** the inode's metadata (`base/ffi/util.lua:579-583`). We do
**not** pass `directory_updated` to `writeToFile` (that path fsyncs the file's own directory after a
plain write — not what we need for a staged-rename flow); the rename is flushed by an explicit
`ffiUtil.fsyncDirectory(final)` below. So durability rests on **`fdatasync` (file data) +
`fsyncDirectory` (the rename directory entry)** — at parity with KOReader's own metadata writes
(`LuaSettings` calls `writeToFile(..., true, ...)`, the same `fdatasync` path), **not** a full
file-inode fsync. The persistent `.bak` (below) is the backstop for the residual metadata gap:

```lua
function Session.save(ui, data, keep)
    local dir = Session.dir(ui)
    if not dir then return false, "no sidecar" end
    local ok, err = pcall(function()
        -- FIRST-WRITE parent-dir durability (STEAL-FAT-1, Round 8): makePath creates bookbuddy_sessions/
        -- but never fsyncs the PARENT .sdr directory entry for the NEW subdir. On FAT a power-loss after
        -- makePath but before the post-rename dir-fsync can lose the file even though its CONTENTS were
        -- flushed (the subdir entry was never durable). One-shot: fsync the parent (.sdr) right after a
        -- first-ever makePath, so the new subdirectory entry is durable BEFORE any file lands in it. This
        -- composes with the post-rename fsyncDirectory(final) below (which flushes bookbuddy_sessions/).
        local existed = util.directoryExists(dir)
        util.makePath(dir)                              -- lazy create on first write
        if not existed then
            -- the PARENT of bookbuddy_sessions/ — the same .sdr DocSettings owns
            local file = ui and ui.document and ui.document.file
            if file then ffiUtil.fsyncDirectory(DocSettings:getSidecarDir(file)) end
        end
        data.schema_version = CURRENT_SCHEMA
        data.updated = os.time()
        local json = rapidjson.encode(data)             -- can throw on bad shape → pcall
        local final = dir .. "/" .. data.id .. ".json"
        -- Unique tmp name: a module-load constant (_proc) + a fresh per-write rand
        -- avoids two-writer staging collisions. (No pid: ffiUtil has no getpid export —
        -- getpid is only C.getpid() inside runInSubProcess at ffi/util.lua:412, so
        -- ffiUtil.getpid() would be a nil call; the rand suffix alone already guarantees
        -- per-write uniqueness.)
        local tmp = string.format("%s/%s.%x.%x.tmp", dir, data.id, _proc, math.random(0, 0xffffff))
        local wrote, werr = util.writeToFile(json, tmp, true)   -- force_flush=true: fdatasync file DATA (not metadata — §6/§11)
        if not wrote then error(werr or "write failed") end
        -- PERSISTENT .bak (Round 5; refresh mechanism corrected Round 11): a reader who hard-powers-off
        -- LONG AFTER closing the book (the real failure mode §1 names) needs a fallback for a torn
        -- `final`. Mirror KOReader's LuaSettings:backup freshness gate (luasettings.lua:252-267): only
        -- refresh .bak from a `final` the OS has LIKELY already sync'ed — i.e. one older than 60s — and
        -- DO NOT remove it. Round 11: the refresh is a COPY (ffiUtil.copyFile), NOT a rename-away —
        -- `final` must SURVIVE the refresh so the direct rename below stays an atomic
        -- replace-over-destination on POSIX. (load() falls back to .bak when final is missing/torn.)
        local bak = final .. ".bak"
        local final_existed = util.fileExists and util.fileExists(final)
        if final_existed then
            local mtime = lfs.attributes(final, "modification")
            if not mtime or mtime < os.time() - 60 then        -- only back up a likely-already-sync'ed final
                pcall(ffiUtil.copyFile, final, bak)             -- COPY, best-effort; final stays in place
            end
        end
        -- RENAME-FIRST (Round 11 — replaces Round 8's remove-first). os.rename over an existing
        -- destination is ATOMIC on POSIX: power-loss leaves either the old `final` or the new one,
        -- never neither. Round 8's unconditional os.remove(final)-before-rename ran on ALL filesystems
        -- and destroyed exactly that guarantee on the rapid-multi-turn path (crash between remove and
        -- rename ⇒ no final, a stale-or-absent .bak, and a .tmp that load/list never read — total
        -- loss). So: try the direct rename FIRST; only when it fails (some FAT drivers EEXIST on
        -- rename-over-existing) fall back to freeing the destination — moving `final` → `.bak`
        -- (upgrading the copy above to the freshest content), else removing it — and retry. The
        -- unlink+rename window now exists ONLY on the FAT fallback path, i.e. only on filesystems
        -- where rename-over was never atomic anyway (§6/§11).
        local moved_to_bak = false
        local rok, rerr = os.rename(tmp, final)                 -- atomic replace-over on POSIX
        if not rok and final_existed then
            moved_to_bak = os.rename(final, bak) and true or false
            if not moved_to_bak then os.remove(final) end       -- best-effort; FAT fallback only
            rok, rerr = os.rename(tmp, final)
            -- ROLLBACK (Round 8, retained): if the fallback moved the live final → bak and the retry
            -- STILL failed, the live .json is gone (renamed to .bak) and list/readHeader scan only
            -- *.json — the row would vanish from the picker, recoverable only via load()'s .bak
            -- fallback by EXPLICIT id, which the picker can no longer offer. Restore final from bak
            -- before erroring.
            if not rok and moved_to_bak then os.rename(bak, final) end
        end
        if not rok then
            os.remove(tmp)
            error(rerr or "rename failed")
        end
        ffiUtil.fsyncDirectory(final)                           -- flush the rename: survives power-loss
        -- DO NOT remove bak: a persistent .bak is what survives a hard-power-off arbitrarily long after the
        -- last save. It is refreshed (above) only from a final older than 60s, so it is never the file we
        -- just wrote. Session.delete/prune reap stale .bak/.tmp so this does not accumulate (§5.1/§13).
    end)
    if not ok then
        logger.warn("BookBuddy: session save failed:", err)
        return false, err
    end
    -- Retention: cap per-book session-file growth (§13). A heavily-chatted book on a memory-constrained
    -- e-reader would otherwise accumulate unbounded blobs in .sdr, each carrying full wire history.
    -- `keep` is the optional 3rd arg (Conversation:_persist passes self.settings:getConfig().session_keep
    -- — §5.2/§13); absent → module default. Best-effort; never fails the save. NOTE: `keep` is NOT a
    -- field of `data` — it never lands in the persisted JSON.
    Session.prune(ui, keep)
    return true
end

function Session.prune(ui, keep)
    keep = tonumber(keep) or DEFAULT_SESSION_KEEP
    -- Sweep stale staging files regardless of the keep cap (§5.1): a crashed save leaves a
    -- <id>.<proc>.<rand>.tmp that is NEVER overwritten (each save mints a fresh-unique tmp name), so a
    -- crashed tmp is orphaned permanently — unbounded litter on Syncthing-metered devices. Remove any
    -- *.tmp older than a few minutes; the AGE GATE ALWAYS APPLIES (Round 11).
    pcall(function()
        local dir = Session.dir(ui)
        if dir and util.directoryExists(dir) then
            util.findFiles(dir, function(path)
                local name = ffiUtil.basename(path)
                -- Syncthing conflict copies (Round 11 — bound the litter): keep them for MANUAL
                -- recovery short-term, but reap any *.sync-conflict-*.json older than ~30 days.
                -- They are never counted toward (nor deleted by) the keep cap — list filters them.
                if name:match("%.sync%-conflict%-.*%.json$") then
                    local cmtime = lfs.attributes(path, "modification")
                    if cmtime and cmtime < os.time() - 30 * 86400 then os.remove(path) end
                    return
                end
                if not name:match("%.tmp$") then return end
                local stem = name:match("^(.-)%.%x+%.%x+%.tmp$") -- <id> from <id>.<proc>.<rand>.tmp
                -- Only reap files that match THE PLUGIN'S OWN tmp shape (stem non-nil). A Syncthing
                -- in-flight partial (~syncthing~….tmp) does NOT match the strict stem → never touched,
                -- so we cannot os.remove another device's in-progress sync pull (§12). Round 11: the
                -- age gate is AND, not OR — a young tmp is NEVER reaped, even when no live <id>.json
                -- exists yet: the FIRST save of a new session has exactly that shape while its write
                -- is in flight (and after a crash mid-first-save, the fdatasync'd tmp can briefly be
                -- the only surviving copy — deleting it young would be self-inflicted data loss).
                if not stem then return end
                local mtime = lfs.attributes(path, "modification")
                local old = (not mtime) or mtime < os.time() - 180   -- > ~3 min ⇒ not an in-flight write
                if old then os.remove(path) end
            end, false)   -- recursive=false: sessions are flat; never descend .stversions/.sync-conflict dirs
        end
    end)
    if keep < 1 then return end                      -- 0/negative ⇒ unbounded (disabled), keep everything
    pcall(function()
        local entries = Session.list(ui)             -- already sorted updated desc; conflicts filtered
        for i = keep + 1, #entries do                -- delete everything past the newest `keep`
            Session.delete(ui, entries[i].id)        -- Session.delete also reaps the matching .bak
        end
    end)
end
```
(`_proc` is one module-load constant — `local _proc = math.random(0, 0xffffff)` — captured next to the
`math.randomseed(os.time())` call. There is **no pid**: `ffi/util.lua` exports no `getpid`; `getpid`
appears only as `C.getpid()` inside `runInSubProcess` (`:412`), so an `ffiUtil.getpid()` call would
nil-error. The fresh per-write `math.random` suffix already guarantees tmp-name uniqueness.)

**`Session.load(ui, id)`** — schema gate + shape check (never `_resolve`; `id` is constrained to a
basename, no path separators):

```lua
function Session.load(ui, id)
    local dir = Session.dir(ui)
    if not dir or type(id) ~= "string" or id:find("[/\\%z]") then return nil, "bad id" end
    local path = dir .. "/" .. id .. ".json"
    -- decodeOne applies the FAT read-side contract: a torn/half-synced blob characteristically carries
    -- an embedded NUL (NUL-padded tail); reject it BEFORE decode, then schema-gate + shape-check.
    local function decodeOne(raw)
        if not raw then return nil end
        if raw:find("%z") then return nil end           -- torn (FAT NUL sentinel)
        local ok, data = pcall(rapidjson.decode, raw)
        if not ok or type(data) ~= "table" then return nil end
        if data.schema_version ~= CURRENT_SCHEMA then return nil end
        if type(data.messages) ~= "table" then return nil end
        return data
    end
    local data = decodeOne(util.readFromFile(path))     -- nil if missing/unsynced/torn/bad-shape
    if data then return data end
    -- FAT power-loss fallback (§6): the rename-over window can momentarily leave `final` missing or
    -- torn while the prior-good `.bak` (written by save before the rename) is still intact. Fall back
    -- to it, applying the SAME NUL sentinel + schema gate. Bounds loss to one turn, not the whole chat.
    local bak = decodeOne(util.readFromFile(path .. ".bak"))
    if bak then return bak end
    return nil, "not found"
end
```

**`Session.list(ui)`** — header-only / capped decode (so the picker never stalls on a pathological
300 KB session), conflict-file filter, sorted `updated` desc:

```lua
function Session.list(ui)
    local dir = Session.dir(ui)
    local out = {}
    if not dir or not util.directoryExists(dir) then return out end
    util.findFiles(dir, function(path)
        local name = ffiUtil.basename(path)
        if not name:match("%.json$") then return end          -- ignore *.tmp
        if name:match("%.sync%-conflict%-") then return end    -- Syncthing conflict copies
        local hdr = readHeader(path)                            -- bounded; see below
        if hdr and hdr.schema_version == CURRENT_SCHEMA then
            out[#out + 1] = hdr
        end
    end, false)   -- recursive=false (frontend/util.lua:789 defaults true): never descend a Syncthing
                  -- .stversions/ or .sync-conflict/ dir in the .sdr; sessions are flat (§12)
    table.sort(out, function(a, b) return (a.updated or 0) > (b.updated or 0) end)
    return out
end
```

`readHeader(path)` reads the file; **first it applies the NUL sentinel** (`raw:find("%z")` → return
`nil`, so a torn/half-synced blob is never surfaced as a ghost picker row). If its size ≤
`LIST_DECODE_CAP` it `rapidjson.decode`s the whole thing (which also re-validates structure) and
returns only the header fields `{id, created, updated, title_snippet, turn_count, anchor, book,
schema_version}`. Above the cap it falls back to a **regex header scan** (the writer emits header
fields before the large `messages`/`transcript` arrays, but the scan does not depend on ordering — it
greps for `"title_snippet"%s*:%s*"(.-)"`, `"updated"%s*:%s*(%d+)`, `"schema_version"%s*:%s*(%d+)`,
etc.). Because this path **bypasses `decode`**, it additionally **requires the schema marker**
(`"schema_version"%s*:%s*1`) to be present before trusting any extracted field — a half-synced large
blob with no marker is omitted from `list`. This keeps the picker bounded without a fragile
partial-JSON parser. Normal sessions are small; the cap only bites pathological ones.

**`Session.delete` / `clear` / `hasContent`:**

```lua
function Session.delete(ui, id)
    local dir = Session.dir(ui)
    if not dir or type(id) ~= "string" or id:find("[/\\%z]") then return false end
    -- Reap the persistent .bak too (§5.1): with the .bak fix, every deleted/pruned session would
    -- otherwise leave <id>.json.bak forever in .sdr (list ignores it, but it accumulates and syncs
    -- over Syncthing). Best-effort; ignore failure.
    os.remove(dir .. "/" .. id .. ".json.bak")
    return os.remove(dir .. "/" .. id .. ".json") and true or false
end

function Session.clear(ui)
    local dir = Session.dir(ui)
    if not dir or not util.directoryExists(dir) then return true end
    return ffiUtil.purgeDir(dir) and true or false           -- mirrors bbmemory.lua:471
end

function Session.hasContent(ui)
    return #Session.list(ui) > 0
end
```

Every entry point is `pcall`-wrapped where it touches disk; failures `logger.warn` and degrade,
never propagate (mirrors `Store:execute`, `bbmemory.lua:430-434`).

### 5.2 `bbconversation.lua`

New functions:

```lua
function Conversation:serialize()             -- -> §3 table (NO _dropDanglingTail; strips cache_control)
function Conversation.restore(o, data)        -- -> Conversation | nil,reason (pair-then-drop; posture re-assert)
function Conversation:_persist()              -- save-if-enabled; swallows errors
function Conversation:_reanchorPosition(data) -- §8; returns ok, reason_or_nil
function Conversation:_effectiveConfig()      -- §9.6; live config overlaid with resumed posture
function Conversation:_rebuildToolSpecs()     -- §9.6; (re)derive tool_specs from _effectiveConfig()
function Conversation:_isResumableState()     -- §7.3; true iff live history is at a clean terminal boundary
```

**`Conversation:new(o)`** (`:171-223`): add fields `o._session_id`, `o._session_created`,
`o._title_snippet`, `o._spoiler_consent = false`, `o._resume_note = nil`, `o._resume_banner = nil`,
`o._resume_consent_reset = false` and `o._resume_notice_shown = false` (Round 6 — the first drives the
title-tail `"(spoilers reset)"` note and the Step-6 one-shot `InfoMessage` **when `not _reveal_all`**,
Round 10; the second is the one-shot
guard so a later `_render` does not re-toast, §8.2 Step 3/6),
`o._resumed = false` (set true by `_reanchorPosition` on a successful resume; drives the §8.2b per-turn
nil-page guard in `_loop`), `o._reveal_all = false` (Round 6 — session-only spoiler re-grant set by
`resumeSession`'s "Reveal everything" escape hatch; gates the rewind redaction in Steps 5/5b/5c/7, §8.2),
`o._mrp_by_tool_use_id = {}` (the `max_referenced_page` side-table keyed by
`tool_use_id`, §5.2),
`o._dirty = false` (Round 9, STEAL-2 — the per-conversation write-needed flag: set `true` in `ask()` and
at `_storeAssistant`, cleared after a successful `Session.save`, and left `false` by `restore()` so a
resumed-but-unasked session keeps its originally-saved `anchor.xpointer` — protecting a later resume's
backward-drift classification; gated in `_persist`, §5.2),
and the (initially nil) config overrides `o._thinking_override`, `o._web_search_override`,
`o._memory_override` (§9.6 — **no `_model_override`**: `model` is recorded for diagnostics only and is
never enforced). The tool-spec assembly (`:176-208`) moves into
`_rebuildToolSpecs()` (called by `new` and again by `restore`). The scratch-clear block (`:193-197`,
which resets `ui._bookbuddy_locators`) is **untouched**, and `restore` runs `new` *first* — so a
restored chat always gets a clean locator table (§8 LEAK-4).

**`Conversation:_loop`** (`:273-274`): read `local cfg = self:_effectiveConfig()` (§9.6) in place of
`self.settings:getConfig()`, so the resumed posture governs `buildBody`'s `body.thinking`/`body.tools`
for the resumed session's lifetime (closes the toggle-thinking-then-resume 400 in both directions).

**`Conversation:ask(question)`** (`:225-260`):
- On the **seed branch** (`#self.messages == 0`): set `self._session_id = self._session_id or Session.newId()`,
  `self._session_created = os.time()`, and `self._title_snippet` to the codepoint-safe 60-char prefix:
  ```lua
  local chars = util.splitToChars(question or "")
  self._title_snippet = table.concat(chars, "", 1, math.min(#chars, 60))
  ```
- On **every** branch: if `self._resume_note` is set (armed by `_reanchorPosition`), prepend it to
  the user message content and clear it, so the resume marker rides the next user turn (§8 Step 4):
  ```lua
  -- seed branch builds an array; follow-up branch builds {role="user", content=question}
  -- when _resume_note is present on a follow-up, wrap as an array:
  --   content = { { type="text", text=self._resume_note }, { type="text", text=question } }
  ```
  **The `_resume_note` wrap affects `messages[].content` ONLY.** The transcript entry for this user
  turn keeps the **plain `question` string** (`{role="user", text=question}`) — it must NOT receive the
  wrapped array, or `_transcriptText` would be handed a table where it expects a string and the render
  breaks. The resume marker is a wire-only steering block; it is never shown in the display log.

- **Dirty-tracking (Round 9, STEAL-2):** set `self._dirty = true` at the top of `ask()` (every branch —
  a new user turn always makes the conversation write-needed). The flag is also set at `_storeAssistant`
  (see below) so a turn that ends without re-entering `ask()` still marks the conversation dirty, and is
  cleared only after a successful `Session.save` inside `_persist`. `restore()` leaves it `false`.

**Spoiler-consent tracking** in the tool loop (`:566-578` region): when a dispatched `tool_use`
carries `input.spoiler == true` for `grep`/`read`, set `self._spoiler_consent = true` (this is the
value persisted as `spoiler_consent`).

**Dirty flag at `_storeAssistant` (Round 9, STEAL-2).** Set `self._dirty = true` in `_storeAssistant`
(`bbconversation.lua:599-608`) — every stored/extended assistant message advances the wire history that
`_persist` would write, so this is the precise complement to the `ask()` set: a resumed session that is
then *closed without an ask* never hits either site, stays `_dirty=false`, and `_persist` (§5.2) skips
the re-write that would otherwise clobber its originally-saved `anchor.xpointer`.

**Transcript `_tool_use_id` stamping — TWO sites (Round 8 — close the web-search transcript leak).**
The rewind transcript scrub (§8.2 Step 7 Rule 1) keys on `transcript[]._tool_use_id ∈ redacted_ids`.
The client-tool dispatch line already gets `tool_entry._tool_use_id = tu.id` at `bbconversation.lua:562`
(the dispatch loop). But the **web-search summary line** built by `_renderAssistantTurn`'s
`server_tool_use`/`web_search` branch (`bbconversation.lua:800-809`) — `{role="tool", text="  →
Searched the web for … — N result(s)"}` — carries **no** `_tool_use_id`. So before this fix, on a
tainted-backward resume the wire `web_search_tool_result` block was redacted (good — §8.2 Step 7), but
the on-screen search-summary line (which can quote a spoiling query, e.g. `Searched the web for "how
does Moby-Dick end"`) was **never** scrubbed, and because Rule 2 only arms `turn_was_redacted` off a
matched `tool` line, a web-search-**ONLY** turn never armed it — so the trailing assistant answer line
that quotes the web result also rendered verbatim. (Step 5c's web-search quarantine marker is a
wire-only steering block and cannot touch the rendered persisted transcript.) **Fix:** in that
`server_tool_use`/`web_search` branch, stamp the transcript entry with the `server_tool_use` id:

```lua
-- bbconversation.lua _renderAssistantTurn, server_tool_use/web_search branch (≈:800-809):
-- stamp the web-search summary transcript line with the server_tool_use id (b.id). The matching wire
-- web_search_tool_result block carries tool_use_id == b.id by pairing, so §8.2 Step 7's redacted_ids
-- (which collects each redacted web_search_tool_result block's tool_use_id) lines up with
-- this line: Rule 1 scrubs the search summary AND arms Rule 2 for the answer line of the same turn.
self.transcript[#self.transcript + 1] = { role = "tool", text = text, _tool_use_id = b.id }
```

`snapshotTranscript`/`sanitizeTranscript` already preserve `_tool_use_id` (§3.3), so the stamped id
round-trips to disk and is present on the resumed transcript the scrub walks.

**`max_referenced_page` annotation (§8, read-only).** At the **same** consent-tracking site, when a
`grep`/`read`/`book_context` `tool_use` is dispatched, record `max_referenced_page` into a **parallel side-table**
`self._mrp_by_tool_use_id[tu.id] = mrp` — **never onto the live `tool_result` block**. This is
load-bearing: the block built in the tool loop (`bbconversation.lua:574-578`) is appended to
`self.messages` (`:580`) and resent on the **next live turn** by `buildBody`, which nulls only
`cache_control` (`bbanthropic.lua:60-69`) and does **not** strip unknown `tool_result` fields. An
annotation written onto that live block would therefore be sent to Anthropic and **400 on every
multi-turn tool-using chat** (strict `tool_result` schema), no resume involved. Keeping the value in a
side-table that `serialize()` merges into the **deep-copied** persisted messages only (§9.1) keeps
`self.messages` wire-clean while still persisting the redaction annotation.

The gate's own clamp values (`grep`'s `cap`, `bbtools.lua:200-211`; `read`'s `cur+1` clamp,
`bbtools.lua:381-383`) are computed **locally inside the tools and are never returned through
`Tools.execute`** (the loop sees only `tu.input`, `result`, `summary` — `bbconversation.lua:565-578`).
So the annotation is **re-derived in the loop** from the same inputs the gate reads — it does **not**
alter the gate; it reads `currentPage(ui)` and `tu.input` exactly as the gate does. For grep, it
additionally consults an **additive read-only third return** from `tool_grep`, `had_unbounded_hit`,
true when any **rendered/shown** item had a nil page (`item._page == nil`). **Pin it to `shown[]`, not
`visible[]` (Round 7):** only `shown[]` (the first `math.min(#visible, max_results)` items — the
lock-step array `tool_grep` already builds at `bbtools.lua:229-243`) is actually rendered into the
returned `tool_result` content; `visible[]` is the larger superset. The redaction protects the
**rendered** content, so a nil-page hit in `visible[9..]` that is **never shown** must **not** arm the
sentinel — otherwise it over-redacts that turn permanently on every future rewind. Iterate `shown[]`:
the grep gate shows nil-page hits regardless of the cap (`bbtools.lua:219`), so such a *shown* hit can
be physically past the reader even on a non-spoiler grep; recording the sentinel makes it redactable on
rewind (this is instrumentation only — **no gate change**).

**`Tools.execute` must thread a third return (Round 5 — load-bearing wiring).** As written today,
`Tools.execute` (`bbtools.lua:1088-1099`) destructures `local ok, result, summary = pcall(fn, …)` and
`return result or "", summary` — **only two values**. So `had_unbounded_hit` is **always nil** at the
call site and the nil-page redaction below is dead code (the §8.3 "closed for rewind" claim does not hold
until this is wired). Thread the tool's third value through:

```lua
-- bbtools.lua Tools.execute: capture and forward a third return.
-- Returns (result_string, summary, extra). `extra` is tool-specific read-only instrumentation
-- (currently tool_grep's had_unbounded_hit); buildBody / the wire path never see it.
local ok, result, summary, extra = pcall(fn, ui, input or {})
if not ok then … end
return result or "", summary, extra
```

`tool_grep` returns `had_unbounded_hit` as its **third** value (after `result, summary`); every other
tool returns no third value (so `extra` is nil and the grep branch alone consults it). The §17 anchor
comment on `Tools.execute` is updated to `Returns (result_string, summary, extra)`. This is a tiny,
additive `bbtools` change — no gate, cap, partition, or clamp behavior changes (§8.3):

**Where the mrp block lives in the loop (Round 6 — pinned; Round 11 — anchored by NAME, not by
else-position).** The live loop declares `local result, summary` **before** the per-tool dispatch
split: the **memory** branch calls `self.memory:execute(tu.input)` (two returns, **no**
`Tools.execute`, no third value); since the `ask_user` tool landed (2026-07 — see the anchor-drift
note at the top) there is also an **`ask_user`** branch (`bbconversation.lua:688-697`) that parks the
coroutine and never touches `Tools.execute`; and the branch that actually calls
**`Tools.execute(tu.name, tu.input, self.ui)`** is where Round 5 threads the **third** return
(`had_unbounded_hit`). The mrp / `had_unbounded_hit` derivation block below **must live inside the
`Tools.execute` dispatch branch** — identified by the `Tools.execute` call itself, NOT by "the else
of the memory split" (the loop is a **≥3-way split** now; an else-position anchor lands the block in
the wrong branch after any future tool addition). Not after the if-chain either: a naive implementer
placing it there would reference `had_unbounded_hit`, which is assigned **only** in the
`Tools.execute` branch, and would re-declare the `result`/`summary` that already exist before the
split. Concretely:
- The **memory** and **`ask_user`** branches record **nothing** into `self._mrp_by_tool_use_id` (no
  spoiler-gated book read happens through either; neither has a page bound).
- `result`/`summary` referenced below are the **ones declared before the split** (do **not** re-declare
  them); only `had_unbounded_hit` is the new third capture, local to the `Tools.execute` branch.

```lua
-- SPOILER_SENTINEL: a large integer standing for "unbounded / past current page" (§3.3). JSON has no
-- infinity, and the persisted field is the SINGLE redaction channel — a spoiler-true read therefore
-- records the sentinel (not an unpersisted flag), so Step 7 redacts it on ANY rewind even after restore.
local SPOILER_SENTINEL = 0x7fffffff

-- INSIDE the Tools.execute dispatch branch only (anchored by the Tools.execute CALL — the loop is a
-- ≥3-way split: memory / ask_user / Tools.execute) — Tools.execute is the sole site that returns the
-- third value. result/summary are the locals declared before the split; do NOT
-- re-declare them. spoiler comes from tu.input.spoiler for this grep/read call. tool_grep now returns an
-- additive read-only third value, had_unbounded_hit, true when any RENDERED/SHOWN hit had a nil page
-- (computed over shown[], NOT visible[] — only shown[] reaches the returned content; §3.3/§5.2).
--   result, summary, had_unbounded_hit = Tools.execute(tu.name, tu.input, self.ui)
local mrp
if tu.name == "grep" then
    -- Fail-safe: a spoiler grep OR a grep that emitted any unbounded (nil-page) visible hit records the
    -- sentinel (the nil-page hit can be physically past the reader — bbtools.lua:219). Otherwise clamp.
    mrp = (spoiler or had_unbounded_hit) and SPOILER_SENTINEL
        or math.min(currentPage(self.ui) or math.huge, tonumber(tu.input.max_page) or math.huge)
elseif tu.name == "read" then
    -- Fail-safe: a spoiler read, OR a read whose live page is unknown, records the sentinel (so a later
    -- rewind redacts it rather than leaving an un-redactable block). A normal read records cur_page.
    mrp = (spoiler or currentPage(self.ui) == nil) and SPOILER_SENTINEL or currentPage(self.ui)
elseif tu.name == "book_context" then
    -- LEAK (Round 4): tool_book_context (bbtools.lua:455-476) emits "Current page: <cur> of <total>"
    -- AND "Current chapter: <title>". At save time <cur> is the HIGHER saved page and the chapter title
    -- can itself spoil (e.g. "Chapter 30: Ahab's Death"). Annotate its tool_result so Step 7 redacts it
    -- on a rewind exactly like a read: record the live page (or the sentinel when it is unknown), so the
    -- single > cur_page predicate fires on a backward resume. (get_toc/get_highlights are similar
    -- pre-existing live-gate gaps — §8.3 — out of scope here.)
    mrp = currentPage(self.ui) or SPOILER_SENTINEL
end
-- mrp may be math.huge (grep, both inputs unknown) — clamp to the sentinel for a finite JSON integer.
if mrp == math.huge then mrp = SPOILER_SENTINEL end
-- Record into the SIDE-TABLE, NOT the wire block: a value on the live tool_result block would be
-- resent by buildBody and 400 every multi-turn tool chat (§3.3). serialize() merges this into the
-- deep-copied persisted messages only (§9.1).
if mrp then self._mrp_by_tool_use_id[tu.id] = mrp end
```

`currentPage` is a **bbtools-local** (`bbtools.lua:58`); import/expose it to `bbconversation` (or read
it once at the consent-tracking site where the spoiler flag is already in scope). This reads the same
inputs the gate reads and **does not alter the gate**. The annotation lives in
`self._mrp_by_tool_use_id` (a `{}` initialized in `new()`); `serialize()` merges it into the persisted
deep copy (§9.1) and the resume path strips it from the decoded persisted blocks before any `buildBody`
(the unconditional Step 7b pass at the close of `_reanchorPosition` — `restore` itself intentionally
leaves the field on so Step 7's rewind redaction can read it first, §7.3). It **never touches `self.messages`**, so the live continuation path is
never sent an unknown `tool_result` field. `had_unbounded_hit` is purely additive instrumentation in
`tool_grep` (no gate behavior change — §8.3); it reaches the loop only because `Tools.execute` now
forwards a **third return** (above). Without that wiring `had_unbounded_hit` is always nil and the
sentinel fail-safe is dead code — so the `Tools.execute` signature change is mandatory, not optional
(§15 item 4).

**Save sites** — insert `self:_persist()` at each verified **terminal, clean-history** render. These
four are exactly where the wire history ends on an assistant message and is resendable. **Since Round 9
`_persist` is self-guarding** (STEAL-1: an early `if not self:_isResumableState() then return end`), so
these call sites are **scheduling hints** — *when* to attempt a save — not correctness-load-bearing: a
refactor that moves a terminus or adds a caller can no longer silently persist a dangling tail.
- `bbconversation.lua:582` — model finished, no `tool_use` (terminal `else` of the tool loop).
- `bbconversation.lua:590` — substantive-turn budget exhausted (loop broke; final round had no tools).
- `bbconversation.lua:305-306` — pause_turn resume-limit reached (partial reply rendered).
- `bbconversation.lua:514` — empty-200 placeholder stored after retries (now an explicit save site).

Mid-loop tool rounds (`:580`) and error/cancel exits (`:328-332`) **do not** persist — the history
may be dangling or the turn incomplete. `_persist` is also a no-op when sessions are disabled, there is
no sidecar, **or the document has no xpointer** (paging docs — PDF/CBZ). The last case is load-bearing:
a paging doc has a structurally `nil` `currentPage` and no `getXPointer`, so the §8 spoiler argument
cannot hold and Step 0.5 would refuse every resume anyway — persisting would only **litter every PDF's
`.sdr` with growing, unresumable blobs**. Skip the write when `safeXPointer(ui)` is nil (paging-doc
sessions are not persisted/resumable by design — §16, §8.2 Step 0.5).

```lua
function Conversation:_persist()
    if not (self.settings and self.settings:getConfig().enable_sessions) then return end
    if not Session.dir(self.ui) then return end
    -- STEAL-1 (Round 9): self-guarding precondition. _persist's correctness used to depend on it being
    -- called ONLY from the four pinned terminal sites (:582/:590/:305-306/:514) plus the close path; a
    -- future refactor moving a terminus or adding a caller would silently persist a dangling tail.
    -- Promote the close-path predicate to a UNIVERSAL precondition: never persist a non-resumable state.
    -- The four call sites become scheduling HINTS, not correctness-load-bearing.
    if not self:_isResumableState() then return end
    -- STEAL-2 (Round 9): dirty check. A resumed-but-unasked session (onCloseDocument flush of a session
    -- restored then closed without an ask) would otherwise re-write an identical blob and re-snapshot
    -- anchor.xpointer — on a BACKWARD resume that overwrites the originally-saved position with the
    -- rewound position, harming a later resume's compareXPointers drift classification. _dirty is set
    -- by ask()/_storeAssistant and left false by restore(), so an unmodified resume keeps its saved anchor.
    if not self._dirty then return end
    -- Paging docs (PDF/CBZ) have no xpointer ⇒ unresumable spoiler-safely (§8). Do not litter their
    -- .sdr with blobs Step 0.5 would always refuse. safeXPointer pcall-wraps getXPointer; nil for non-cre.
    if not safeXPointer(self.ui) then return end
    local ok, data = pcall(function() return self:serialize() end)
    if ok and data then
        -- Pass the live retention cap (§13); Session.save prunes oldest-by-updated beyond it.
        local keep = self.settings and self.settings:getConfig().session_keep
        -- Round 11: CHECK the return. Session.save swallows/logs errors and returns false on failure
        -- (disk full, transient sidecar loss); clearing _dirty on a FAILED save would make every
        -- later _persist/close-flush a no-op — silent loss of all subsequent turns while §11 claims
        -- "in-memory remains the source of truth." A failed save leaves _dirty true so the next
        -- terminal turn / the onCloseDocument flush RETRIES the write (§5.3/§6).
        local saved = Session.save(self.ui, data, keep)
        if saved then
            self._dirty = false                           -- cleared ONLY on an actually-successful save
        end
    end
end
```

**`_closeViewer`** (existing): on **viewer** close, calling `self:_persist()` is **not** added — viewer
close can happen mid-error; the four terminal sites already cover the resumable states. (Decision: avoid
a viewer-close save that could persist a dangling tail.)

**Document close (Round 4; rationale reconciled Round 11): DO flush, gated.** Distinct from viewer
close, the §5.3 `BookBuddy:onCloseDocument()` hook **does** flush on book close / power-off **when
`conv:_isResumableState()` is true**. **What it actually buys (Round 11 — honest scope):** the four
terminal sites already save every completed turn, so a between-turns close normally finds
`_dirty == false` and the flush no-ops — the Round-4 "covers the common between-turns close" framing
overstated it. Its real value is (a) **retrying a previously FAILED terminal save** — `_persist` now
leaves `_dirty` true on a failed `Session.save` (disk full, transient sidecar loss), so the close
flush is the last-chance retry before the conversation is garbage-collected — and (b)
**future-proofing**: any new terminal state a refactor forgets to hook still gets flushed at close.
Gating on the exact `_dropDanglingTail` danglingness predicate is what makes reversing the original
"no close-time save" decision safe: a mid-turn close is skipped, so the close-time flush can never
persist a dangling tail (§5.3/§6).

### 5.3 `main.lua`

- **Primary "Chat about this book" entry becomes Continue-or-New (Round 8 — close the invisible-fork
  data-loss mode, steal Approach B).** The primary menu item (`main.lua:94-99`) currently always calls
  `self:promptAndStart(nil)`, so it **always mints a fresh** `Conversation`/`_session_id`/file. Resume
  was reachable **only** via the separate secondary "Resume a chat about this book" item below — so a
  reader who taps the familiar primary entry never sees their prior chat and silently starts a forgotten
  **parallel** session (the `_isResumableState` guard protects only the resume-picker-replaces-live path,
  **not** this primary-entry fork). Gate the primary callback on
  `self.settings:getConfig().enable_sessions and Session.hasContent(self.ui)`: when true, show a
  `ConfirmBox` chooser; otherwise fall straight through to `promptAndStart(nil)` (zero behavior change
  when sessions are off or no resumable session exists). No global store is needed — A already has the
  per-book `Session.hasContent(ui)` and newest-first `Session.list(ui)`:

  ```lua
  -- main.lua:94-99 primary "Chat about this book" callback (Round 8):
  callback = function()
      if self.settings:getConfig().enable_sessions and Session.hasContent(self.ui) then
          self:showContinueOrNew()   -- ConfirmBox: [Continue last chat] [Start new chat]
      else
          self:promptAndStart(nil)   -- unchanged path (off, or no sessions for this book)
      end
  end
  ```

- **`BookBuddy:showContinueOrNew()`** (NEW, Round 8) — a `ConfirmBox` whose two actions are: "Continue
  last chat" → `self:resumeSession(Session.list(self.ui)[1].id)` (the newest-first first row — same
  `Session.list` the picker uses); "Start new chat" → `self:promptAndStart(nil)`. This eliminates the
  invisible-fork data-loss mode (the real failure: a forgotten parallel session) while leaving the
  full picker available for older chats via the secondary item below.

  ```lua
  function BookBuddy:showContinueOrNew()
      local ConfirmBox = require("ui/widget/confirmbox")
      local sessions = Session.list(self.ui)   -- newest-first; conflicts filtered (§5.1)
      if #sessions == 0 then return self:promptAndStart(nil) end   -- race: gone since hasContent
      UIManager:show(ConfirmBox:new({
          text = _("You have a saved chat about this book. Continue it, or start a new one?"),
          ok_text = _("Continue last chat"),
          ok_callback = function() self:resumeSession(sessions[1].id) end,
          cancel_text = _("Start new chat"),
          cancel_callback = function() self:promptAndStart(nil) end,
      }))
  end
  ```

- **Menu entry** at index 2 (mirror the "Chat about this book" item, `:94-99`), gated on
  `self.settings:getConfig().enable_sessions and Session.hasContent(self.ui)`:
  text `_("Resume a chat about this book")`, callback `function() self:showResumePicker() end`. (This
  secondary item is still the way to reach an **older** chat than the most recent one offered by the
  primary-entry chooser above.)
- **`BookBuddy:showResumePicker()`** — §7.
- **`BookBuddy:resumeSession(id)`** — §7; **closes any live conversation first** (otherwise two live
  `Conversation`s autosave the same file).
- **Wire `self.conversation` (Round 5 — load-bearing prerequisite, Checklist 0.5).** Every guard below
  reads/writes `self.conversation` on the plugin object, but that field is **never created today**: at
  `main.lua:166` the conversation is a function-local (`local conversation = Conversation:new{…}`) that
  survives only via the viewer widget. Without storing it on `self`, `onCloseDocument` can never find the
  live conversation (the Round-4 between-turns close-flush is **dead code**), `resumeSession`'s
  close-the-live-chat-first and mid-turn-loss gate never fire, and two live conversations can coexist
  autosaving the same file. **Fix:** assign `self.conversation = Conversation:new{…}` at `main.lua:166`
  (in addition to / instead of the local), and **null it on viewer close and on replace** (`resumeSession`
  sets `self.conversation = conv` after closing the old one). §5.3's `onCloseDocument` and §7.3's
  resume-replace guards **depend on this single wiring step**.
- **`BookBuddy:onCloseDocument()`** (NEW, Round 4; rationale reconciled Round 11) — close-document
  flush. A previously had **no** close-document hook (verified: `main.lua` has no `onCloseDocument`
  handler) and §5.2 declined a close-time save. **Round 11 — what the hook is actually for:** the four
  terminal sites save every completed turn, so a between-turns close normally finds `_dirty == false`
  and this flush no-ops; its real value is **retrying a terminal save that FAILED** (a failed
  `Session.save` now leaves `_dirty` true — §5.2 Round 11) plus future-proofing against a terminal
  state a refactor forgets to hook. `onCloseDocument` fires
  **before** the document is nulled (copy B's ordering note: `CloseDocument` precedes document nulling),
  so `ui.document` (hence the sidecar dir and xpointer) is still valid. When a live conversation exists,
  `self.settings:getConfig().enable_sessions` is on, **and `conv:_isResumableState()` is true**, call
  `conv:_persist()`:

  This hook reads `self.conversation`, which **only exists if the Checklist-0.5 wiring is done** (the
  conversation is stored on `self` at `main.lua:166` and nulled on viewer close / replace). Without it
  `conv` is always nil and the flush below is dead code:

  ```lua
  function BookBuddy:onCloseDocument()
      local conv = self.conversation
      if not conv then return end
      if not (self.settings and self.settings:getConfig().enable_sessions) then return end
      -- Gate on _isResumableState so a MID-TURN close is skipped (no dangling-tail persist) — this is
      -- exactly what lets A safely reverse the §5.2 "no close-time save" decision. CloseDocument fires
      -- before ui.document is nulled (B's ordering note), so the sidecar + xpointer are still resolvable.
      -- (Since Round 9 _persist self-guards on the same predicate (STEAL-1) AND on _dirty (STEAL-2), so
      -- this external gate is belt-and-suspenders and a resumed-but-unasked close is additionally a no-op.)
      if conv:_isResumableState() then conv:_persist() end
  end
  ```

  Gating on `_isResumableState()` (the **exact** `_dropDanglingTail` danglingness predicate, §7.3) is
  what makes reversing §5.2's "no close-time save" safe: a seed-only / mid-turn / orphan-tail chat is
  skipped, so the close-time flush can never persist a dangling tail. (Since Round 9 `_persist` itself
  re-checks `_isResumableState()` (STEAL-1) and `_dirty` (STEAL-2), so this gate is now redundant defense,
  and a **resumed-but-unasked** close additionally writes nothing — preserving its saved `anchor.xpointer`.
  `_persist` is still a no-op for paging docs via `safeXPointer` nil, §5.2.)

### 5.4 `bbsettings.lua`

- `DEFAULTS.enable_sessions = true` (§13). `getConfig` exposes it.
- `DEFAULTS.session_keep = 20` (§13 retention). `getConfig` exposes it; read by `_persist` and passed
  to `Session.save`/`Session.prune` (oldest-by-`updated` beyond the cap are deleted after a successful
  write). A value `< 1` disables pruning (keep everything).
- Toggle menu item "Save chats" mirroring the memory checkbox (`:293-308`).
- "Manage saved chats" item (mirror `:342-350`) → `BookBuddy:showSessions(ui)`: a `Menu` listing the
  current book's sessions with per-row **Delete**, plus a "Clear all chats" `ConfirmBox` →
  `Session.clear(ui)`.
  - **Per-row delete requires confirmation (Round 4).** The per-row Delete is **`ConfirmBox`-gated** (or
    swipe-to-reveal), matching bbmemory's destructive-op pattern (`bbsettings.lua:182`). On low-contrast
    e-ink with imprecise touch, a single mis-tap would otherwise destroy a full multi-turn conversation
    with **no undo** — the persistent `.bak` is same-id-only and `Session.delete` **explicitly reaps it
    too** (Round 5, §5.1), so the `.bak` does **not** survive a delete. This is the most likely
    **accidental** data-loss path in normal use. The confirm text names the chat
    (e.g. its `title_snippet`); `ok_callback` calls `Session.delete(ui, id)` then refreshes the list.

### 5.5 `_meta.lua`

- Bump `version` (dotted numeric) on release.
- (No `_meta` change for retention; `session_keep` lives in `bbsettings` DEFAULTS — §5.4/§13.)

---

## 6. Lifecycle & save points

- **Autosave per terminal turn, same file.** Every save reuses `_session_id` → overwrites one file.
  A 10-turn chat writes ~10 times; JSON is small; this is the natural debounce (no timer). The first
  save sets `created`, `title_snippet`, `book.ident`; every save updates `updated` and re-snapshots
  `anchor` to the *current* xpointer at save time.
- **Close-document flush (Round 4; scope honest since Round 11).** In addition to the four terminal
  save sites, `onCloseDocument` (§5.3) flushes on book close / power-off **when the live conversation
  is at a resumable state** (`conv:_isResumableState()`). Because the terminal sites already save
  every completed turn, this flush normally no-ops on the `_dirty` gate; its concrete jobs are
  **retrying a previously failed terminal save** (a failed `Session.save` leaves `_dirty` true —
  §5.2 Round 11) and backstopping unhooked future terminal states. `CloseDocument` fires **before**
  `ui.document` is nulled (B's ordering
  note), so the sidecar dir + xpointer are still resolvable. The `_isResumableState` gate skips a
  mid-turn close (no dangling-tail persist) — this is what lets A safely reverse the original §5.2
  "no close-time save" decision. Paging docs remain unpersisted (`_persist` skips on nil `safeXPointer`).
- **Load** only via the explicit resume picker (§7). No autoload-on-open.
- **Atomicity & crash safety:** unique-tmp → `force_flush` (**`fdatasync` — file DATA only, not the
  inode metadata**: `writeToFile(..., true)` passes `sync_metadata` nil, `util.lua:1153` →
  `C.fdatasync`, `base/ffi/util.lua:579-583`) → `os.rename` → `ffiUtil.fsyncDirectory(final)` (flush the
  rename directory entry). Durability is therefore **fdatasync (data) + fsyncDirectory (rename entry)**,
  **at parity with KOReader's own metadata writes** (`LuaSettings` writes via the same
  `writeToFile(..., true, ...)` `fdatasync` path) — **not** a full file-inode fsync; the persistent
  `.bak` (below) is the backstop for the residual metadata gap. On the **first ever** save, after
  `makePath(bookbuddy_sessions/)` we additionally `fsyncDirectory` the **parent `.sdr`** once, so the new
  subdirectory entry is durable before any file lands in it (STEAL-FAT-1 — §5.1). On **POSIX filesystems**
  (internal storage) `os.rename` over the destination is
  atomic, so power-loss leaves either the previous good `.json` or the new one — never a torn or
  zero-length file — **and Round 11 makes that claim true again**: `Session.save` tries
  `os.rename(tmp, final)` **directly** (rename-first). Round 8's unconditional
  `os.remove(final)`-before-rename ran on **all** filesystems and destroyed the atomic-replace
  guarantee on exactly the rapid-multi-turn path (a crash between remove and rename left no `final`,
  a stale-or-absent `.bak`, and a fdatasync'd `.tmp` that `load`/`list` never read — and that the
  prune sweep would eventually reap: total loss). On **FAT/exFAT** (dominant e-reader removable
  storage) a rename **over an existing destination** is not guaranteed atomic — it can be
  unlink+rename, **and some FAT drivers fail rename-over-existing with EEXIST rather than
  replacing**. So `Session.save` (§5.1, Round 11): only **when the direct rename fails** does it free
  the destination — `os.rename(final, bak)` (upgrading the `.bak` to the freshest content), else
  `os.remove(final)` — and retry; if the retry still fails after `final` was moved to `.bak`, it
  `os.rename(bak, final)` to **roll back** before erroring
  (otherwise the live `.json` is gone — renamed to `.bak` — and `list`/`readHeader` scan only `*.json`,
  so the row would vanish from the picker, recoverable only by explicit id which the picker can no longer
  offer: silent unlistable-session loss). The unlink+rename window therefore exists **only on the FAT
  fallback path** — filesystems where rename-over was never atomic anyway. There, a power-loss can
  still momentarily
  leave the destination (which every post-first save overwrites — same `<id>.json`) missing. Because A
  rewrites the **whole blob** every terminal turn, a crash in that window with **no subsequent save**
  (the e-reader hard-power-off after the reader closed the book — the real failure mode §1 names) would
  otherwise lose the **entire** conversation, not just the last turn. To bound that loss, `Session.save`
  retains a **persistent `.bak`** (Round 5; refresh corrected Round 11), mirroring KOReader's
  `LuaSettings:backup` freshness gate
  (`luasettings.lua:252-267`): before `rename(tmp → final)`, refresh the `.bak` *only* from a
  `final` the OS has likely already sync'ed — `if util.fileExists(final) then local mtime =
  lfs.attributes(final, "modification"); if not mtime or mtime < os.time()-60 then
  pcall(ffiUtil.copyFile, final, bak) end end` — a **COPY, not a rename-away** (Round 11: `final`
  must survive the refresh, or the direct rename loses its atomic-replace destination) — then
  `rename(tmp → final)`, `fsyncDirectory(final)`, and **DO NOT remove the `.bak`**.
  `Session.load` falls back to `.bak` when `final` is missing/torn (same NUL sentinel + schema gate). The
  earlier design `remove(final..".bak")`'d at the end of every save, so the `.bak` existed only for the
  ~microsecond between the two renames of one save — already gone by the hard-power-off-after-close §1
  names (arbitrarily long after the last save). The persistent `.bak`, refreshed only from a >60s-old
  final, is a copy the OS itself probably flushed, so a torn `final` from a prior interrupted save still
  has a fallback — **never losing the whole chat**, no journal required. This is now **genuinely at parity
  with KOReader's own metadata writes** (the earlier "slightly stronger" claim was FALSE — a
  microsecond-lifetime `.bak` is materially **weaker** than KOReader's persistent, 60s-gated `.old`). A
  stale `*.tmp` is ignored by `list` (`*.json` glob) and is reaped by `Session.prune` (orphaned/aged-out
  staging files, §5.1/§13); a stale `*.json.bak` is ignored by `list` (it does not end in `.json`) and is
  reaped by `Session.delete`/`prune` so persistent backups do not accumulate.
- **Worst case after a crash:** the last completed turn is the resume point. An in-flight turn was
  never saved (no mid-loop persist), so the persisted history stays resendable. (Round 11 scope:
  this holds on POSIX via the direct atomic rename-over; on the FAT fallback path the `.bak` — a
  ≥60s-old copy — bounds the loss to the turns since that copy, never the whole chat. A parked
  `ask_user` turn — see the anchor-drift note — is an in-flight turn for this purpose.)

---

## 7. Resume flow

### 7.1 UX (e-ink-tuned)

The picker rows are **title-first and sparse**: primary line `"<title_snippet>"`, right-aligned
discriminator `"<turn_count> turns · <date_time>"` where
`<date_time> = datetime.secondsToDateTime(updated, nil, true)` (an absolute, in-tree, localized
date+time formatter — `koreader/frontend/datetime.lua:296`, unambiguous across long gaps; there is **no**
`relativeDate` in-tree). **Round 7 — lead with `turn_count`, drop the page number.** The earlier design
led with `p.<page_at_save>`, but for this spec's own motivating case (asking "What happens next?" twice
in one sitting — expected usage for a chat-about-book tool) `page_at_save` is **constant within a sitting**
(the reader hasn't moved) **and reflow-dependent/display-only**, and both rows lead with the same question
text — so the rows are **non-disambiguating**, separated only by clock minutes on a low-contrast e-ink
panel. `turn_count` is already in memory (a header field, §5.1) and is the single most legible "which was
the long conversation" signal: the brief "what happens next?" probe vs the long back-and-forth read very
differently as `2 turns` vs `14 turns`. So the discriminator is **`<turn_count> turns · <date_time>`** —
turn count leads, time is the tiebreaker. **Round 5 (retained) — date+time, not date-only:**
`datetime.secondsToDate` returns the **date only** (no hour/minute — `datetime.lua:274`), so two same-day
chats need the clock time to separate them; `secondsToDateTime` adds it. The reflow-dependent
`page_at_save` is **dropped** from the row (it is still stored for the in-viewer banner and the spoiler
anchor; it just no longer earns a slot in the row). Both `turn_count` and `updated` are already-serialized
header fields (no schema impact). Newest first. Tap → resume.

**In-viewer identity (the highest-value UX addition):** the resumed `ChatViewer` title is threaded to
read **`BookBuddy — resumed · now at p.<cur>`** (or `· now at p.<cur> (spoilers reset)` when prior
consent was revoked **and the reader did not tap "Reveal everything"**, or `· now at p.<cur> (showing
everything)` on a "Reveal everything" resume — Round 10, §8.2 Step 6). This answers "which session am I in?", makes the destructive-in-place resume
legible, and gives the spoiler-boundary notice a **persistent on-screen home** instead of a toast that
flashes past on slow e-ink. **Round 6 — plus a one-shot notice for the consent reset:** because the
`"(spoilers reset)"` token rides the **end** of the title string (first to be clipped/shrunk on a narrow
e-ink viewport), a consent-revoked resume **also** raises a one-shot, tap-to-dismiss `InfoMessage`
carrying the reset text (§8.2 Step 6) — the title is the durable signal, the InfoMessage guarantees the
safety-critical consent change is seen at least once.

**Persistence requires threading ALL three title sites (Round 4 — the fix; Round 5 — via the title
STRING, not a subtitle).** The title is hardcoded `_("BookBuddy")` at **three** build sites (verified):
`_render` (`bbconversation.lua:957`), `_ensureStreamingViewer` (`:864`), and `ChatViewer.build`'s default
(`bbchatviewer.lua:55`). `_render` paints only the terminal state — the moment the reader taps **Reply**,
`_ensureStreamingViewer` rebuilds the viewer with the **plain** title and the banner would vanish
*exactly when the reader acts on the resumed chat*. So the "persistent / survives the repaint" claim only
holds if `_resume_banner` is threaded into **all three** sites (and re-applied across `updateText`).

**Round 5 — the banner rides the title STRING, not a subtitle slot.** The earlier "persistent
subtitle/line slot" design is **infeasible**: `TextViewer.build` forwards only
`title`/`title_face`/`title_multilines`/`title_shrink_font_to_fit` to its `TitleBar`
(`textviewer.lua:177-184`) and **never `subtitle`** (TitleBar supports `subtitle` —
`titlebar.lua:37` — but the only way through `TextViewer` is to patch upstream, which the plugin cannot
do). `subtitle = self._resume_banner` would silently no-op. Instead **fold the banner into the title
string** at all three sites:

```lua
title = self._resume_banner and T(_("BookBuddy — %1"), self._resume_banner) or _("BookBuddy")
```

A fresh chat (`_resume_banner == nil`) gets the plain `_("BookBuddy")` — zero change. `TitleBar`'s
`title_multilines` / `title_shrink_font_to_fit` handle narrow e-ink overflow of the longer resumed
string. This makes the spoiler-reset notice the durable on-screen signal it is described as — carried by
the title, which `TextViewer` *does* paint and *does* rebuild — not a slot that does not exist. (An
explicit `TextViewer` upstream patch is out of plugin scope; the title-string approach is the default.)

### 7.2 Picker

```lua
function BookBuddy:showResumePicker()
    local Menu = require("ui/widget/menu")
    local datetime = require("datetime")
    local sessions = Session.list(self.ui)
    if #sessions == 0 then
        UIManager:show(InfoMessage:new({ text = _("No saved chats for this book.") })); return
    end
    local items = {}
    for _, s in ipairs(sessions) do
        -- Round 6: omit the row for the session the reader is ALREADY viewing. The live conversation
        -- auto-saves to its own _session_id file every terminal turn, so it shows up in the dir scan as a
        -- normal tappable row — indistinguishable from older chats. Tapping it would restore → reanchor →
        -- consent-reset → re-render the session you are already in (or flash the §8.2b mid-turn refusal):
        -- a confusing self-inflicted state with zero benefit. Skip it (one id compare). (Alternative:
        -- keep the row, append " [current]", and make tap a no-op that just closes the picker — same goal.)
        if not (self.conversation and self.conversation._session_id == s.id) then
        -- date+time (not date-only): two same-day chats need the clock time to disambiguate, since
        -- turn_count and date may both be close within a sitting (§7.1, Round 5). secondsToDateTime(
        -- updated, nil, true): nil = inherit the reader's 12/24h setting; true = localized.
        local dateStr = datetime.secondsToDateTime(s.updated, nil, true)
        -- Round 7: lead with turn_count (already a header field, §5.1) — the single most legible "which
        -- was the long conversation" signal. The reflow-dependent, within-sitting-constant page_at_save
        -- is DROPPED from the row (it is non-disambiguating for two same-sitting chats — §7.1); time is
        -- the tiebreaker. Guard against an absent/old turn_count (default 0).
        local turns = tonumber(s.turn_count) or 0
        items[#items + 1] = {
            text = s.title_snippet ~= "" and s.title_snippet or _("(untitled chat)"),
            -- right-aligned discriminator: turn count (the "long vs short chat" signal) + date+time
            -- (the same-day tiebreaker). Disambiguates two similar opening questions asked in one sitting.
            mandatory = T(_("%1 turns · %2"), turns, dateStr),
            callback = function() self:resumeSession(s.id) end,
        }
        end -- skip-current-session guard (Round 6)
    end
    local menu = Menu:new({ title = _("Resume a chat"), item_table = items, is_borderless = true })
    UIManager:show(menu)
end
```

### 7.3 Resume

```lua
-- PREREQUISITE (Checklist 0.5): self.conversation must be wired at main.lua:166 (the conversation stored
-- on self, not just a function-local) and nulled on viewer close. Without it, the mid-turn-loss guard and
-- the close-live-after-success step below silently no-op (self.conversation is always nil) and two live
-- conversations can coexist autosaving the same file.
function BookBuddy:resumeSession(id)
    local data, err = Session.load(self.ui, id)
    if not data then
        UIManager:show(InfoMessage:new({ text = _("Could not load that chat.") })); return
    end
    -- UX/live-loss guard: Resume CLOSES the live chat without a close-time save (§5.2). Only replace a
    -- live chat that is itself at a terminal/clean state; otherwise the reader's unsaved mid-turn work
    -- would be silently lost via a deliberate UI action (not just a crash). _isResumableState() is true
    -- when the live history ends on an assistant message AND _dropDanglingTail would remove nothing
    -- (the EXACT same danglingness predicate the four save sites satisfy — incl. orphan server_tool_use,
    -- not a looser "no client tool_use" check) — a seed-only / mid-turn / orphan-tail chat returns false.
    if self.conversation and not self.conversation:_isResumableState() then
        UIManager:show(InfoMessage:new({ text = _("Finish or close the current chat first.") })); return
    end
    -- Round 11 — PURE pre-flight BEFORE any Conversation exists. Conversation.restore runs
    -- Conversation:new(), whose scratch-clear wipes the SHARED ui._bookbuddy_locators / _loc_seq /
    -- _last_search — so constructing the conv before the refusals/dialog (the pre-Round-11 order)
    -- meant a CANCELLED taint dialog or a Step 0/0.5 refusal still clobbered the LIVE chat's locator
    -- state, contradicting the "refused resume leaves the live chat fully intact" promise below.
    -- Conversation.assessResume(ui, data) is a PURE read over the loaded blob + live document
    -- (identity guard = Step 0; nil-page refusal = Step 0.5; direction = Step 1's compareXPointers
    -- classify; taint = data.spoiler_consent OR max persisted max_referenced_page > cur_page). It
    -- constructs nothing and mutates neither ui nor data. Deliberate ordering side-effect: the
    -- Step 0/0.5 refusals now run BEFORE the taint dialog, so the reader is never offered a
    -- hidden-vs-reveal choice that a position refusal then discards.
    local okp, verdict = Conversation.assessResume(self.ui, data)
    if not okp then
        UIManager:show(InfoMessage:new({ text = verdict })); return
    end
    -- Continuation: construct + re-anchor + replace, ONLY past all refusals and the consent choice.
    local function finish(reveal_all)
        local conv, rerr = Conversation.restore({ ui = self.ui, settings = self.settings }, data)
        if not conv then
            UIManager:show(InfoMessage:new({ text = _("That saved chat is damaged and can't be resumed.") }))
            logger.warn("BookBuddy: restore refused:", rerr); return
        end
        conv._reveal_all = reveal_all or false      -- session-only re-grant, set BEFORE _reanchorPosition
        -- _reanchorPosition re-runs Steps 0–0.5/1 itself (belt: the position can move while the dialog
        -- is up). A refusal HERE is late but rare, and the scratch-clear it cost belonged to the
        -- INCOMING conv — the outgoing live chat was already committed to be replaced at this point.
        local ok, reason = conv:_reanchorPosition(data)             -- §8; may refuse (Step 0.5)
        if not ok then
            UIManager:show(InfoMessage:new({ text = reason })); return
        end
        if self.conversation then self.conversation:_closeViewer() end -- replace the (clean) live chat
        self.conversation = conv
        conv:_render()                                              -- title shows resumed + boundary
    end
    -- Round 6 — "Reveal everything" escape hatch (steal C §8.G); Round 11 — the dialog now fires on
    -- the PURE verdict, before any construction. Default (Resume hidden) keeps the redaction.
    if verdict.tainted then
        local ConfirmBox = require("ui/widget/confirmbox")
        UIManager:show(ConfirmBox:new({
            text = _("This chat discussed content past your current position. Hide it (spoiler-safe), or reveal everything for this session?"),
            ok_text = _("Resume hidden"),
            ok_callback = function() finish(false) end,
            other_buttons = {{
                {
                    text = _("Reveal everything"),
                    callback = function() finish(true) end,       -- session-only re-grant
                },
            }},
            -- Cancel: NOTHING was constructed or mutated — the live chat, INCLUDING its shared
            -- locator scratch, is genuinely intact (Round 11).
        }))
        return
    end
    finish(false)
end
```

**`Conversation.assessResume(ui, data)` (NEW module function, Round 11 — the pure pre-flight).**
A **pure** read: no `Conversation:new`, no `ui._bookbuddy_*` mutation, no `data` mutation. Steps,
sharing the exact logic (not a looser re-derivation) with `_reanchorPosition`:
(1) the Step 0 **identity guard** (`util.partialMD5` compare, title+author fallback, refuse on the
`(unknown)` sentinel); (2) the Step 0.5 **nil-page refusal** — `type(currentPage(ui)) ~= "number"` →
`false, <capability-specific reason>`; (3) the Step 1 **direction classify** (pcall'd
`compareXPointers(stored_xp, live_xp)`; nil/error ⇒ backward fail-safe); (4) **taint** =
`data.spoiler_consent or (max persisted max_referenced_page > cur_page)` (the walk over
`data.messages` that pre-Round-11 lived inline in `resumeSession`). Returns
`true, { cur_page = n, is_backward = bool, tainted = bool }` or `false, reason`.
`_reanchorPosition` **retains** its own Steps 0/0.5/1 as the belt — the reader can move while the
taint dialog is open, so the authoritative classification is still made at re-anchor time;
`assessResume` exists so refusals and the consent question can be answered **without side effects**.

`_isResumableState()` returns true iff `#self.messages > 0`, the last wire message is
`role=="assistant"`, **and `_dropDanglingTail` would remove nothing** — i.e. it reuses the **exact**
`_dropDanglingTail` danglingness test rather than a simplified "no client `tool_use`" check. That test
treats a tail assistant message carrying an **orphan `server_tool_use`** (its paired
`web_search_tool_result` missing) as dangling too (`bbconversation.lua:642-645`). A simplified check
would report such a tail "resumable" and let `resumeSession` silently replace/close it — a data-loss
path that contradicts the "same predicate the four save sites satisfy" promise. Concretely:

```lua
function Conversation:_isResumableState()
    local last = self.messages[#self.messages]
    if not last or last.role ~= "assistant" then return false end
    -- Reuse the live danglingness oracle: a clean terminal turn is one _dropDanglingTail leaves intact.
    -- (Implement by sharing the predicate _dropDanglingTail uses for the tail message — client tool_use
    -- present, OR orphan server_tool_use — not by re-deriving a looser rule.)
    return not _tailIsDangling(last)   -- _tailIsDangling: the SAME test _dropDanglingTail applies
end
```

A fresh seed-only chat (`#messages > 0` but last role `user`, awaiting the first answer), a
mid-tool-round chat, or a tail assistant turn with an orphan `server_tool_use` all return false. Note
the live chat is closed **after** a successful restore + re-anchor, so a refused resume leaves the live
chat fully intact — **including its shared `ui._bookbuddy_locators`/`_loc_seq` scratch (Round 11):**
every refusal and the taint dialog now run on the pure `assessResume` verdict, before
`Conversation.restore` (whose `new()` scratch-clear is the side effect that used to fire even on a
cancelled dialog, falsifying this exact sentence).

`Conversation.restore(o, data)`:

```lua
function Conversation.restore(o, data)
    local self = Conversation:new(o)            -- clears scratch, rebuilds tool_specs + memory store
    self.messages   = data.messages or {}
    self.transcript = sanitizeTranscript(data.transcript or {})   -- coerce non-string text → "" (§7.3)
    -- C4/C-usage: a synced/edited file may carry usage as a NUMBER (e.g. 0) or null. numOr0 alone
    -- does not save us: (0).input → "attempt to index a number value". Guard the table-ness first.
    local u = type(data.usage) == "table" and data.usage or {}
    self.usage = {
        input       = numOr0(u.input),
        output      = numOr0(u.output),
        cache_read  = numOr0(u.cache_read),
        cache_write = numOr0(u.cache_write),
    }
    self._session_id      = data.id
    self._session_created = data.created
    self._title_snippet   = data.title_snippet
    self._spoiler_consent = false               -- §8 Step 3: revoke; never inherit
    -- Round 11 — TAINT HARVEST (load-bearing; closes the generation-2 rewind leak). Step 7b strips
    -- max_referenced_page from the decoded blocks before any buildBody, and new() initialized
    -- _mrp_by_tool_use_id to {}. Without harvesting here, the first post-resume save re-wrote the
    -- blob with NO annotations (mergeReferencedPages had an empty side-table) and spoiler_consent
    -- revoked — so a LATER backward resume of that file detected no taint and redacted NOTHING: the
    -- rewind-with-prior-consent leak, reopened one generation later. Copy every decoded annotation
    -- (SPOILER_SENTINEL included) into the side-table BEFORE any strip; serialize()'s merge then
    -- re-emits it on every re-save. (Harvesting an id a healer later drops is harmless — the merge
    -- skips absent tool_results.) spoiler_consent itself stays revoked — that is CONSENT, not taint;
    -- the taint scan works at generation N because the sentinel/mrp now persist.
    for _, m in ipairs(self.messages) do
        if type(m.content) == "table" then
            for _, b in ipairs(m.content) do
                local p = tonumber(b.max_referenced_page)
                if p and b.tool_use_id then self._mrp_by_tool_use_id[b.tool_use_id] = p end
            end
        end
    end
    -- Round 11 — locator high-water mark (§8.3 LEAK-4). new() cleared ui._bookbuddy_locators AND
    -- ui._bookbuddy_loc_seq; restoring the persisted mint counter (max with the live one) means a
    -- post-resume grep can never re-mint a loc:N that a stale token in the restored history already
    -- names — stale tokens hit the not-found refusal PERMANENTLY, not just until the first grep.
    if self.ui then
        self.ui._bookbuddy_loc_seq = math.max(tonumber(data.loc_seq) or 0, self.ui._bookbuddy_loc_seq or 0)
    end
    -- _dirty stays false here (new() set it; not re-touched): a resumed-but-unasked session must NOT
    -- re-write its blob (§5.2 STEAL-2), preserving its originally-saved anchor.xpointer for a later
    -- backward-drift classification. The first ask()/_storeAssistant flips it true.
    -- C1/§9.6: re-assert the SAVED config posture for this resumed session's lifetime, in BOTH
    -- directions (thinking ON→OFF and OFF→ON). new() already rebuilt tool_specs from the CURRENT
    -- config; set the per-conversation overrides from the fingerprint, then re-derive tool_specs so
    -- web_search/memory tools match the saved posture (otherwise the resent history's thinking blocks /
    -- web_search pairs disagree with body.thinking / body.tools → guaranteed 400 every turn).
    -- NOTE: model is NOT enforced (§9.6/§16) — a deprovisioned saved model would 400 every resumed turn
    -- with no escape. The overlay touches ONLY enable_thinking/enable_web_search/enable_memory; the
    -- session runs against the reader's LIVE model. (model stays in the fingerprint for display only.)
    local fp = type(data.config_fingerprint) == "table" and data.config_fingerprint or nil
    if not fp then
        -- Round 11 — ABSENT-FINGERPRINT FALLBACK (hand-edited / foreign / pre-fingerprint blob).
        -- Running such a history under the LIVE config reproduces the exact §9.6 thinking-400 the
        -- fingerprint exists to prevent. The thinking posture is INFERABLE from the history itself:
        -- any thinking block present ⇒ it was built thinking-ON; none ⇒ OFF. Infer it, log it, and
        -- pin only that toggle (web_search/memory follow the live config for these blobs — an
        -- honestly-scoped residual, §9.6: resent web-search pairs are wire-legal either way; only
        -- thinking has the hard body.thinking↔blocks consistency requirement).
        local has_thinking = false
        for _, m in ipairs(self.messages) do
            if m.role == "assistant" and type(m.content) == "table" then
                for _, b in ipairs(m.content) do
                    if b.type == "thinking" then has_thinking = true break end
                end
            end
            if has_thinking then break end
        end
        self._thinking_override = has_thinking
        logger.info("BookBuddy: no config_fingerprint in saved chat; inferred enable_thinking =", has_thinking)
        self:_rebuildToolSpecs()                -- re-derive from _effectiveConfig() (§9.6)
    end
    if fp then
        self._thinking_override   = fp.enable_thinking
        self._web_search_override = fp.enable_web_search
        self._memory_override     = fp.enable_memory
        self:_rebuildToolSpecs()                -- re-derive from _effectiveConfig() (§9.6)
        -- §9.6/C12: if the effective posture re-enables memory but new() skipped store construction
        -- (live config had memory off), the resent memory calls would have a spec but NO backing store.
        -- Rebuild the per-book .sdr memory store exactly as new() does (bbconversation.lua:203-208):
        -- Memory.new(Memory.baseDirForBook(ui)), guarded on a resolvable base.
        if self:_effectiveConfig().enable_memory and not self.memory then
            local Memory = require("bbmemory")
            local base = Memory.baseDirForBook(self.ui)
            if base then self.memory = Memory.new(base) end   -- per-book .sdr sidecar; no global store
        end
    end
    -- Round-3/§9.2: load-side input normalization belt. A foreign/older/hand-edited writer (or a JSON
    -- encoder whose object sentinel didn't survive) can deliver tool_use/server_tool_use input as a bare
    -- {} that real rapidjson re-encodes as [] → 400. serialize()'s coerce only protects what A wrote;
    -- this normalizes blobs A did NOT write. Runs BEFORE pairing/tail-drop.
    _normalizeToolInputs(self.messages)
    -- C8: pair FIRST (heal orphan server_tool_use), THEN drop dangling tail once.
    -- Round-4: in the SAME pass also heal the REVERSE-orphan case. pairDanglingWebSearch
    -- (bbconversation.lua:73-96) heals ONLY the forward orphan (a server_tool_use missing its
    -- web_search_tool_result → append a synthetic error). It does NOT drop a reverse-orphan
    -- web_search_tool_result whose server_tool_use id is ABSENT in the same array — a Syncthing-merged or
    -- hand-edited file can carry such a mid-history block; it passes restore's leading/interior/tail
    -- checks but 400s validateMessages on the first buildBody. Approach C's bbwire.healWebSearch handles
    -- both directions; A only ran the forward healer. So after pairing, drop any web_search_tool_result
    -- block whose tool_use_id has no matching server_tool_use id in the SAME assistant message's content.
    -- No schema change, no journal.
    for _, m in ipairs(self.messages) do
        if m.role == "assistant" and type(m.content) == "table" then
            pairDanglingWebSearch(m.content)            -- forward orphan → append synthetic error
            -- reverse orphan: collect server_tool_use ids present in THIS message, then drop any
            -- web_search_tool_result whose tool_use_id is not among them.
            local server_ids = {}
            for _, b in ipairs(m.content) do
                if b.type == "server_tool_use" and b.id then server_ids[b.id] = true end
            end
            for i = #m.content, 1, -1 do               -- reverse so removals don't skip blocks
                local b = m.content[i]
                if b.type == "web_search_tool_result" and not server_ids[b.tool_use_id] then
                    table.remove(m.content, i)
                end
            end
            -- Round-5/§7.3: the reverse-orphan removal above can reduce an assistant message's content to
            -- {} (e.g. a synced/hand-edited message that was only a reverse-orphan web_search_tool_result).
            -- _dropDanglingTail (bbconversation.lua:625-647) marks a tail assistant dangling ONLY if it
            -- carries a tool_use or orphan server_tool_use — an empty-content assistant is NEITHER, so it
            -- SURVIVES; the leading/interior/tail checks also pass it; validateMessages (sse.lua) does not
            -- check empty content; and the live empty-content 400 guard (bbconversation.lua:506-516) never
            -- runs for an interior restored message. So an emptied assistant would re-introduce, on the
            -- RESTORE side (no placeholder guard), the empty-content 400 the §9.1 serialize-side fix
            -- prevents. Placeholder it, mirroring bbconversation.lua:512.
            -- Round-6 — BELT-ONLY, not enabling: the placeholder produces a {type="text",text="(no
            -- response)"} assistant. If the emptied message is ADJACENT to another assistant message (the
            -- reverse-orphan was an interior turn between two assistant turns), the placeholdered message is
            -- still an assistant next to an assistant → the interior-alternation check below REFUSES the
            -- file regardless. The placeholder only RESCUES the case where the emptied assistant is NOT
            -- adjacent to another assistant (effectively the tail, or surrounded by user messages). So this
            -- step prevents an empty-content 400 for the non-adjacent case; it does NOT make an
            -- adjacent-assistant file restorable (those are refused, by design — interior alternation is not
            -- self-healed, §9.3/§11).
            if #m.content == 0 then
                m.content[1] = { type = "text", text = "(no response)" }
            end
        end
    end
    self:_dropDanglingTail()                    -- _clean_transcript_len is nil → _trimTranscript no-ops
    -- Round-4/§7.3/§9.1: resync the transcript UNCONDITIONALLY (not only when restore's OWN drop shrank
    -- messages). A serialize-side rollback (dropSignaturelessThinking rolling back a trailing tool round,
    -- §9.1) delivers a file with already-short messages + a LONGER persisted transcript: n_before equals
    -- #messages here, so a "shrank?" conditional would SKIP the sync and _render would show turns no
    -- longer in the resendable history (the §14 deep-equal baseline can't catch it — both sides carry the
    -- same long transcript + short messages). _syncTranscriptToMessages trims self.transcript back to the
    -- surviving last-assistant turn; it is a no-op when transcript already matches, so running it always
    -- is the single robust guard covering BOTH restore-side tail-drops AND serialize-side rollbacks.
    self:_syncTranscriptToMessages()            -- trim transcript back to the surviving last assistant turn (steal B)
    -- Round-3/§3.1: if tail-heal emptied messages (e.g. a session whose only assistant content was an
    -- orphan server_tool_use), the next ask() takes the SEED branch and re-seeds at the live position.
    -- Restore selected_text/note from data.seed so the re-seed carries the ORIGINAL highlight instead
    -- of silently dropping it. Round 11: rehydrate UNCONDITIONALLY (not only on the empty-history
    -- path) — serialize() emits `seed` from self.selected_text/self.note, so a resumed session that
    -- left them nil dropped the field on its first re-save (generation-2 decay of the re-seed
    -- backstop). ask() CONSUMES them only on its seed branch (#messages == 0), so rehydrating on a
    -- non-empty history changes no behavior beyond carrying the field forward.
    if type(data.seed) == "table" then
        self.selected_text = data.seed.selected_text
        self.note          = data.seed.note
    end
    -- C-firstmsg: tail-heal repairs only the TAIL. A corrupt/synced file that lost the user seed can
    -- leave a LEADING assistant message → validateMessages first-message-must-be-user fails on the
    -- next buildBody. Interior consecutive same-role messages (Syncthing merge / duplicated turn) are
    -- ALSO not self-healed. Neither self-healer touches these, so refuse such files here.
    if #self.messages > 0 and self.messages[1].role ~= "user" then
        return nil, "unrestorable: leading non-user message"
    end
    for i = 2, #self.messages do
        if self.messages[i].role == self.messages[i - 1].role then
            return nil, "unrestorable: interior alternation broken"
        end
    end
    return self
end
```

**`_normalizeToolInputs(messages)` (load-side belt, ~10 lines, §9.2).** For every `tool_use` /
`server_tool_use` block whose `input` is `nil` or an empty table, set `input = rapidjson.object({})`
(the empty-object **sentinel**, not bare `{}`). This makes the "never 400 on resend" guarantee hold for
**foreign-written** blobs at load time — `serialize()`'s `coerceToolUseInput` (§9.1) is the serialize-side
parallel that, **as of Round 10, matches this same "nil OR empty table" predicate** (so a re-save whose
`deepCopy` stripped the object sentinel down to a bare `{}` is re-coerced rather than re-encoded as `[]`).
Runs in `restore` **after decode, before**
`pairDanglingWebSearch` / `_dropDanglingTail`.

**`_syncTranscriptToMessages()` (transcript desync fix, stolen from B, §7.3).** `restore` calls
`_dropDanglingTail()` but `_clean_transcript_len` is `nil`, so the embedded `_trimTranscript` no-ops —
leaving the displayed transcript **longer** than the resendable history whenever tail-drop actually
removed wire messages. `restore` therefore calls `_syncTranscriptToMessages()` **unconditionally** after
pair-then-drop, trimming `self.transcript` back to the surviving last assistant turn (and no-op when the
two already match). **Round-4: the call is unconditional — not gated on restore's own drop having shrunk
`messages`.** This is the single robust guard for **two** desync sources: (1) restore-side
`_dropDanglingTail` removing a Syncthing-merged dangling tail, AND (2) a **serialize-side rollback**
(`dropSignaturelessThinking` rolling back a trailing tool round, §9.1) that persisted an already-short
`messages[]` next to a still-long transcript — for which `#messages` did **not** shrink in `restore`, so
a "shrank?" conditional would skip the sync and `_render` would show a turn no longer in the resendable
history (a desync the §14 deep-equal baseline cannot detect — both sides carry the same long transcript +
short messages). Pure in-memory.

**Algorithm (Round 11 — pinned; the helper was previously contract-only, and the mapping is the
part that desyncs).** Walk `self.transcript` in order, maintaining a **wire cursor** `w` over
`self.messages`:
- a **`user`** transcript entry (always a reader question — interior `tool_result` wire messages
  never produce a `user` transcript entry) advances `w` to the next wire **user** message **whose
  content carries no `tool_result` block** (the turn opener; skip tool-round user messages);
- **`assistant` / `tool` / `thinking`** entries all belong to the assistant turn opened by the most
  recent `user` entry — i.e. to the wire messages between that turn opener and the next turn opener.
  A **pause-extended** wire assistant message (one logical message, content extended in place —
  §9.4) maps to **multiple** assistant/tool transcript lines; they all belong to that same turn, so
  the cursor does not advance per line.
Truncate `self.transcript` at the **first entry whose owning turn-opener index exceeds
`#self.messages`** (equivalently: whose turn has no surviving wire messages). **Invariant restored:**
every remaining transcript entry's owning turn survives in the resendable `messages[]` — `_render`
never shows a turn `buildBody` would not resend. No-op when the histories already correspond.

`restore` returns `nil, reason` for an unrestorable file; `resumeSession` surfaces the reason and
keeps the live chat. Because `#self.messages > 0` after a successful restore, the next `ask(followup)`
appends a plain user message (not a re-seed), and `buildBody` resends the full restored history.

**`sanitizeTranscript` contract (restore-time hardening for the `:825` nil-concat).** For **every**
transcript entry: if `role` is `"user"`, `"assistant"`, or `"tool"` (or any role other than
`"thinking"`), coerce a missing or non-string `text` to `""` — **do not drop the field**. A
`"thinking"` entry keeps only `done:bool` and needs no `text`. **Preserve `_tool_use_id` on `tool`
entries** (it survives the round-trip so the rewind transcript scrub — §8.2 Step 7 — can still key on
it after restore). This closes a real crash: `_transcriptText`'s
else-branch does `out[#out+1] = turn.text` with **no nil-guard** (`bbconversation.lua:825`), then
`table.concat` at `:832` — so a restored or Syncthing-merged transcript carrying a `tool`-role (or any
non-user/assistant/thinking) entry with `text == nil`/non-string would throw "attempt to concatenate a
nil value" on the first `_render` after resume. `sse.validateMessages` does **not** cover transcript
shape, so only this coercion catches it.

**Defense-in-depth at `:825`.** Additionally harden the `_transcriptText` else-branch to
`out[#out+1] = tostring(turn.text or "")` so a stray entry that bypasses `sanitizeTranscript` (e.g. a
future code path that appends to `self.transcript` directly) cannot crash the render either.

**`max_referenced_page` is intentionally NOT stripped in `restore` — but it IS harvested there.**
Step 7's rewind redaction
(§8.2) must read the field, and `_reanchorPosition` runs *after* `restore` on every resume. So the
**unconditional** strip (the always-on guard that removes this non-wire field so a forward/same resume
does not 400 on the first `buildBody`) lives at the **close of `_reanchorPosition`** (Step 7b),
after the rewind redaction and before any `buildBody`. `restore` leaves the field on the blocks; the
strip is guaranteed because `_reanchorPosition` is mandatory on every resume (§7.3 `resumeSession`).
**Round 11:** before the strip can ever run, `restore` has already **harvested** every decoded
annotation into `self._mrp_by_tool_use_id` (see the taint-harvest block above), so stripping the
wire field no longer destroys the persistence channel — `serialize()`'s merge re-emits the
annotations on every re-save and the taint survives across generations.

---

## 8. SPOILER-SAFETY ON RESUME — airtight

This is mandatory and is the hard problem for persistence. Verified facts it rests on:

- The live gate in `grep`/`read` reads `currentPage(ui)` **fresh per call** (`bbtools.lua:199`, and
  the read path) and is **not** threaded with any seed/session position. **The gate already floats
  with the reader.**
- `max_page` **only tightens**, never widens past the current page (`bbtools.lua:196-211`). ⇒ A
  stale `max_page` from history can only **over-block** (forward move), never leak.
- `spoiler=true` **removes the cap entirely** (`bbtools.lua:201`, read path mirror). ⇒ This is the
  **only** in-history token that can cause a true leak after a rewind.
- `currentPage` for EPUBs is reflow-dependent; `getXPointer()` is device-stable
  (`credocument.lua:884`), and `compareXPointers` is the gate's own ordering oracle
  (`bbtools.lua:465-466` comment; uses at `:480/:494/:505`: `1` = second arg after first; upstream
  contract `credocument.lua:750-752`: `1` if xp2 after xp1, `-1` if not, `0` if same, **`nil` if
  either xpointer is invalid**). ⇒ The anchor must be an **xpointer**, and
  move **direction** must be decided by `compareXPointers`, not a page-int compare.

### 8.1 The threat, precisely

A session frozen at one position is resumed at another (reader advanced, rewound, or resumed on a
second device with a different font). Three independent hazards:

1. **Forward move → over-block** (common, *annoying not unsafe*): persisted `max_page=<old>` and
   prior `book_context` tool_results keep the model hiding content the reader has since read.
2. **Rewind + prior spoiler consent → LEAK** (*unsafe*): if the model ever ran a tool with
   `spoiler=true`, that posture lives in-context; after a rewind it can re-reveal content now ahead
   of the lower live position.
3. **Cross-device / reflow → wrong boundary** (*unsafe/misleading*): a page integer means different
   things on two devices; comparing `saved_page` to `cur` compares incommensurable units.

### 8.2 The hardened resolution — `Conversation:_reanchorPosition(data)`

Fail-closed, xpointer-anchored, posture-revoking. Returns `ok, reason_or_nil`.

**Step 0 — Identity guard (DRIFT-2).** Compute live `ident = util.partialMD5(ui.document.file)`. If
`data.book.ident` and live `ident` are **both present and differ → refuse**
(`_("This saved chat is for a different book.")`). If either is missing, fall back to title+author
equality, **but refuse when the live title is the `(unknown)` sentinel** (so two metadata-less books
can't pass). Never treat absent metadata as a match.

**Step 0.5 — Fail closed on an unresolvable live position (LEAK-0, load-bearing).** The entire §8
spoiler argument rests on the floating gate, but the gate is **wide open by design when
`currentPage(ui)` returns nil**: the start-page refusal is gated on `cur` truthy
(`bbtools.lua:369`, `if start_page and cur ...`) and the forward clamp is `if cur then`
(`bbtools.lua:381`) — a nil live page **bypasses BOTH**, giving unclamped reads end-to-end. Compute
`cur_page = currentPage(ui)` **first**; if `type(cur_page) ~= "number"`, **refuse the resume**:

```lua
local cur_page = currentPage(ui)
if type(cur_page) ~= "number" then
    -- Distinguish the two nil causes. A PAGING doc (PDF/CBZ) has no getXPointer capability AT ALL —
    -- the reader cannot fix it by turning a page, so say so honestly. (In practice such a doc was never
    -- persisted: _persist skips when safeXPointer is nil — §5.2 — so this is the belt for a synced-in
    -- blob.) A cre doc with a transient nil position CAN be fixed by opening to a page.
    if not (ui.document and ui.document.getXPointer) then
        return false, _("This book type can't be resumed spoiler-safely.")
    end
    return false, _("Reading position unavailable — open the book to a page, then resume again.")
end
-- Capture the LIVE total alongside cur_page: both the Step 2 seed re-anchor and the Step 7 seed
-- surgery rewrite the "Current page: <cur> of <total>" boundary line, so `total` must be a bound
-- local. A bare `total` resolves to the global nil and bakes "of nil" into the resent wire history;
-- Step 2's post-condition only checks the "Current page: <cur_page>" prefix, so a malformed "of nil"
-- boundary would pass silently. Prefer the LIVE page count -- per §3.1/§3.3 the stored
-- `total_at_save` is display-only and reflow/device-dependent -- with `data.anchor.total_at_save`
-- (then "?") as a documented fallback only when the live count is unavailable.
local total = (ui.document and ui.document.getPageCount and ui.document:getPageCount())
    or (data.anchor and data.anchor.total_at_save)
    or "?"
```

Do **not** arm the marker and do **not** proceed to restore. (`resumeSession` already surfaces
`reason` on `ok == false`.) This also prevents the Step 4 marker from emitting literal
`page nil` / `max_page=nil` text. Every later step may now assume `cur_page` is a number, and `total`
is a bound local (the live `getPageCount()`, with `data.anchor.total_at_save` as a documented
fallback) that Step 2 and Step 7 reference when rewriting the `"Current page: <cur> of <total>"` line.

**Step 1 — Resolve the anchor on *this* device (DRIFT-3), via the gate's own oracle.** `currentPage`
is reflow-dependent, so a page-integer compare reintroduces the layout-dependence the design avoids:
it spuriously fires on a font/margin change and misses a same-reflowed-page backward move. The read
gate's own oracle is `compareXPointers` (`bbtools.lua:391, 406`: `1` means the second arg is **after**
the first). Resolve the live xpointer and compare against the stored one — **all inside a `pcall`**, so
a malformed stored xpointer degrades to the fail-safe branch rather than crashing `resumeSession`
(which has no `pcall` around `_reanchorPosition`):

```lua
local function classify()
    local live_xp = ui.document.getXPointer and ui.document:getXPointer()
    local stored_xp = data.anchor and data.anchor.xpointer
    if not (live_xp and stored_xp and ui.document.compareXPointers) then
        return "backward"  -- fail-safe: missing oracle ⇒ treat as the unsafe (rewind) direction
    end
    local cmp = ui.document:compareXPointers(stored_xp, live_xp)  -- 1 ⇒ live AFTER stored; 0 ⇒ EQUAL position
    -- cmp==1 (live moved forward) AND cmp==0 (same position — same device, no movement: the COMMON
    -- resume case) are BOTH the safe/forward branch. Only cmp<0 (live BEFORE stored) is a genuine
    -- rewind. Equal position is provably not a rewind, so it must NOT trip the Step 5 passage-gate or
    -- the "(spoilers reset)" banner (reconciles with §8.3 "On forward/same moves nothing is redacted").
    -- Round 11 — the NIL return is named, not just implied: compareXPointers returns NIL when either
    -- xpointer is INVALID (a synced/hand-edited anchor, a DOM change that dropped the node —
    -- credocument.lua:750-752 "Returns nil if any of XPointers are invalid"). nil is neither 1 nor 0,
    -- so the expression below classifies it "backward" — the fail-safe branch, BY DESIGN (an
    -- unverifiable anchor gets the strictest gating; same posture as the missing-oracle and pcall
    -- fail-safes around this function).
    return (cmp == 1 or cmp == 0) and "forward" or "backward"     -- <0 OR nil (invalid) ⇒ backward
end
local ok_cmp, direction = pcall(classify)
if not ok_cmp then direction = "backward" end                    -- compareXPointers errored ⇒ fail-safe
local is_backward = (direction == "backward")
```

`is_backward` drives the rewind-only steps (5 and 7). `cur_page` is used **only** for the marker
boundary number and the UX banner — never as the move-detection oracle. The stored `page_at_save` is
**never** used. (For non-cre docs with no xpointer the oracle is absent ⇒ fail-safe `backward` ⇒ the
strictest gating; the Step 4 marker still anchors on the live `cur_page`.)

**Step 2 — Re-anchor the seed (handle TABLE content; C1).** `messages[1].content` is a **block
array** after the first `buildBody`. Locate the single `{type="text"}` block whose text contains
`"<book_context>"` and rewrite *that block's text*. **Build the replacement deterministically from the
`cur_page` captured in Step 0.5**, not by re-running the tool: `tool_book_context` re-reads
`currentPage(ui)` independently (`bbtools.lua:464`), so on a live device where the reader's position
moves between Step 0.5 and Step 2 (queued gesture, mid-turn) a freshly executed `book_context` would
disagree with the captured `cur_page` and spuriously fail the post-condition, silently dropping the
belt to the Step 4 marker more often than the spec implies. Instead, do **string surgery from the
captured value** — rewrite the `"Current page: %s of %s"` line (`bbtools.lua:545`) to
`"Current page: " .. tostring(cur_page) .. " of " .. tostring(total)` (both `cur_page` **and**
`total` are the bound locals captured in **Step 0.5** — `total` from the live
`getPageCount()`, never a bare unassigned name that would emit `"of nil"`).
**Round 11 — the surgery MUST be span-bounded.** The seed is **ONE text block holding ALL tags**:
`ask()` concatenates `<book_context>` + `<highlighted_passage>` + `<reader_note>` + `<question>`
into a single string (`bbconversation.lua:340-360`) and `buildBody` coerces that string to **one**
`{type="text"}` block (`bbanthropic.lua:84-89`) — the earlier "never on the untrusted
`<highlighted_passage>` block" framing wrongly assumed separate blocks. A whole-block
`gsub("Current page:[^\n]*", …)` therefore runs over the **untrusted passage/note text too** — a
passage containing a literal `"Current page:"`/`"Current chapter:"` line would be silently mutilated
(and a `%` in a gsub replacement corrupts the substitution). So: locate the plugin-generated span
with **plain `find`** — `s = text:find("<book_context>", 1, true)`,
`e = text:find("</book_context>", 1, true)` — run the line rewrite on `text:sub(s, e - 1)` **only**,
and splice via `string.sub` + concat. Patterns never touch a byte outside the
`<book_context>…</book_context>` span, so the surgery provably cannot reach the untrusted text that
shares the block.
**Post-condition (DRIFT-1, fail-closed):** after the rewrite, assert the new block text contains
`"Current page: " .. tostring(cur_page)`. Because the replacement is built from the captured
`cur_page` (not a re-run tool), this post-condition is now self-consistent and only fails when the
**seed shape is genuinely unexpected** (tag absent, hand-edited file) — never from mid-turn movement.
On a genuine failure, **do not silently keep the stale boundary** — proceed to Step 4's authoritative
marker (which does not depend on string surgery) and treat posture as untrusted (Step 3 runs
regardless).

**Step 3 — Revoke prior spoiler consent across the boundary (LEAK-2, load-bearing).** Regardless of
`data.spoiler_consent`, set `self._spoiler_consent = false` (already done in `restore`). The danger
is the model *continuing* to pass `spoiler=true` out of habit; the authoritative marker (Step 4)
explicitly instructs that spoiler mode is OFF and prior consent does not carry over. If
`data.spoiler_consent` was `true`, **set `self._resume_consent_reset = true`** (Round 6 — the factual
"prior consent was revoked at this boundary" flag). It drives both the title-tail `"(spoilers reset)"`
note **and** the Step-6 one-shot `InfoMessage`, so the viewer title and a tap-to-dismiss notice both
note "spoiler mode reset — ask again to re-enable," making the revocation visible and requiring fresh,
explicit opt-in. *This converts silent inheritance into explicit re-consent.* **Round 10 caveat:** both
UX surfaces gate on `self._resume_consent_reset and not self._reveal_all` — a reader who taps "Reveal
everything" also had `data.spoiler_consent == true` (so this flag is set), but they explicitly opted to
KEEP the later-book discussion, so the `"(spoilers reset)"` tail and the popup are suppressed and the
reveal path shows its own `" (showing everything)"` banner instead (Step 6). The wire-level revocation
in Step 4 is independent of `_reveal_all`: `_reveal_all` controls **redaction**, and even on a reveal-all
resume the model still must not auto-pass `spoiler=true` without a fresh ask — only the on-screen
*messaging* about a "reset" is suppressed.

**Step 4 — Inject an authoritative, most-recent marker (LEAK-2 fix; replaces editing a buried
seed).** Arm `self._resume_note` so the next `ask()` prefixes the next user turn with the single
highest-salience anchor the model sees:

```
<resume_context>
You are resuming a saved conversation. Ignore any earlier "Current page" values AND any earlier
"Current chapter" title in this chat; they are stale and the chapter title may itself be from
ahead of the reader. The reader is now at page <cur_page> of <total>. Treat page <cur_page>
as the current spoiler boundary. Spoiler mode is OFF regardless of any earlier request to
reveal spoilers; do not pass spoiler=true unless the reader asks again now. When you search,
pass max_page=<cur_page>.
</resume_context>
```

**Strip any prior `<resume_context>` block before arming a fresh one (compounding-marker fix;
Round 11 — scan ALL user messages, not just the last).** The
marker rides the next user turn and then stays **baked into history** as a permanent user block. On a
**second** resume, naively arming a new marker leaves history carrying **two stacked
`<resume_context>` blocks with conflicting "current page" numbers** — the exact "ignore earlier Current
page values" hazard this design warns about, now self-inflicted and compounding per resume. The prior
marker rides the **first** user turn asked after the previous resume — so once the reader has asked
two or more questions since, it sits **several user messages back**, and a last-message-only scan
(the pre-Round-11 rule) misses it, re-stacking the exact conflict this fix claims closed. Before
arming `self._resume_note`, therefore, **scan EVERY user message's content for any prior
`<resume_context>…</resume_context>` block and remove it** (locate the span with plain `find` on the
plugin-generated tags, splice via `string.sub` — same span-bounded discipline as the Step 2/Step 7
seed surgery) so at
most one marker — the newest — ever exists in history. (The marker text itself is plugin-generated, so
this surgery is on known spans, never on untrusted passage text.)

Because it is the most-recent turn, it overrides the stale `max_page=<old>` habit in **both**
directions — fixing forward over-block (FALSE-BLOCK-1) **and** the rewind leak — and it does not
depend on the fragile seed rewrite landing. Step 2 is belt; this marker is suspenders.

**Rewind redaction is gated on `not self._reveal_all` (Round 6 — the escape hatch).** All of the
rewind-only steps below (Step 5 passage-gate clause, Step 5b memory-quarantine clause, Step 5c
web-search-quarantine clause, **and Step 7's wire + transcript redaction — including the seed
`book_context` surgery and the foreign-blob `book_context` fail-safe, which Round 10 brought under the
same gate**) run only when `is_backward and not self._reveal_all`. `resumeSession`'s "Reveal everything" button (§7.3) sets
`self._reveal_all = true` **before** `_reanchorPosition` runs, a **session-only** re-grant for a reader
who deliberately re-read earlier and wants the later-book discussion back. When `_reveal_all` is true,
the resume behaves like a forward/same resume for redaction purposes (nothing hidden); Step 0.5, Step 1
classification, Step 2/4 re-anchoring, and Step 7b's unconditional `max_referenced_page` strip still run
(the strip is wire-hygiene, not spoiler redaction, and must always remove the non-wire field). Default
(no button / "Resume hidden") leaves `_reveal_all` false and the redaction applies as written.

**Step 5 — Gate the frozen highlighted passage on rewind (LEAK-3).** The seed's
`<highlighted_passage>` is text from `~saved_page`. On a **rewind** (`is_backward` from Step 1's
`compareXPointers` oracle) **and `not self._reveal_all`** (Round 6), it may now be *ahead* of the live
boundary. Only in that case, append to the marker:

```
An earlier highlighted passage in this chat may be from ahead of your current position; do not
quote or discuss it beyond page <cur_page> unless asked.
```

We do not delete the seed passage (immutable history) — we instruct the model to treat it as gated.

**Step 5b — Quarantine the memory-recall channel on EVERY memory-enabled resume (LEAK-6, cross-B/C).**
`restore` rebuilds the bbmemory store from the **live** book dir, and the MEMORY_PROTOCOL mandates a
start-of-conversation memory view — so a session that progressed to a later chapter pulls later-page
plot notes straight into context. Step 7 redacts only `tool_result.content` in `self.messages`; it
**never touches the memory store** (no schema/store change is made here). So for memory-enabled books
the redaction alone is not airtight — the marker is the only guard. **The memory channel is keyed to
the book, not the session position**, and the start-of-conversation memory view is injected on **every**
resume regardless of move direction. A session saved at p.142 with notes about p.500 events, resumed
after the reader *advanced* to p.200 (a **forward** move → Steps 5/5c/7 arm nothing), still pulls the
p.500 notes into context with zero guard. So the `is_backward` gate is wrong for the memory channel:
the page bound `cur_page` (not the move direction) is what makes a recalled note safe. Arm this clause
whenever `self:_effectiveConfig().enable_memory` is true (independent of `is_backward`, modulo the
existing `not self._reveal_all` override). Append to the marker:

```
Some saved memory notes may describe events past page <cur_page>. Treat any recalled memory note
about events beyond page <cur_page> as spoiler-quarantined: do not reveal or rely on it unless the
reader has reached that point or explicitly asks about it now.
```

This rides the same `_resume_note` and is omitted entirely when memory is off (no false clause).
(Steps 5/5c/7 stay backward-only; only this memory clause is decoupled from `is_backward`.)

**Step 5c — Quarantine the web-search channel on rewind (LEAK-7, Round 4).** Step 7 now redacts every
`web_search_tool_result` block's content on a rewind (the enforced backstop), but a marker clause is the
belt — and it also covers the model's *habit* of re-asserting a known web-search finding. When
`is_backward`, append to the marker:

```
Any earlier web-search results in this chat may describe events past page <cur_page>; treat them as
spoiler-quarantined and do not reveal or rely on them unless the reader has reached that point or asks
for a fresh search now.
```

This rides the same `_resume_note` and is omitted on forward/same resumes.

**Step 6 — Surface the boundary persistently (UX) and mark the session resumed.** Set
`self._resume_banner = T(_("resumed · now at p.%1"), cur_page)`, then append a posture tail (**Round 10 —
the tail must agree with the reader's actual choice**):
- append `" (spoilers reset)"` when **`self._resume_consent_reset and not self._reveal_all`** — i.e.
  consent was revoked (Step 3) **and** the reader did NOT tap "Reveal everything." (Gating on
  `_resume_consent_reset` alone is wrong: a reader who tapped "Reveal everything" still had
  `data.spoiler_consent == true`, so Step 3 set `_resume_consent_reset = true`, yet they explicitly
  opted to KEEP the later-book discussion — a `"(spoilers reset)"` tail would assert the exact opposite
  of the choice they made one tap earlier.)
- append **`" (showing everything)"`** when `self._reveal_all` is true — the reveal path's own honest
  banner token, so the title says `"resumed · now at p.<cur> (showing everything)"` instead of falsely
  claiming spoilers were reset. **Round-4/Round-5: this must be
threaded into ALL three viewer build sites** —
`_render` (`bbconversation.lua:957`), `_ensureStreamingViewer` (`:864`), and `ChatViewer.build`'s default
(`bbchatviewer.lua:55`) — via the **title STRING**, **not** a subtitle slot and **not** only `_render`:

```lua
title = self._resume_banner and T(_("BookBuddy — %1"), self._resume_banner) or _("BookBuddy")
```

**Round 5 — a subtitle slot is infeasible:** `TextViewer.build` forwards only
`title`/`title_face`/`title_multilines`/`title_shrink_font_to_fit` to its `TitleBar`
(`textviewer.lua:177-184`) and **never `subtitle`**, so the earlier "persistent subtitle slot" would
silently no-op and the banner would never paint. Folding the banner into the title is what makes it
survive: otherwise the first **Reply** tap rebuilds the viewer through `_ensureStreamingViewer` with the
plain `_("BookBuddy")` title and the safety-critical notice vanishes exactly when the reader acts on the
resumed chat. The notice lives in the title, which `TextViewer` does paint and does rebuild; `TitleBar`'s
`title_multilines` / `title_shrink_font_to_fit` handle narrow e-ink overflow. Also set
`self._resumed = true` here, so the §8.2b per-turn nil-page guard in `_loop` is armed for every later
turn of this resumed session (not just the Step 0.5 entry check). (The wire marker — Step 4 — remains the
**durable safety channel**; the title banner is the on-screen signal.)

**Round 6 — also raise a one-shot, tap-to-dismiss `InfoMessage` on a CONSENT-REVOKED resume (the title
tail clips first).** The spoiler-reset notice is folded into the title **string**
(`"BookBuddy — resumed · now at p.142 (spoilers reset)"`), which puts the safety-critical
`"(spoilers reset)"` token at the **END** of the longest string on the narrowest e-ink viewport —
exactly what `title_multilines` / `title_shrink_font_to_fit` clip or shrink first. The §14 banner test
asserts only the title **string content**, not its visible rendering, so it gives **false confidence**
that a token that may be off-screen is "shown." Since this notice is the only on-screen home for a
consent change the reader did **not** explicitly tap for, on the **first** resumed render of a
**consent-revoked** resume (`data.spoiler_consent` was true) **that is NOT a "Reveal everything" resume**
(Round 10 — `not self._reveal_all`; the reveal path is a deliberate tap to KEEP spoilers, so a
"spoiler mode was reset" popup would contradict it), **additionally** show a one-shot,
tap-to-dismiss `InfoMessage` carrying the reset text (using the already-imported `InfoMessage` widget —
the picker/resume path already requires it):

```lua
-- Step 6, consent-revoked first render only. self._resume_consent_reset is set in Step 3 when
-- data.spoiler_consent was true; guard a _resume_notice_shown one-shot so a later _render does not re-toast.
-- Round 10: ALSO gate on `not self._reveal_all` -- a reader who tapped "Reveal everything" still had
-- data.spoiler_consent == true (so _resume_consent_reset is set), but they explicitly KEPT spoilers; a
-- popup asserting "spoiler mode was reset" would contradict the choice they just made.
if self._resume_consent_reset and not self._reveal_all and not self._resume_notice_shown then
    self._resume_notice_shown = true
    UIManager:show(InfoMessage:new({
        text = T(_("Spoiler mode was reset — you moved back to page %1. Ask again to re-enable spoilers."), cur_page),
    }))
end
```

This is **in addition** to the title banner (which remains the persistent signal), and fires only when
consent was actually revoked **and the reader did not tap "Reveal everything"** — a forward/same resume
with no prior consent, **and a "Reveal everything" resume**, both show nothing extra. A §14
assertion verifies the `InfoMessage` was shown with the reset text on a consent-revoked resume (and is
**not** shown on a "Reveal everything" resume).

**Step 7 — Redact future-page payload already in history on a rewind (LEAK-5, the real backstop).**
Steps 3–5 are *instructional*: they revoke consent and arm a marker, but the floating gate
(`bbtools.lua`) **never runs against payload already in `self.messages`**. So a prior `tool_result`
that drew from pages now ahead of a rewound reader stays **verbatim** in the resent history — the
model can re-quote future-page content it already fetched. The instruction is the belt; this redaction
is the suspenders that actually removes the leak surface from the wire.

Only on a rewind (`is_backward` **and `not self._reveal_all`** — Round 6, the "Reveal everything"
escape hatch disables this redaction for the session), walk `self.messages` in memory
(`for _, m in ipairs(self.messages) do … for _, block in ipairs(m.content) do …`, so the snippets
below have `block` in scope) and redact **two** block families:
(1) every **`tool_result`** block whose `max_referenced_page` is `> cur_page` (a spoiler-true read
recorded `SPOILER_SENTINEL = 0x7fffffff`, which is `> cur_page` for every real page, so it always
redacts on a rewind — §3.3); **and (2) every `web_search_tool_result` block unconditionally** (LEAK-7,
Round 4 — web results carry no page bound and were never produced by the floating gate). In both cases
replace `content` with a **structurally valid** redaction stub that keeps `validateMessages` passing:

As wire blocks are redacted, **collect their `tool_use_id`s into a `redacted_ids` set** and set a
single **`any_redacted`** flag, so the transcript scrub below can map redacted wire blocks back to
their on-screen lines (Round 11: the earlier `redacted_turn[msg_idx]` set is **deleted** — it held
`self.messages` indices, which have **no mapping** to transcript positions, so nothing could ever
consume it; the flag is what the untagged-blob fallback below actually needs).
Declare both **once, before** the `self.messages` walk:

```lua
-- BEFORE the walk: redacted_ids = set of tool_use_id whose backing block was redacted on this rewind;
-- any_redacted = true iff ANY wire block was redacted (drives the Round-11 untagged-transcript
-- fallback below). Both populated inside the walk.
local redacted_ids, any_redacted = {}, false

-- INSIDE the walk: tool_result stays a tool_result with the same tool_use_id; only content changes.
if type(block.max_referenced_page) == "number" and block.max_referenced_page > cur_page then
    block.content = "[Earlier result hidden: it referenced content past your current page "
                 .. tostring(cur_page) .. " after you moved back. Search again if you want it.]"
    if block.tool_use_id then redacted_ids[block.tool_use_id] = true end
    any_redacted = true
end
```

**Web-search redaction on rewind (LEAK-7, Round 4).** A server-side `web_search_tool_result` block
carries **no per-block `max_referenced_page`** (annotation is recorded only for client `grep`/`read`
tool_uses — §5.2) and the floating page gate **never produced it**, so the single `> cur_page` predicate
above can never touch it. A model that web-searched "how does Moby-Dick end" at the saved (later)
position would leave that result **re-quotable verbatim** on a rewind. So in the **same** rewind walk,
**unconditionally redact every `web_search_tool_result` block's content** (web results have no notion of
the reader's page; there is no safe-keep case on a rewind):

```lua
-- web_search_tool_result stays a web_search_tool_result with the same tool_use_id/type, so
-- pairDanglingWebSearch / validateMessages stay satisfied; only content is replaced with a
-- structurally-valid error OBJECT (NOT a string). web_search_tool_result.content is never a
-- string on the wire (§3.3/§9.1 coerceToolResultContent EXCLUDES it): the legal shapes are a
-- gateway results array or the synthetic error object {type="web_search_tool_result_error",
-- error_code=…}. We reuse pairDanglingWebSearch's exact shape (bbconversation.lua:88-91), which
-- round-trips through rapidjson as a table (§9.2 error-object round-trip test) and is accepted by
-- the real Anthropic/Vertex schema — a string content would 400 on the first post-resume buildBody.
-- The transcript-side REDACTION_STUB (Rule 2) is display text and is unaffected.
if block.type == "web_search_tool_result" then
    block.content = { type = "web_search_tool_result_error", error_code = "unavailable" }
    if block.tool_use_id then redacted_ids[block.tool_use_id] = true end
    any_redacted = true
end
```

This runs only on `is_backward`, preserving `tool_use_id` and `type` so web-search pairing and
alternation are untouched. (Forward/same: nothing redacted, consistent with §8.3.)

**Seed `book_context` surgery on rewind (LEAK-8, Round 6 — the seed is never a `tool_result`).** The
seed `book_context` is fetched in `ask()` (`bbconversation.lua:227`) and embedded as **raw text**
inside the `<book_context>` block of `messages[1]` — it is **never** a `tool_result` and carries **no**
`max_referenced_page`. The two predicates above walk `tool_result` / `web_search_tool_result` blocks
only, so they can **never** touch the seed's `"Current chapter: <title>"` line (`bbtools.lua:472`),
which can itself spoil (e.g. `"Chapter 30: Ahab's Death"`). Step 2's seed rewrite only re-anchors the
`"Current page:"` line and is explicitly **fail-open** (DRIFT-1), so on a rewind the stale chapter
title would otherwise stay **verbatim** in the resent history, guarded only by the Step-4 instruction
to ignore it. Therefore, on `is_backward and not self._reveal_all` (Round 10 — it now honors the
escape hatch like Steps 5/5c/7; the earlier "unconditional on `is_backward`" framing false-blocked a
reader who tapped "Reveal everything"), run a string-surgery pass on the seed
block — independent of Step 2's post-condition: locate the single `{type="text"}` block of
`messages[1]` whose text contains `"<book_context>"` and **strip/redact any `"Current chapter:"`
line** (and re-anchor the `"Current page:"` line to `cur_page` exactly as Step 2 does, in case Step 2
failed open). **Round 11 — span-bounded, like Step 2:** the seed is ONE block holding the untrusted
passage/note text alongside the plugin-generated context (§3.1), so the surgery locates the
`<book_context>…</book_context>` span with plain `find` and rewrites **inside that span only** —
patterns never run over the passage text. It actually removes the leak from the wire rather than
relying on the instruction:

```lua
-- is_backward AND NOT _reveal_all. Seed book_context surgery (the seed has no max_referenced_page; the
-- tool_result predicates cannot reach it). Re-anchor Current page (belt for a failed-open Step 2) and
-- strip the Current chapter line (it can name a future chapter). cur_page AND total are the Step 0.5
-- locals (total = the live getPageCount(); a bare `total` would bake "of nil" into messages[1]).
-- HONORS THE ESCAPE HATCH (Round 10): like Steps 5/5c/7, this runs only when redaction is in force.
-- When the reader tapped "Reveal everything" (_reveal_all true), the seed "Current chapter:" line stays
-- verbatim -- otherwise we false-block the exact later-book discussion the reader just opted to keep,
-- contradicting the L2044 promise that _reveal_all "behaves like a forward/same resume ... nothing
-- hidden." (We still re-anchor "Current page:" only when redacting; on a reveal-all resume Step 2's
-- own re-anchor already ran and a stale page number is not a spoiler under reveal-all.)
if is_backward and not self._reveal_all then
    local seed = self.messages[1]
    if seed and type(seed.content) == "table" then
        for _, b in ipairs(seed.content) do
            if b.type == "text" and type(b.text) == "string" and b.text:find("<book_context>", 1, true) then
                -- Round 11 — SPAN-BOUNDED: the seed is ONE block; the untrusted passage/note text
                -- shares it (ask() concatenates all tags into one string, bbconversation.lua:340-360;
                -- buildBody makes it ONE text block, bbanthropic.lua:84-89). A whole-block gsub would
                -- mutilate a passage that itself contains a "Current page:"/"Current chapter:" line.
                -- Locate the plugin-generated span with PLAIN find, rewrite inside it, splice back.
                -- (The replacement strings are plugin numbers or "?" — no `%` capture hazard; the
                -- span itself is plugin-generated, so gsub WITHIN it is safe.)
                local s = b.text:find("<book_context>", 1, true)
                local e = b.text:find("</book_context>", 1, true)
                if s and e and e > s then
                    local span = b.text:sub(s, e - 1)
                    span = span:gsub("Current page:[^\n]*", "Current page: " .. tostring(cur_page) .. " of " .. tostring(total))
                    span = span:gsub("Current chapter:[^\n]*\n?", "")  -- drop the (possibly future) chapter title
                    b.text = b.text:sub(1, s - 1) .. span .. b.text:sub(e)
                end
            end
        end
    end
end
```

**Foreign-file `book_context` `tool_result` with NO annotation (Round 6 fail-safe).** The
`tool_result` predicate above keys on `type(block.max_referenced_page) == "number"`. A file written by
an **older A**, a **sibling approach**, or a **hand/Syncthing edit** has **no** `max_referenced_page`
on its interior `book_context` `tool_result`, so on a rewind the spoiling `"Current chapter:"` line
would stay verbatim, guarded only by the instruction. Therefore, on `is_backward and not
self._reveal_all` (Round 10 — honors the escape hatch like Steps 5/5c/7; "Reveal everything" keeps
even a foreign blob's later-book content visible), when a
`tool_result.content` (string) matches the plugin-generated `"Current page: %d of %d"` /
`"Current chapter:"` shape **and carries no `max_referenced_page`**, redact (strip those lines) anyway
— A cannot prove the embedded page is at-or-behind `cur_page`:

```lua
-- is_backward AND NOT _reveal_all. Belt for foreign/older blobs whose book_context tool_result lacks
-- max_referenced_page. The page-shape arm uses [%w?]+ (NOT %d+) for the page field: tool_book_context
-- (bbtools.lua:464-466) emits "Current page: %s of %s" where %s = tostring(cur or "?"), so an unknown
-- saved position yields the literal "Current page: ? of 610" — %d+ would NOT match the "?" and a
-- "?"-page blob with no chapter line would fall through unredacted. The "Current chapter:" OR-branch
-- independently catches the spoiling case. (The `is_backward and not self._reveal_all` outer gate that
-- arms this whole pass is shown at Step 7's entry; this `if` is the per-block shape filter inside it.)
if not self._reveal_all  -- Round 10: belt-and-suspenders escape-hatch gate (redundant with the outer
    -- walk gate, but kept explicit so this fail-safe is self-defending if ever lifted out of the walk)
    and block.type == "tool_result" and type(block.content) == "string"
    and block.max_referenced_page == nil
    and (block.content:find("Current page:%s*[%w?]+%s+of") or block.content:find("Current chapter:")) then
    block.content = "[Earlier result hidden: it referenced book position past your current page "
                 .. tostring(cur_page) .. " after you moved back. Search again if you want it.]"
end
```

This residual is disclosed in §8.3 LEAK-8.

**Scrub the displayed `transcript[]` on rewind too (Round 6 — the wire-only redaction is not enough,
cross-C §8.E).** Everything above redacts only `self.messages` (the resent wire history). But the
persisted `transcript[]` is rendered by `_render` on resume, and a transcript **tool line** (e.g. a
`"read p.300 — …"` summary) or a future-page **answer** line shows **on screen** even when its backing
wire block was redacted — a **transcript-side spoiler leak** the wire-side redaction does not cover.
Approach C closes this by re-deriving the transcript from the redacted messages (its §8.E). A does the
equivalent surgical scrub: on `is_backward`, after redacting the wire blocks above, **replace the text
of any `transcript[]` `tool`/`assistant` entry whose backing wire block was redacted in this pass with
the same redaction-stub wording**, so screen and wire agree.

To keep screen and wire byte-identical, both sides use a **shared module constant**:

```lua
-- bbconversation module-level constant (shared by the wire-block redaction above AND the transcript
-- scrub below, so the displayed stub and the resent stub are the SAME string).
local REDACTION_STUB = "[Earlier result hidden: it referenced content past your current page after you moved back. Search again if you want it.]"
```

(The `cur_page`-bearing stubs shown earlier in this step append the live page; `REDACTION_STUB` is the
page-agnostic shared base. Either thread `cur_page` into both sites or use the page-agnostic constant on
both — the load-bearing requirement is that the transcript line and its wire block carry the **same**
stub text.) The scrub maps redacted wire blocks to transcript lines through the
**`redacted_ids` set / `any_redacted` flag collected during the wire redaction above**, via two
concrete rules plus a conservative fallback — there is **no** `_redacted_on_rewind` field (that
hand-wave is gone), and (Round 11) no `redacted_turn` set either (message indices have no transcript
mapping; nothing could consume it):

**Rule 1 — `tool` lines by `tool_use_id`.** A persisted `tool` entry carries `_tool_use_id` when it was
stamped at **either** of the two sites (§3.3): the client-tool dispatch line (`= tu.id`, stamped by
`_loop` at `bbconversation.lua:562`) **or** the web-search summary line (`= b.id`, the
`server_tool_use` id, stamped in `_renderAssistantTurn` at `bbconversation.lua:800-809` — Round 8;
without it the spoiling search query and the web-search-only answer line leak on a rewind). It is
persisted by `snapshotTranscript`. Scrub a `tool` entry iff its `_tool_use_id` is in `redacted_ids`
(a `tool` entry lacking the field is simply not matched — the scrub tolerates its absence). The web-side
half of this pairing is closed by the wire walk: every redacted `web_search_tool_result` block adds its
`block.tool_use_id` to `redacted_ids` (the web-search redaction snippet above), and that `tool_use_id` equals
the `server_tool_use` `b.id` the transcript line now carries — so the two ends meet on the same id.

**Rule 2 — `assistant` answer lines by turn.** The trailing `assistant` answer line has **no**
`tool_use_id`, so it cannot be reached by an id-keyed map. Instead: walk `transcript[]` and, for each
`assistant` entry, redact it when a preceding `tool` entry of the same turn was itself redacted by
Rule 1 (i.e. the same tool round produced both the redacted tool line and the answer
that quotes it). This closes the answer-line leak the id-keyed map structurally cannot.

**Fallback — untagged transcripts (Round 11; Rules 1/2 alone were quietly conditional on tagging).**
Both rules key off `transcript[]._tool_use_id`, which a **foreign / pre-tagging** blob's `tool`
entries lack — Rule 1 matches nothing, so Rule 2 (which arms **off Rule 1 matches**) never fires
either: the wire got redacted while the screen still showed the future-page summary AND answer
verbatim, an undisclosed transcript-side leak. Conservative fallback: when **`any_redacted` is true
but no transcript line matched Rule 1**, replace the **entire transcript** with the single
placeholder line `"[Earlier discussion hidden — it referenced parts of the book ahead of your
current position.]"` — lossy on screen (the wire history is untouched beyond Step 7's redaction; the
reader can still continue the chat), but the screen can never disagree with the redacted wire.

```lua
-- is_backward only. Rule 1: scrub a tool line whose backing wire tool_result/web_search block was
-- redacted (keyed by _tool_use_id ∈ redacted_ids). Rule 2: scrub the assistant answer line of a turn
-- whose tool line was scrubbed by Rule 1 (tracked via a "last tool line in this turn was redacted"
-- flag, since the assistant line carries no tool_use_id). thinking entries carry no text; user
-- entries are the reader's own questions and are never redacted. matched_any records whether Rule 1
-- matched at all — the Round-11 fallback trigger for untagged (foreign/pre-tagging) transcripts.
local turn_was_redacted, matched_any = false, false
for _, t in ipairs(self.transcript) do
    if t.role == "user" then
        turn_was_redacted = false                       -- a user turn starts a fresh round
    elseif t.role == "tool" then
        if t._tool_use_id and redacted_ids[t._tool_use_id] then
            t.text = REDACTION_STUB
            turn_was_redacted = true                     -- arm the answer-line rule for this turn
            matched_any = true
        end
    elseif t.role == "assistant" then
        if turn_was_redacted then t.text = REDACTION_STUB end
    end
end
-- Round 11 fallback: wire blocks were redacted but NO transcript line could be matched (untagged
-- tool entries — foreign/pre-tagging blob). Rules 1/2 structurally cannot find the leaking lines,
-- so replace the whole displayed transcript with one honest placeholder; screen and wire agree.
if any_redacted and not matched_any then
    self.transcript = {
        { role = "assistant", text = "[Earlier discussion hidden — it referenced parts of the book ahead of your current position.]" },
    }
end
```

A §14 assertion verifies that after a rewind resume the **rendered transcript contains the stub, not
the original future-page summary OR the original future-page answer line** — and (Round 11) that an
**untagged** blob's rewind resume renders only the single placeholder line.

There is **no separate "produced under spoiler==true" branch**: that flag was an in-memory value not
present in the schema, so on a *resumed* session it could never fire (the leak this step exists for).
Spoiler reads instead persist `SPOILER_SENTINEL` in this same `max_referenced_page` field (§5.2), so the
single `> cur_page` condition covers them on any rewind, restore or not.

This runs **before** the first post-resume `buildBody`, so the redacted (not the original) content is
sent. `tool_use_id` and block type are preserved, so tool_use/tool_result pairing and alternation are
untouched. **Honest residual (carried from Approach C):** redaction is only as good as the per-tool
`max_referenced_page` we recorded — a tool that under-reports its furthest page could still leak; this
is why consent revocation + the marker remain as the belt. On forward/same moves nothing is redacted.

**Step 7b — Unconditional strip (always runs, every direction; fixes the forward/same 400).** After
the (rewind-only) redaction above, run a direction-**independent** pass that removes
`max_referenced_page` from **every** `tool_result` block in `self.messages`:

```lua
-- ALWAYS runs (forward, same, AND backward). Non-wire field: buildBody only nulls cache_control
-- (bbanthropic.lua:60-69) and does NOT strip unknown tool_result fields, so any surviving
-- max_referenced_page is sent to Anthropic → 400 (strict tool_result schema). Step 7's redaction is
-- rewind-only and would leave the field on a forward/same resume → first buildBody 400. This pass is
-- the always-on guard. It runs at the END of _reanchorPosition (after the rewind redaction has read
-- the field) and BEFORE any buildBody.
for _, m in ipairs(self.messages) do
    if type(m.content) == "table" then
        for _, b in ipairs(m.content) do
            if b.type == "tool_result" then b.max_referenced_page = nil end
        end
    end
end
```

This is placed at the close of `_reanchorPosition` deliberately — Step 7's redaction (above) must read
`max_referenced_page` first, so `restore()` intentionally **leaves** the field on the freshly-decoded
persisted blocks and the strip happens here, after redaction, for **all** directions. (The field never
existed on the *live* `self.messages` in the first place — it is merged onto the deep copy at
serialize-time only, §5.2/§9.1 — so this strip is purely about the blocks just loaded from disk.)
Because `_reanchorPosition` runs on every resume before the first `buildBody`, the strip is
unconditional in practice (§7.3, §15 item 5).

### 8.2b — Per-turn nil-page fail-closed guard for resumed sessions (LEAK-0, every later turn)

Step 0.5 refuses a resume when `currentPage(ui)` is nil, but it fires **once**, at `resumeSession`
time. The underlying `bbtools` nil-page leak is **still live for every later turn**: the read gate
bypasses both the start-page refusal (`bbtools.lua:369`, `if start_page and cur`) and the forward clamp
(`:381`, `if cur then`) when `cur` is nil. So a session that **passed** Step 0.5 can still hit an
**unclamped** read on any post-resume turn where the reader navigates to a position with no resolvable
page (transient crengine nil, page-flip mid-stream). §8.3's "airtight" depends on Step 0.5 being the
*sole* entry path — which it is not for later turns.

**Fix:** add a per-turn fail-closed guard in `_loop` for resumed sessions. When the session is resumed
(`self._resumed == true`, set by `_reanchorPosition`) and `type(currentPage(self.ui)) ~= "number"`,
**abort the turn** with the Step-0.5 reason rather than building a body:

```lua
-- At the top of _loop, before buildBody, for a resumed session only:
if self._resumed and type(currentPage(self.ui)) ~= "number" then
    -- Same reason string family as Step 0.5; surface it and do not build a body this turn.
    self:_showTurnRefused(_("Reading position unavailable — open the book to a page, then ask again."))
    return
end
```

This is a **conversation-layer refusal**, not a fix to the `:381` gate itself (which stays exactly as
audited — §8.3). The guard is scoped to resumed sessions because a fresh chat seeded at the live
position has no stale future-page payload to leak against a transient nil; a resumed chat does.

**Round 6 — the entry guard is necessary but NOT sufficient: re-check before every gated tool
dispatch (LEAK-0, the mid-turn window).** `_loop` is a `while true` loop
(`bbconversation.lua:295`) that dispatches `read`/`grep` via `Tools.execute` **once per round**
(`bbconversation.lua:558-578`). The entry guard above fires **once per `ask()`**, before the `while`.
But a reader who page-flips (or crengine transiently returns nil) **between tool rounds within the
same turn** to a position with no resolvable page then reaches `Tools.execute("read", …)` with
`cur == nil`, bypassing **both** `bbtools.lua:369` and `:381` and reading unclamped — the entry guard
already passed and never re-checks. So duplicate the resumed-session nil-page check **inside the
tool-dispatch loop**: in the `for i = 1, #tool_uses` body, **before** each gated `Tools.execute` for
`read`/`grep`, refuse the call when `self._resumed and type(currentPage(self.ui)) ~= "number"` —
returning the Step-0.5 reason string **as the tool result** (so the round stays well-formed and the
model is told why) instead of executing:

```lua
-- Inside the for i = 1, #tool_uses loop, in the Tools.execute dispatch branch (anchored by the
-- Tools.execute CALL — the loop is a ≥3-way split: memory / ask_user / Tools.execute; see §5.2).
-- This is the SAME nil-page check as the loop-entry guard, applied per-round so a mid-turn page-flip
-- to a no-resolvable-page position cannot reach an unclamped read/grep.
if self._resumed and (tu.name == "read" or tu.name == "grep")
    and type(currentPage(self.ui)) ~= "number" then
    -- Refuse THIS gated tool call; feed the reason back as the tool_result so the round is valid and
    -- the model learns the boundary is unavailable. Do NOT execute the tool.
    result, summary = _("Reading position unavailable — open the book to a page, then ask again."), nil
else
    result, summary = Tools.execute(tu.name, tu.input, self.ui)
end
```

Keep the loop-entry guard too (it short-circuits the whole turn when the position is unavailable up
front; the per-round check backstops a position that goes nil mid-turn). Non-gated tools (`get_toc`,
`book_context`, etc.) and `memory` are unaffected — the per-round refusal is scoped to `read`/`grep`,
the only tools that read book body past the gate.

### 8.3 Why this is airtight

- **Unresolvable position (LEAK-0):** a nil live `currentPage` **refuses the resume** (Step 0.5)
  instead of arming a wide-open gate; nothing is restored. **On every later turn** of a resumed
  session the §8.2b loop-entry guard re-checks `currentPage` and aborts the turn if it is nil; **and
  (Round 6) the same nil-page check is re-run before every gated `read`/`grep` `Tools.execute` dispatch
  inside the tool loop** — not only once at loop entry. This closes the mid-turn window: `_loop` is a
  `while true` loop dispatching tools per round (`bbconversation.lua:295`, `:558-578`), so a reader who
  page-flips (or crengine transiently returns nil) **between tool rounds within one turn** to a
  no-resolvable-page position would otherwise reach an unclamped `:381` read after the entry guard
  already passed. The per-round refusal returns the Step-0.5 reason as the tool result instead of
  executing (§8.2b). **The `:381` gate itself is NOT fixed** — nil-page protection is a
  **conversation-layer refusal** (Step 0.5 at entry + the §8.2b loop-entry guard + the §8.2b per-gated-
  dispatch re-check), so a future code path that constructs a *resumed* `Conversation` **outside**
  `resumeSession` (bypassing `_reanchorPosition`, hence with `_resumed` never set) would re-open this
  leak. Any such path must set `_resumed`/re-run the guard.
- **Forward over-block (FALSE-BLOCK-1):** the marker gives the model the new, higher `max_page`,
  overriding the stale lower one — the chat can discuss what was read.
- **Rewind leak (LEAK-1/2):** consent is revoked and must be re-requested; the marker forbids
  `spoiler=true`; the gate (which only widens via `spoiler=true`) is back to floating at the lower
  live page; the highlighted passage is instruction-gated.
- **Future-page payload already in history (LEAK-5):** the floating gate does **NOT** backstop content
  already in `self.messages` — it only runs on *new* tool calls. Step 7 **redacts** in-history
  `tool_result` content whose `max_referenced_page > cur_page` (a single condition — spoiler reads
  recorded `SPOILER_SENTINEL`, so they redact too) before the first post-resume `buildBody`. Belt =
  consent revocation + marker; suspenders = redaction. Residual: only as good as the recorded
  `max_referenced_page`. On forward/same moves (Step 1 classifies `cmp==0` equality as **forward/safe**)
  nothing is redacted — consistent with the redaction predicate.
- **Memory-recall channel (LEAK-6):** `restore` rebuilds the bbmemory store from the **live** book dir
  and the MEMORY_PROTOCOL injects a start-of-conversation memory view, so **any** resume that has not yet
  reached the noted pages can pull later-page plot notes into context. The memory store is keyed to the
  **book**, not the session position, so a **forward** move does **not** make later-page notes safe: a
  session saved at p.142 with notes about p.500, resumed after advancing to p.200, still pulls the p.500
  notes with no guard from the backward-only redaction. Step 7 redacts only `tool_result.content`; it
  does **not** touch the memory store, so for memory-enabled books **the marker (Step 5b), not
  redaction, is the only guard** — this is an honest gap, not an enforced backstop. Therefore the
  memory-quarantine clause is armed on **every memory-enabled resume** (independent of move direction,
  keyed on `cur_page`), instructing the model to treat past-`cur_page` recalled notes as
  spoiler-quarantined; memory-off resumes omit the clause.
- **Web-search results already in history (LEAK-7, Round 4):** a `web_search_tool_result` block carries
  **no per-block `max_referenced_page`** (annotation is recorded only for client `grep`/`read` —
  §5.2/§8.2 Step 7) and the floating page gate **never produced it**, so the single `> cur_page`
  predicate cannot touch it. A model that web-searched "how does Moby-Dick end" at the saved later
  position would otherwise leave that result **re-quotable verbatim** after a rewind. **Closed for
  rewind:** Step 7 now **unconditionally redacts every `web_search_tool_result` block's content** on a
  backward resume — replacing it with the **error OBJECT**
  `{type="web_search_tool_result_error", error_code="unavailable"}` (Round 9; **never a string** —
  `web_search_tool_result.content` is never a string on the wire, §3.3/§9.1, so a string stub would 400
  the real API), preserving `tool_use_id`/`type` so `pairDanglingWebSearch`/`validateMessages` stay
  satisfied — and Step 5c arms a web-search-quarantine marker clause as the belt. **Transcript side also
  closed (Round 8):** the on-screen web-search summary line (`"  → Searched the web for «query» — N
  result(s)"`, which can quote a spoiling query) and a web-search-ONLY turn's answer line are now
  scrubbed too — Step 7 Rule 1 keys on `transcript[]._tool_use_id`, which `_renderAssistantTurn` now
  stamps with the `server_tool_use` id at `bbconversation.lua:800-809` (§3.3/§5.2). Before Round 8 the
  wire was redacted but the screen still showed the query and the answer verbatim — a transcript-side
  leak the wire redaction alone did not cover. On forward/same
  resumes nothing is redacted (the reader moved *past* the saved position). This was an honest gap the
  earlier "airtight" claim omitted; it is now a closed-for-rewind / accepted-for-forward backstop on
  **both** wire and screen, mirroring the LEAK-6 disclosure.
- **Future-page text from `book_context`/`get_toc`/`get_highlights` (LEAK-8, Round 4):** these tools
  carry text from the saved (later) position into history. `book_context` (`bbtools.lua:455-476`) emits
  `"Current page: <cur> of <total>"` AND `"Current chapter: <title>"` — the chapter title alone can spoil
  (e.g. "Chapter 30: Ahab's Death"). **Closed for rewind on three channels (Round 6):** (1) the
  **tool-call** `book_context` result is annotated with `max_referenced_page` at the §5.2 site (live
  page, or the sentinel when unknown), so the `> cur_page` predicate redacts the whole result on a
  backward resume exactly like a `read`; (2) the **seed** `book_context` text in `messages[1]` is
  **never a `tool_result`** and carries no `max_referenced_page`, so on a rewind Step 7 runs an
  **unconditional string-surgery pass on the seed block** that strips the `"Current chapter:"` line and
  re-anchors `"Current page:"` (independent of Step 2's fail-open post-condition — this actually removes
  the seed chapter-title leak from the wire, not just instruction-gates it); (3) a
  **foreign/older-A/hand-edited** `book_context` `tool_result` that has **no** `max_referenced_page` is
  matched by its `"Current page: %d of %d"` / `"Current chapter:"` shape and **redacted anyway** on a
  rewind (A cannot prove its embedded page is at-or-behind `cur_page`). The Step 4 marker still
  instructs the model to ignore earlier "Current page" values and chapter titles as the belt. **Honest
  residual:** the foreign-file shape-match (channel 3) catches only the plugin-generated text shape; a
  wholly foreign block-context format with different wording falls through to instruction-gating only.
  The channel-3 page-shape arm uses `[%w?]+` (not `%d+`) for the page field so an **unknown** saved
  position — `tool_book_context` emits the literal `"Current page: ? of <total>"` when `currentPage` is
  nil (`bbtools.lua:464-466`) — is still matched even when the block carries no `"Current chapter:"` line.
  **Out of scope (accepted
  pre-existing live-gate gaps):** `get_toc` (returns all chapter titles, including future ones) and
  `get_highlights` (returns page + text from ahead) are channels that already leak through the **live**
  gate independent of resume — they are not redacted here and not in scope for persistent sessions;
  named honestly rather than left under an overstated "airtight" claim.
- **Cross-device/reflow (DRIFT-3):** direction is resolved from the device-stable xpointer via the
  gate's own `compareXPointers` oracle (fail-safe to the rewind branch on any ambiguity), never from
  incommensurable stored page integers.
- **Fragile rewrite (DRIFT-1):** the seed rewrite is verified post-hoc and is non-load-bearing — the
  authoritative marker is the real anchor and cannot silently no-op.
- **Stale locators (LEAK-4):** `new()` clears `ui._bookbuddy_locators`; restored `loc:N` tokens hit
  the *not-found* refusal branch (`bbtools.lua:403`), never the layout-shift live-read branch (which
  requires a present locator entry). **Round 11 — the invariant is made true for the WHOLE session,
  not just until the first grep:** `new()` also resets the mint counter `ui._bookbuddy_loc_seq`, so
  a post-resume grep would re-mint `loc:1..n` and a stale `loc:3` in the restored history would then
  silently resolve to a **different live passage** (wrong content — not a spoiler, the page gate
  still clamps, but a correctness hole the old wording papered over). The blob now persists
  `loc_seq` (the mint high-water mark, §3.1/§9.1) and `restore` sets the live counter to
  `max(live, stored)` (§7.3), so a stale token's index is never re-minted. **Invariant: locator
  ENTRIES are never restored; the mint COUNTER is — stale `loc:N` tokens refuse, permanently.**
  (Pre-Round-11 blobs carry no `loc_seq` and keep the old first-grep-collision residual; disclosed.)

- **Nil-page grep hits (in-tree nuance, now closed for rewind).** The grep gate shows a hit with a
  **nil page as VISIBLE** regardless of cap (`bbtools.lua:219`), so a **non-spoiler** grep can surface
  content physically past the reader. A naive `max_referenced_page = min(cur, max_page)` would record
  `cur`, which a same-or-forward resume never redacts (forward/same = never redact), **leaking the
  nil-page hit on a rewind**. A closes this **fail-safe** without changing gate behavior: `tool_grep`
  returns an **additive read-only** `had_unbounded_hit` (true when any visible item had a nil page —
  `item._page == nil`), and the loop records `SPOILER_SENTINEL` for that block whenever
  `spoiler OR had_unbounded_hit` (§5.2/§3.3). The sentinel is `> cur_page` for every real page, so such
  a block redacts on **any** rewind. (On a *forward* resume nothing is redacted — but the reader moved
  *past* the saved position, so the hit is at-or-behind them; the leak only mattered on rewind, which is
  now covered. This is the only nil-page-grep residual; **closed** for rewind, **accepted** for forward.)

`bbtools.lua`'s **gate logic is untouched** — the only `bbtools` change is the **additive, read-only**
`had_unbounded_hit` return from `tool_grep` (pure instrumentation; no partition, cap, refusal, or clamp
behavior changes), so the audited gate stays exactly as audited. The rest of the fix is load-time
string/posture/redaction work in `bbconversation`. (The gate guards *new* tool calls; Step 7's
redaction is what guards payload *already* in the resent history — the gate alone does not.)

---

## 9. Serialization / deserialization

### 9.0 Helper definitions / ownership (buildable-from inventory)

Every helper referenced across §5/§7/§9 with its **owner module** (so this spec is buildable without
guessing where a name lives). Helpers without an explicit upstream owner are **new, defined in
`bbconversation.lua`** as file-locals unless noted.

| helper | owner | notes |
| --- | --- | --- |
| `deepCopy` | `bbconversation` (new local) | recursive table copy; live convo never mutated by strip steps |
| `safeMD5(file)` | `bbconversation` (new local) | `pcall(util.partialMD5, file)`; `nil` on unreadable |
| `safeXPointer(ui)` | `bbconversation` (new local) | `pcall` around `ui.document:getXPointer()`; `nil` for non-cre |
| `countAssistant(messages)` | `bbconversation` (new local) | count of `role=="assistant"` wire messages |
| `numOr0(x)` | **`bbanthropic` LOCAL** — **see fix** | `type(v) == "number" and v or 0` (the actual source, `bbanthropic.lua:200-202` — NOT `tonumber(x) or 0`); used in §7.3/§9.1/§9.3 by `bbconversation` |
| `snapshotTranscript(t)` | `bbconversation` (new local) | strip `_md_src`/`_md_out`; **preserve `_tool_use_id` on `tool` entries** (the rewind-scrub redaction key — §8.2 Step 7); drop non-string `text`; tag the result with the rapidjson array metatable so an empty transcript encodes `[]` not `{}` (Round 6, §9.0) |
| `tagArrays(messages)` | `bbconversation` (new local) | Round 6: set the rapidjson array metatable on `messages` and each `content` block-array so an empty array encodes `[]` not `{}` (§9.0) |
| `sanitizeTranscript(t)` | `bbconversation` (new local) | restore-side; coerce non-string `text`→`""` (§7.3) |
| `stripCacheControl` / `coerceToolResultContent` / `coerceToolUseInput` / `dropSignaturelessThinking` / `mergeReferencedPages` | `bbconversation` (new locals) | §9.1 serialize pipeline |
| `_normalizeToolInputs` / `_syncTranscriptToMessages` | `bbconversation` (new methods) | §7.3 restore belts |
| `currentPage(ui)` | **`bbtools` LOCAL** (`bbtools.lua:58`) | expose/import for §5.2's loop annotation |
| `pairDanglingWebSearch` / `_dropDanglingTail` / `_trimTranscript` | `bbconversation` (existing) | self-healers reused by restore |

**`numOr0` ownership fix (load-bearing).** `numOr0` is a **`local`** in `bbanthropic.lua` — it is **not**
on the `Anthropic` table, so `bbconversation.lua` cannot call it as written in §7.3/§9.1/§9.3. Resolve
one of two ways (pick one, do not leave it dangling): **(a)** export it — `Anthropic.numOr0 = numOr0`
in `bbanthropic.lua` — and `require("bbanthropic").numOr0` from `bbconversation`; **or (b)** define a
private one-line copy that **matches the actual source semantics**
`local function numOr0(v) return type(v) == "number" and v or 0 end` in `bbconversation.lua` (NOT
`tonumber(x) or 0` — they diverge: a JSON-decoded string usage field like `"5120"` from a hand-edited /
foreign file returns `0` under the real helper but `5120` under `tonumber`, so option (b) must mirror
the export to keep restore's usage coercion identical to live `_mergeUsage` semantics).
Same for `currentPage` (a `bbtools` local — §5.2): expose it (`Tools.currentPage = currentPage`) or
import it. The §15 checklist names these owners explicitly.

### 9.1 `serialize()` (lossless, mutation-aware)

```lua
function Conversation:serialize()
    local messages = deepCopy(self.messages)          -- do NOT mutate the live (still-running) convo
    stripCacheControl(messages)                        -- C1: buildBody leaves a stale ephemeral breakpoint
    coerceToolResultContent(messages)                  -- nil CLIENT tool_result content → "" (never 400)
    coerceToolUseInput(messages)                       -- C3: absent OR empty tool_use.input → empty JSON object
    dropSignaturelessThinking(messages)                -- C: drop sig-less thinking; ROLL BACK the tool round
                                                       --   if dropping it orphans a tool_use (§9.1 CRITICAL)
    mergeReferencedPages(messages, self._mrp_by_tool_use_id) -- merge max_referenced_page onto the DEEP COPY
                                                       --   only (NEVER on self.messages — §5.2/§3.3); keyed
                                                       --   by tool_use_id; runs AFTER any rollback so a
                                                       --   removed tool_result is simply skipped.
    tagArrays(messages)                                -- Round 6: tag messages + each content block-array
                                                       --   with the rapidjson ARRAY metatable so an EMPTY
                                                       --   array (post-rollback messages[], empty content)
                                                       --   encodes as [] not {} (§9.0). Transcript tagged
                                                       --   below at the return site.
    -- NOTE: NO _dropDanglingTail / _trimTranscript here (C7) — save sites are terminal/clean, so the
    -- live history is already resendable; defensive trimming would delete the persisted transcript.
    -- getProps() is an uncached crengine C round-trip (Document:getProps → getDocumentProps); call it
    -- ONCE per save, not once per field, since a save fires every terminal turn.
    local props = self.ui.document:getProps() or {}    -- maps "" → nil, so the (unknown) sentinel holds
    -- config_fingerprint: snapshot the toggles that change wire shape, so restore can re-assert the
    -- saved posture and avoid a guaranteed 400 if the reader toggled thinking/web_search since (C1/§9.6).
    -- CRITICAL — snapshot the EFFECTIVE config, not getConfig() (the live one). For a RESUMED session the
    -- wire history is governed by _effectiveConfig() (the saved posture overlaid), and may carry signed
    -- thinking blocks / web_search pairs the LIVE config no longer matches. Re-saving with the live
    -- fingerprint records a posture inconsistent with this file's own messages[] (e.g. resumed
    -- thinking-ON history + reader's live thinking OFF → re-saved file says enable_thinking=false while
    -- history still has thinking blocks). A second-generation resume of that file re-asserts OFF and
    -- emits no body.thinking while resending thinking blocks → the exact R1 guaranteed thinking-400. A
    -- resumed session MUST persist the posture its messages[] were built under, not the live one, else a
    -- chain of resumes drifts back into the R1 thinking-400. _effectiveConfig() returns a fresh table per
    -- §9.6, safe to read here.
    local cfg = self:_effectiveConfig()
    return {
        schema_version = 1,
        id        = self._session_id,
        created   = self._session_created,
        updated   = os.time(),                         -- also re-stamped by Session.save
        config_fingerprint = cfg and {
            enable_thinking    = cfg.enable_thinking,
            enable_web_search  = cfg.enable_web_search,
            enable_memory      = cfg.enable_memory,
            model              = cfg.model,
        } or nil,
        book = {
            title   = props.title or "(unknown)",
            authors = props.authors or "(unknown)",
            ident   = safeMD5(self.ui.document.file),
            file    = self.ui.document.file,
        },
        anchor = {
            xpointer      = safeXPointer(self.ui),                 -- nil for non-cre docs
            page_at_save  = currentPage(self.ui),
            total_at_save = self.ui.document:getPageCount(),
        },
        -- Round 11: locator mint high-water mark (§3.1/§8.3 LEAK-4). restore sets the live counter
        -- to max(live, stored), so stale loc:N tokens in restored history are never re-minted.
        loc_seq = (self.ui and self.ui._bookbuddy_loc_seq) or 0,
        spoiler_consent = self._spoiler_consent == true,
        title_snippet   = self._title_snippet or "",
        turn_count      = countAssistant(messages),
        -- §3.1/§7.3: original seed material, so an empty-history restore (tail-heal emptied messages)
        -- re-seeds at the live position with the ORIGINAL highlight instead of dropping it. Round 11:
        -- restore() rehydrates selected_text/note from data.seed UNCONDITIONALLY, so this expression
        -- carries the field forward on every re-save of a resumed session (no generation-2 decay).
        seed = (self.selected_text or self.note) and {
            selected_text = self.selected_text,
            note          = self.note,
        } or nil,
        usage = {
            input       = numOr0(self.usage.input),
            output      = numOr0(self.usage.output),
            cache_read  = numOr0(self.usage.cache_read),
            cache_write = numOr0(self.usage.cache_write),
        },
        messages   = messages,
        transcript = snapshotTranscript(self.transcript),         -- strip _md_src/_md_out; drop non-string text
    }
end
```

Helper contracts:
- `deepCopy` — **plain** recursive table copy with **no metatable preservation** (so the live
  conversation, which may keep running after a save, is never mutated by the strip step). Consequence:
  the rapidjson object metatable on a zero-arg `tool_use.input` sentinel does **not** survive the copy —
  it becomes a bare empty `{}` — which is exactly why `coerceToolUseInput` (§9.1) must re-coerce both
  `nil` AND empty tables (Round 10), and why `tagArrays` (below) must re-tag array-typed tables.
- `tagArrays(data)` (Round 6 — **empty-array-vs-object trap**) — `rapidjson.encode` decides array vs
  object by **metatable first, then `rawlen > 0`**: an **empty plain Lua table** (no `__jsontype`)
  encodes as `{}` (a JSON **object**), not `[]`. `deepCopy` produces plain tables. The spec's own
  `dropSignaturelessThinking` rollback / empty-history paths can legitimately produce an **empty
  `messages[]`** (or an empty `content` block-array), which would then serialize as `"messages":{}` —
  **malformed wire** (the API requires an array), and the §14 deep-equal round-trip baseline can
  spuriously pass/fail because the decoded `json.object` vs the deep-copied empty plain table compare
  inconsistently. This is the **same rapidjson trap** already documented for `coerceToolUseInput`
  (bare `{}` → `[]`). **Fix:** at the **end of `serialize()`** (after all strip/coerce/merge/rollback
  steps), tag every array-typed table with the rapidjson **array** metatable so emptiness is
  unambiguous — `messages`, `transcript`, **and every per-message `content` block-array**:
  ```lua
  -- getmetatable(rapidjson.array({})) is the array sentinel metatable; setting it makes an EMPTY table
  -- encode as [] not {}. Tag the top-level arrays and each content block-array. NOTE: rapidjson.array
  -- is OPTIONAL at the call site -- the real lib exposes it, but the Tier-1 stub historically did not
  -- (stubs.lua:234-247 had only encode/decode/object/null). A bare `rapidjson.array({})` would then be
  -- a nil call, throwing inside serialize() on EVERY Tier-1 run (swallowed by _persist's pcall, so
  -- every Tier-1 save silently no-ops, and the §14 round-trip tests error inside serialize()). So the
  -- MT lookup is pcall-guarded and runtime-detected: tagArray no-ops when `array` is absent (the
  -- value-equality §14 helper, below, ignores metatables anyway, so an untagged copy still passes).
  local ok_mt, ARRAY_MT = pcall(function() return getmetatable(rapidjson.array({})) end)
  if not ok_mt then ARRAY_MT = nil end
  local function tagArray(t)
      if ARRAY_MT and type(t) == "table" then setmetatable(t, ARRAY_MT) end
  end
  tagArray(messages)
  for _, m in ipairs(messages) do
      if type(m.content) == "table" then tagArray(m.content) end
  end
  ```
  Run this on the **deep copy** only (never on `self.messages` — tagging the live array is harmless but
  the contract is "serialize touches only the copy"). The `transcript[]` array is tagged the same way
  **inside `snapshotTranscript`** (it builds the persisted transcript), so an empty transcript also
  encodes `[]`. With this, a fully-rolled-back history encodes `"messages":[]`, not `"messages":{}`.

  **Tier-1 stub requirement (chosen — option a + value-equality).** The Tier-1 `rapidjson` stub
  (`tests/support/stubs.lua:234-247`) historically exposed only `encode`/`decode`/`object`/`null` — no
  `array`. The spec **adds an `array` shim** to that stub so the MT lookup resolves and `tagArrays`
  exercises a real code path under Tier-1:
  ```lua
  -- tests/support/stubs.lua, in the rapidjson double:
  array = function(t) local r = t or {}; r.__array = true; return r end,
  ```
  This is a marker shim, **not** byte-compatible with the real lib's array metatable (the real lib
  tags via a metatable; the stub tags via an `__array` field). To keep the §14 deep-equal baseline from
  spuriously diverging — the serialize side would carry the real array MT / stub `__array` marker while
  the decoded side carries the stub decoder's own array marker — the §14 deep-equal helper is pinned to
  **value-equality that ignores metatables AND the `__array` marker key** (see §14 baseline note). So
  the round-trip compares *content*, never the array-ness tag, on either tier.
- `stripCacheControl(messages)` — for every message with table content, for every table block, set
  `block.cache_control = nil`. After this, a never-saved array and the restored array are deep-equal
  (the only divergence `buildBody` introduces is the ephemeral breakpoint).
- `coerceToolResultContent(messages)` — short-circuits when `type(content) ~= "table"` (mirrors
  `stripCacheControl`: a message whose `content` is a **string** — the seed before first `buildBody`, and
  every interior follow-up user turn, `bbconversation.lua:254/256` — has no blocks to walk). For any
  **client `tool_result`** block, coerce `content` to a
  legal client shape (string, or content-block array): `content == nil` → `""`; and (Round 6) a
  **non-string, non-array** `content` (a number, boolean, or arbitrary table delivered by a
  hand-edited / Syncthing-merged / foreign-client file) → `tostring(content)` (or `""` for a table that
  is not an array of blocks). A client `tool_result.content` **must** be a string or a content-block
  array; a number/foreign-table survives `serialize` untouched and **passes `validateMessages`** (which
  only checks pairing, not content type) yet **400s the real API**, so the spec's "never 400 …
  regardless" guarantee does **not** hold for this class without this coercion. (Guarded at both live
  dispatch sites today by `result or ""` — `bbconversation.lua:577` via `Tools.execute`'s `result or ""`
  and `Store:execute`'s `res or ""` — but only against `nil`, and only for blocks **A** wrote; the
  load-side `_normalizeToolInputs` belt (§7.3) is the parallel guard for foreign blobs and may carry the
  same non-string coercion.) **Explicitly EXCLUDES `web_search_tool_result`**: its
  `content` is legitimately a **table** — either the synthetic error object
  `{type="web_search_tool_result_error", error_code=…}` produced by `pairDanglingWebSearch`, or a
  gateway results array — and flattening such a table to `""` would corrupt it. `web_search_tool_result`
  content is left as whatever string/table it was.
- `coerceToolUseInput(messages)` (C3) — runs **after** `stripCacheControl`. Short-circuits a message
  whose `content` is not a table (the seed before first `buildBody`, and interior follow-up user turns,
  carry **string** content — §9.1 string-content note below). For every block with
  `type == "tool_use"` or `"server_tool_use"`, if **`block.input == nil` OR `block.input` is an empty
  table (`next(block.input) == nil`)** set `block.input = rapidjson.object({})` (the empty-object
  **sentinel**, not bare `{}` — bare `{}` encodes as `[]`). This is required, not defensive: a
  **zero-arg** tool call (`get_toc`, `book_context`, `get_highlights`) never receives an
  `input_json_delta`, so `content_block_stop` never assigns `.input` (`bbanthropic.lua:282` only sets it
  when `accum and #accum > 0`). The carried-forward block therefore has `input` **ABSENT** (not `{}`);
  after `deepCopy` + `rapidjson.encode` an absent `input` re-sends as a `tool_use` with no `input`
  field → 400. We do NOT rely on the live parser having set it.
  **Round 10 — the empty-table arm closes a re-save divergence with `_normalizeToolInputs`.** The
  load-side belt `_normalizeToolInputs` (§7.3 — a NEW `bbconversation` method) already coerces **`nil` OR an
  empty table** → `rapidjson.object({})` on `self.messages` at restore. But `deepCopy` (§9.1) is a plain
  recursive copy with **no metatable preservation**, so it strips the rapidjson object metatable on a
  re-save: a re-saved restored zero-arg-tool session then has `input` as a **bare empty `{}`** (not nil).
  A `nil`-only `coerceToolUseInput` would NOT re-coerce that bare `{}`, so it re-encodes as `[]` → 400 on
  the **next** resume of the re-saved file. Matching `_normalizeToolInputs` (nil OR empty) makes the
  load-side belt and the serialize-side coercion converge so a chain of resume→re-save→resume cannot
  drift a zero-arg tool back into the `[]` 400.
- `dropSignaturelessThinking(messages)` — **short-circuits any message whose `content` is not a table**
  (`type(content) ~= "table"`): the seed before first `buildBody` and every interior follow-up user turn
  carry **string** content (`bbconversation.lua:254/256`; `buildBody` rewrites only the LAST message's
  string content to an array — `bbanthropic.lua:73-76`). This skip is **load-bearing here**, not merely
  latent: the helper's block-order walk and pair-roll classify on block `type`, and `ipairs` over a
  string yields nothing, so an unguarded walk would treat a string-content interior **user** turn as an
  empty block list and could mis-anchor the rollback's "last clean assistant turn." Explicitly skip
  string-content messages before walking blocks. Then, for every assistant message, drop any `thinking`
  block whose `signature` is not a non-empty string. `serialize()` does a plain `deepCopy` with no validation, so
  a thinking block whose `signature_delta` never arrived (a truncated stream that still reached
  `message_stop`, or a non-Anthropic gateway that strips signatures) would have `signature == nil` —
  persisting it makes a durable, resumable-into-guaranteed-400 file (signature is mandatory on
  resend — §3.3). A signatureless thinking block is unusable; drop it rather than persist it.
  **CRITICAL — do not manufacture the very 400 §9.6 prevents.** A signatureless `thinking` can **share
  an assistant message with a `tool_use`/`server_tool_use`** (e.g. `[thinking(no sig), tool_use]`).
  Naively dropping just the thinking leaves `[tool_use]` — and on resume `config_fingerprint` re-asserts
  thinking ON (it was ON at save), so `buildBody` emits `body.thinking` while resending a `tool_use`
  with **no preceding signed thinking** → the exact thinking-before-tool_use / orphan-`tool_use` 400
  §9.6 names. `validateMessages` does **not** check thinking-before-tool_use (`sse.lua`), so a naive
  serializer passes every Tier-1 round-trip while the real resume 400s — the serializer manufactures
  the failure it claims to prevent. **Therefore:** when dropping a signatureless `thinking` from a
  message that **still contains** a `tool_use`/`server_tool_use`, do **not** leave the orphaned tool
  turn. Instead **roll the whole trailing tool round back to the last clean assistant turn** using the
  **same logic as `_dropDanglingTail`**: drop the `[assistant tool_use]` message **and its paired
  `[user tool_result]`** so the persisted history ends on a clean, resendable assistant (or the seed) —
  the same shape `_dropDanglingTail` produces for a dangling client `tool_use`. (Chosen over the
  alternative "refuse to persist / `serialize()` returns no data" because the rollback preserves the
  resumable prefix instead of dropping the whole chat; `serialize()` still returns the rolled-back
  blob.) A message whose dropped thinking left only `text` blocks (no tool_use) needs no rollback.
  **Round-5 — INTERIOR signatureless-thinking orphan (the tail-roll is not enough); Round 7 — the
  trigger is BLOCK-ORDER-AWARE, not "message also carries a tool_use".** The rollback above uses
  `_dropDanglingTail` logic, which walks **only the tail** — but a signatureless `thinking` can sit in an
  **interior** assistant message that also carries a `tool_use`/`server_tool_use` (the model interleaves
  thinking between tool calls — `bbanthropic.lua:50-51`; the signature can be absent if a gateway strips
  it). Dropping that interior thinking can leave an interior `tool_use` with **no preceding signed
  thinking** in the same message, while later rounds are still valid (so the tail-roll cannot reach it).
  On resume `config_fingerprint` re-asserts thinking ON → the exact thinking-before-tool_use /
  orphan-tool_use 400 §9.6 prevents — and it passes **every** Tier-1 `validateMessages` round-trip,
  because `sse.lua` does **not** check thinking-before-tool_use.

  **The trigger must be block-order-aware (Round 7 — "message also carries a tool_use" is too coarse and
  WRONG).** A single assistant message can legitimately be
  `[thinking(signed), tool_use, thinking(no-sig), text]`: dropping the trailing signatureless thinking
  leaves `[thinking(signed), tool_use, text]` — a **valid** message, because the `tool_use` *still* has a
  signed thinking block preceding it in content order. The coarse "interior message that ALSO carries a
  tool_use → truncate" rule would needlessly truncate all subsequent resumable history here, **over-
  truncating a valid prefix**. The orphan exists only when a `tool_use`/`server_tool_use` ends up with
  **no signed thinking block preceding it in the same message's content order**. **Therefore (chosen —
  Option b, block-order-aware):** for each assistant message, walk its content **in block order**; after
  (conceptually) dropping the signatureless `thinking` blocks, the message is an **orphan** iff it
  contains a `tool_use`/`server_tool_use` with **no `thinking` block carrying a non-empty `signature`
  earlier in that same content array**. When the **first** such interior orphan is found, **truncate the
  persisted `messages[]` at the last clean assistant turn BEFORE it** — drop that message, its paired
  `[user tool_result]`, and **all subsequent rounds** — so the persisted history ends on a clean,
  resendable assistant (or the seed). A message where every `tool_use` is still preceded (in block order)
  by a signed `thinking` after the drop is **left intact and is not a truncation trigger** (only the
  signatureless thinking blocks themselves are removed). The transcript is resynced restore-side by the
  existing **unconditional** `_syncTranscriptToMessages` (§7.3), so no transcript surgery happens in
  `serialize()`. (The trailing tool-round rollback above is the special case where the orphan IS the
  tail; this generalizes it to any interior position by truncating from the first interior orphan onward.
  The rejected Option (a) — refuse to persist the whole file, `serialize()` returns nil → `_persist`
  no-ops — discards the resumable prefix and is not used.) Because Tier-1 cannot detect this shape, a
  **§14 Tier-2 test** (real rapidjson) covers it.
  **Round-4 — empty-content message.** If dropping `thinking` blocks reduces an assistant message to
  **zero** content blocks (a `[thinking(no sig)]`-only message), do **not** persist it as
  `{role="assistant", content={}}`: that resends as the empty-content 400 the **live** loop guards
  against at `bbconversation.lua:506-513` with a `(no response)` placeholder — but `serialize()` has no
  placeholder path. Instead **drop the whole message** and **pair-roll** the same way as the
  orphan-`tool_use` case (drop its paired `[user tool_result]` if any, rolling back to the last clean
  assistant turn) so the persisted history ends resendable. Never persist `content={}`.
  **Round-4 — persisted-transcript desync after a rollback.** This rollback shortens the persisted
  `messages[]` deep copy, but `serialize()` persists `snapshotTranscript(self.transcript)`
  **unmodified** (§9.1 forbids `_trimTranscript` here). So the rolled-back round's tool line + the
  assistant answer survive in `transcript[]` while their backing wire messages are gone — a file with an
  **already-short `messages[]` + a longer transcript**. The robust guard is **restore-side**: `restore`
  now calls `_syncTranscriptToMessages()` **unconditionally** (§7.3, Round 4), trimming the transcript
  back to the surviving last-assistant turn whether the short-vs-long mismatch came from a restore-side
  tail-drop **or** this serialize-side rollback. (We deliberately do **not** trim `self.transcript` in
  `serialize()` — never mutate the live transcript; the restore-side unconditional sync covers both.)
- `mergeReferencedPages(messages, mrp_by_id)` — short-circuits when `type(content) ~= "table"` (a
  string-content seed/interior user turn has no `tool_result` blocks). For every `tool_result` block in
  the **deep-copied** `messages`, if `mrp_by_id[block.tool_use_id]` exists, set
  `block.max_referenced_page` to it. This is
  the **only** place the annotation reaches a `messages` array, and it operates on the **deep copy
  only** — `self.messages` (the live wire history `buildBody` resends) is **never** touched, so the
  live continuation path never sends an unknown `tool_result` field (§5.2/§3.3). Runs **after**
  `dropSignaturelessThinking`'s rollback, so a `tool_result` removed by the rollback is simply absent
  and its side-table entry is harmlessly skipped. **Round 11:** the side-table is fed from **two**
  sites — the live tool loop (§5.2) for blocks this session produced, and `restore`'s **taint
  harvest** (§7.3) for annotations decoded from the blob — so a resumed session's re-save re-emits
  the inherited annotations and taint survives every save generation (the generation-2 rewind leak).

### 9.2 Object/array round-trip (C3)

The Tier-1 stub's `rapidjson.object` is `return t` and its encoder re-derives array-ness by content
heuristic, so a **stub-only spec cannot detect a real-rapidjson regression**. Therefore:
- The `tool_use.input` object-ness assertion lives in **Tier-2** (real rapidjson — §14). Note the
  source contract (§9.1 `coerceToolUseInput`): for a zero-arg call `input` is **ABSENT** in the wire
  history (and, after a restore→re-save whose `deepCopy` stripped the sentinel, a **bare empty `{}`**),
  and `serialize()` **coerces both** to an empty JSON object (`rapidjson.object({})`); we do
  not rely on the live parser having produced `{}`.
- `web_search_tool_result.content` is **not coerced** (§9.1) and an *empty* `[]` content is not
  actually producible by this plugin — synthetic content from `pairDanglingWebSearch` is always the
  error **OBJECT**, and gateway content is non-empty. So the Tier-2 C3 assertion tests the **error-object
  content round-trip** (the real producible case), not an unproducible empty `[]`.
- The Tier-1 spec constructs message inputs via the **decode path** (not bare `{}`), modelling the
  realistic production path (stored inputs always originate from `decode`), and is documented as
  "shape sanity, not object/array proof."

`thinking.signature` is plain string data — **preserved verbatim by `deepCopy` when present**;
**signatureless thinking blocks are dropped** by `dropSignaturelessThinking` (§9.1), since a thinking
block without a signature is unusable on resend. A spec re-sends a signed block on a follow-up turn (§14).

### 9.3 `restore` (pair-then-drop, posture-safe, refuse-unrestorable) — see §7.3

- Assign fields; **guard `type(data.usage) == "table"` before field access** (C-usage), then coerce all
  four numbers through `numOr0` (C4). `numOr0` alone does **not** suffice: a synced/edited file with
  `usage` as a **number** (e.g. `0`) reaches `(0).input` → "attempt to index a number value" and
  crashes resume; a *string* usage survives via the string metatable, but a number does not. The
  table-ness guard covers both. (A `null` field then still coerces through `numOr0` for `_usageText`.)
- Re-assert the saved config posture from `config_fingerprint` (C1 — §9.6) and re-derive `tool_specs`.
- Run `pairDanglingWebSearch(content)` on **every** assistant message **first** (C8), then
  `_dropDanglingTail()` once. `_clean_transcript_len` is `nil` after `new`, so the embedded
  `_trimTranscript` is a no-op on the restored transcript (which we keep verbatim).
- **Reverse-orphan web-search heal (Round 4, both directions).** `pairDanglingWebSearch`
  (`bbconversation.lua:73-96`) heals only the **forward** orphan (a `server_tool_use` lacking its
  `web_search_tool_result` → append a synthetic error object). It does **not** drop the **reverse**
  orphan — a `web_search_tool_result` whose `server_tool_use` id is **absent** in the same array (a
  Syncthing-merged or hand-edited file). Such a block passes restore's leading/interior/tail checks but
  **400s `validateMessages`** on the first `buildBody`. In the **same** per-message pass, after the
  forward healer, `restore` therefore drops any `web_search_tool_result` whose `tool_use_id` has no
  matching `server_tool_use` id in that message's content (Approach C's `bbwire.healWebSearch` handles
  both directions; A previously ran only the forward healer). No schema change, no journal.
  **Round-5 — empty-content after reverse-orphan removal.** This removal can reduce an assistant
  message's content to `{}`; `_dropDanglingTail` does not treat an empty-content assistant as dangling
  (it checks only for a `tool_use`/orphan `server_tool_use`), so it survives, passes the
  leading/interior/tail checks **and** `validateMessages`, and re-introduces the empty-content 400 on the
  restore side (which has no placeholder guard). In the **same** per-message pass, any assistant message
  emptied by the reverse-orphan removal is **placeholdered** with `{type="text", text="(no response)"}`
  (mirroring the live guard at `bbconversation.lua:512`), so it never survives as `content={}` (§7.3).
  **Round-6 — the placeholder is BELT-ONLY, not enabling.** It rescues only the case where the emptied
  assistant is **not adjacent to another assistant** (effectively the tail, or surrounded by user
  messages). If the reverse-orphan was an **interior** turn between two assistant turns, the
  placeholdered message is still an assistant next to an assistant, so the **interior-alternation check
  below REFUSES the file** regardless — the placeholder does not make an adjacent-assistant file
  restorable (interior alternation is explicitly not self-healed). So the §14 "reverse-orphan removal
  does not leave empty content" test must place the reverse-orphan-only message **surrounded by user
  messages** (`[user, assistant(reverse-orphan-only), user]`), otherwise restore refuses it instead of
  validating.
- **The result is NOT unconditionally `validateMessages`-clean.** The self-healers heal only specific
  shapes: `_dropDanglingTail` heals the **tail** and `pairDanglingWebSearch` heals **web-search
  pairing** — neither touches (a) a **leading non-user message** (corrupt/synced file that lost the
  user seed → first-message-must-be-user fails) or (b) **interior consecutive same-role messages**
  (Syncthing merge / duplicated turn → alternation fails). After tail-heal, `restore` therefore
  asserts `#messages == 0 or messages[1].role == "user"` **and** that no two adjacent messages share a
  role; on violation it **returns `nil, reason`** — the file is treated as unrestorable (resume
  refused, never deleted). **Interior alternation is explicitly NOT self-healed** (§11): the file is
  refused, not repaired.
- After those checks pass, the restored array **does** satisfy `sse.validateMessages` (first-message-user,
  alternation, no dangling client `tool_use`, no orphan `server_tool_use`). **Caveat (C10):**
  `validateMessages` does **not** check `signature` presence, input object-ness, `cache_control`
  leakage, or non-table usage — passing it is necessary, not sufficient; those are covered by the
  serialize strip/coerce steps, the table-usage guard, and the dedicated specs.

### 9.4 pause_turn-extended assistant messages

A pause-resumed turn is one logical `{role="assistant", content=[…]}` message whose content was
extended in place by `_storeAssistant` (`bbconversation.lua:599-608`). It serializes and restores
as an ordinary assistant message — no special handling. The web-search pairing in `restore` operates
per-message, so an extended message's interleaved `server_tool_use`/`web_search_tool_result` pairs
stay intact — including the Round-4 **reverse-orphan** heal, which scopes its
`server_tool_use`-id-presence check to the **same** message's content, so a legitimately paired block in
an extended message is never dropped.

### 9.5 transcript persisted, not re-derived

`messages[]` lacks tool summaries ("— 5 matches") and thinking "Done" markers, so re-derivation
would be lossy. We persist `transcript[]` (cost: a handful of small tables) to preserve the display
faithfully.

### 9.6 Config-posture reconciliation (C1 — the largest correctness bug)

**The bug.** `buildBody` sets `body.thinking` **only** when `cfg.enable_thinking` (`bbanthropic.lua:53-54`),
but it **always resends** whatever `thinking` blocks are in `self.messages` (it merely strips
`cache_control`). The tool loop reads `cfg = self.settings:getConfig()` fresh per turn
(`bbconversation.lua:274`). So:

- **thinking ON at save → reader toggles OFF → resume → ask:** `buildBody` omits `body.thinking` yet
  resends the persisted `thinking` blocks → **guaranteed Anthropic 400 every turn**.
- **thinking OFF at save → ON now → resume:** the first restored assistant turn has a `tool_use`
  **without** a preceding `thinking` block, tripping the thinking-before-tool_use rule → 400.

The same class of drift applies to `enable_web_search` (resent `server_tool_use`/`web_search_tool_result`
pairs vs. whether the web_search tool is offered). This is wholly a persistence-introduced bug: in-memory
the posture never changes mid-conversation.

**`model` is deliberately NOT pinned.** Although thinking-signature validity is nominally model-scoped,
**enforcing** the saved model is the riskiest and least-justified of the four overrides: if the saved
model was since deprovisioned/revoked from the gateway, every resumed turn would 400 with **no escape**.
Approach B records `model` for diagnostics only and does not enforce it; two independent lenses (cross-B
STEAL-1, ux SCOPE-2) flag pinning it. So A keeps `model` in `config_fingerprint` for **display/diagnostics
only** and runs resumed sessions against the reader's **live** model (§3.3/§16). Only the three
wire-shape toggles are overridden.

**The fix — honor the SAVED posture for the resumed session's lifetime.**

```lua
-- One read site for everything wire-shaping. The base is the live settings config; a restored
-- session overlays the posture it was saved under so the resent history stays self-consistent.
function Conversation:_effectiveConfig()
    local cfg = self.settings:getConfig()
    if self._thinking_override   ~= nil then cfg.enable_thinking   = self._thinking_override end
    if self._web_search_override ~= nil then cfg.enable_web_search = self._web_search_override end
    if self._memory_override     ~= nil then cfg.enable_memory     = self._memory_override end
    -- model is NOT overridden: a deprovisioned saved model would 400 every resumed turn with no escape
    -- (cross-B STEAL-1 / ux SCOPE-2). The resumed session always runs against the reader's LIVE model;
    -- config_fingerprint.model is display/diagnostics only (§3.3/§16). Only the three wire-shape toggles
    -- are pinned — enable_thinking/enable_web_search/enable_memory.
    return cfg
end
```

- `getConfig()` returns a fresh table each call (`bbsettings.lua:61-` builds and returns a new table),
  so mutating the overlay does not corrupt stored settings.
- **`_loop` reads `self:_effectiveConfig()`** instead of `self.settings:getConfig()` at
  `bbconversation.lua:274`. `enable_sessions` and every non-wire setting still come straight from the
  live config (the overlay touches only the **three** enforced fields —
  `enable_thinking`/`enable_web_search`/`enable_memory`; `model` is never overridden).
- **`_rebuildToolSpecs()`** factors the `new()` tool-spec assembly (`bbconversation.lua:176-208`:
  base specs, web_search drop when disabled, memory spec append) into a method that reads
  `_effectiveConfig()`. `new()` calls it (current behavior); `restore()` calls it again **after** the
  overrides are set so `tool_specs` matches the saved posture.
- **Memory STORE construction half (C12), not just the spec.** `_rebuildToolSpecs()` appends the memory
  **spec** when `_effectiveConfig().enable_memory` is true — but the spec alone is half the story. If
  memory was **ON at save but OFF in the live config now**, `new()` skipped **store** construction
  (`bbconversation.lua:203-208` runs only under the live `enable_memory`), so the resumed history's
  resent memory calls would have a spec but **no backing store to dispatch against**. `restore` must
  therefore rebuild `self.memory` from `Memory.baseDirForBook(self.ui)` exactly as `new()` does
  (`Memory.new(base)`, guarded on a resolvable `base`) whenever the effective posture re-enables memory
  and `self.memory` is still nil (§7.3). This is the **dispatch-correctness** half, orthogonal to the
  Step 5b spoiler-quarantine clause (§8.2). Uses the existing per-book `.sdr` memory sidecar — no global
  store.
- A **fresh** (non-resumed) chat sets no overrides → `_effectiveConfig()` is exactly the live config →
  zero behavior change.

**Both directions are covered:** OFF→ON resume keeps thinking OFF (no orphan thinking-before-tool_use
expectation; the saved history has none); ON→OFF resume keeps thinking ON so `body.thinking` is emitted
to match the resent thinking blocks.

**Absent fingerprint (Round 11 — the fallback that keeps "never 400" honest).** A hand-edited /
foreign / pre-fingerprint blob carries no `config_fingerprint`, and running it under the live config
reproduces exactly the 400 above. The thinking posture is inferable from the history itself: any
`thinking` block present ⇒ it was built thinking-ON; none ⇒ OFF. `restore` infers it, sets
`_thinking_override` accordingly, and logs the inference (§7.3). Only thinking is inferred — it is
the toggle with the hard `body.thinking` ↔ resent-blocks consistency requirement; web_search/memory
for fingerprint-less blobs follow the live config (resent web-search pairs are wire-legal whether or
not the tool is offered; the residual is instruction-level, disclosed in §3.3). So the "never 400 on
resend" guarantee holds for A-written blobs via the fingerprint, and for fingerprint-less blobs via
the inference — not by luck of the live toggle.

---

## 10. Migration & versioning

- `CURRENT_SCHEMA = 1`. Every file carries `schema_version`.
- **First run:** no prior format; nothing to migrate. The picker entry is hidden until `hasContent`.
- **Load of a different version:** `load` returns `nil` if `schema_version ~= 1` (or absent); `list`
  omits the file (header `schema_version` mismatch). **No migration chain, no disabled rows.**
- **Never auto-delete** unknown-version files (may be future versions still syncing).
- A future breaking change reintroduces migration only against a real installed base.

---

## 11. Error handling & corruption recovery (never crash the chat)

- **Partial write:** unique-tmp + **fdatasync-file (data only, not metadata — §6/§5.1)** + rename +
  fsync-dir, plus a one-shot parent-`.sdr` fsync on the first-ever save (STEAL-FAT-1). On **POSIX**
  filesystems power-loss leaves the previous good `.json` or the new one, never a torn file. On
  **FAT/exFAT** the rename-over-existing window means a power-loss can momentarily leave `final`
  missing/torn. A torn/NUL-filled tail (the real FAT shape) is rejected read-side by the NUL sentinel
  below.
- **Rename failure on FAT (rename-first + rollback, Round 8/Round 11):** the directory-entry table
  can be full or a FAT driver can EEXIST on rename-over-existing. `Session.save` (§5.1) tries
  `os.rename(tmp, final)` **directly first** (atomic replace-over on POSIX — Round 11; Round 8's
  unconditional remove-first destroyed that atomicity on every rapid-multi-turn save); **only on
  failure** does it (a) free the destination — `os.rename(final, bak)` (freshest `.bak`), else
  `os.remove(final)` — and retry (the unlink+rename window is confined to filesystems where
  rename-over was never atomic anyway); and (b) if the retry still fails after `final` was moved to
  `.bak`, `os.rename(bak, final)` to
  roll the live file back before erroring — so the session never silently disappears from
  the picker (which scans `*.json` only, ignoring `*.json.bak`). Without (b) the live `.json` (already
  renamed to `.bak` by the fallback) would be unlistable and recoverable only by explicit id.
- **FAT power-loss, whole-blob loss (persistent `.bak`, Round 5):** because A rewrites the entire file
  each terminal turn, a crash in the rename-over window — **or a hard power-off arbitrarily long after the
  last save** — could lose the **whole** chat. `Session.save` keeps a **persistent** `.bak`, refreshed
  from `final` only when `final` is >60s old (mirroring `LuaSettings:backup`'s freshness gate; a
  **copy** since Round 11, so `final` survives the refresh) and **never removed at the
  end of save**; `Session.load` falls back to `.bak` (same NUL sentinel + schema gate) when `final` is
  missing/torn. So a torn `final` from a prior interrupted save still has an OS-likely-flushed fallback —
  the whole conversation is never lost, without a journal (§6). A stale `*.json.bak` is ignored by `list`
  (not a `*.json`) and reaped by `Session.delete`/`prune`; stale `*.tmp` is reaped by `Session.prune`.
- **Torn / NUL-filled file (FAT read-side contract):** `Session.load` rejects raw bytes containing an
  embedded NUL (`raw:find("%z")`) **before** `decode` → returns `nil, "torn"`. The `readHeader`
  regex path (used for `> LIST_DECODE_CAP` files, which **skip** `decode`) applies the **same** NUL
  sentinel **and** requires a schema marker (`"schema_version"%s*:%s*1`) before trusting any extracted
  header field — otherwise a half-synced large blob could surface a ghost `title_snippet`/`updated`
  picker row that then fails on tap. A blob failing either check is omitted from `list`.
- **Missing / unsynced file:** `load` → `nil`; `resumeSession` shows an InfoMessage; `list` omits
  unreadable entries.
- **JSON parse failure / wrong shape:** NUL sentinel + `pcall`-guarded `decode` +
  `type(data.messages)=="table"` check → skip with a `logger.warn`; **never delete** (may still be
  syncing).
- **Unrestorable-but-decodable file:** a leading non-user message or interior alternation break that
  the self-healers don't repair → `restore` returns `nil, reason`; `resumeSession` shows "damaged"
  and keeps the live chat (§7.3/§9.3). **Never deleted.**
- **Null `usage` in a decodable file:** coerced via `numOr0` in `restore` (C4) — no crash in
  `_usageText`.
- **Book moved/renamed (`doc`/`dir` sidecar mode):** `DocSettings.updateLocation` copies only
  metadata, not subdirs (`docsettings.lua:433`; the metadata/cover copy body is `:441-463`). Sessions are **left as orphaned litter at the
  old `.sdr`** (the dir is non-empty, so `purge`'s empty-only `removeSidecarDir` can't remove it).
  Documented; `hash` mode follows the book. Parity with `bbmemory`. A "prune orphaned session dirs"
  affordance is future work, not v1.
- **`hash`-mode dir cost:** `getSidecarDir` calls `util.partialMD5` (a multi-MB read on cold cache).
  The cache is per-process and warms on first open; `dir(ui)` is cheap thereafter.
- **`dir(ui) == nil`** (no document / no resolvable sidecar): all entry points no-op; `_persist`
  skips; the picker menu entry is hidden.
- **Disk full / write error:** `save` → `false`; `_persist` logs and the chat continues
  (in-memory remains the source of truth).
- **`.sdr` deleted out from under a live chat:** next `_persist` recreates `bookbuddy_sessions/` via
  `makePath`; the chat is unaffected.

---

## 12. Concurrency & edge cases

- **Two devices via Syncthing:** distinct ids → union merge. The same session edited on both →
  last-writer-wins (atomic writes prevent torn files); Syncthing `.sync-conflict-*.json` copies are
  **filtered from `list`** — kept on disk for manual recovery, **but bounded (Round 11 decision):**
  the `Session.prune` sweep reaps any `.sync-conflict-*.json` older than **~30 days** (§5.1/§13);
  they are never counted toward, nor deleted by, the `session_keep` cap, and never reaped young. So
  a conflicted edit stays manually recoverable for a month instead of accumulating forever.
- **Same book open twice (one device):** `resumeSession` closes any live conversation first; fresh
  chats are distinct files; the same resumed session in two instances is LWW with atomic writes.
- **Power-loss mid-sync:** a peer may briefly pull a partial file → `list` skips it as corrupt → the
  chat transiently vanishes from the *other* device's picker until the good copy re-syncs. No
  corruption, no crash.
- **Syncthing partials & peer dirs are never touched by prune/list (Round 9):** the `prune` `.tmp`
  reaper only `os.remove`s files matching the plugin's own `<id>.<proc>.<rand>.tmp` shape (strict stem
  match required), so a Syncthing in-flight partial (`~syncthing~….tmp`, no matching stem) is left alone
  — we never corrupt another device's in-progress sync pull. Both `list` and `prune` call
  `util.findFiles(…, false)` with **`recursive=false`** (it defaults `true`, `frontend/util.lua:789`),
  so a Syncthing `.stversions/` or `.sync-conflict` directory in the `.sdr` is never descended into.
- **Very long sessions:** **no automatic pruning/compaction** (would alter wire history and risk
  alternation/pairing). The API cost of resending full history caps practical length first; if
  `serialize()` output is large, persistence still happens and the manage-chats UI offers manual
  delete. **No silent size cap** (a silent un-resumable tail is the worse failure). If real `.sdr`
  bloat is observed, add a *visible* "this chat is too long to save" notice later.
- **Empty/aborted sessions:** no clean `_render` → no file. Seed-only (pre-first-answer) state is not
  persisted; a crash during the very first turn loses it (accepted, documented gap).
- **Multi-book isolation:** each `.sdr` holds only its book's sessions; the §8 identity guard handles
  the pathological synced-into-wrong-book case.

---

## 13. Settings & rollout

- New key `enable_sessions = true` in `bbsettings.lua` `DEFAULTS` (**default-on**). Rationale: unlike
  memory (off by default because it *spends tokens* every turn), sessions cost **zero tokens** — only
  disk + Syncthing traffic. Surprising data loss is the worse default for a chat tool. Mitigated by
  an obvious "Save chats" toggle, the manage/clear UI, and living in the `.sdr` the reader already
  syncs.
- `getConfig` exposes `enable_sessions` (read by `_persist` and the menu gating).
- **Per-book retention (`session_keep`, default `20`).** A heavily-chatted book would otherwise grow an
  unbounded set of `*.json` blobs in its `.sdr` — each carrying the **full wire history** — a real
  footprint problem on a memory-constrained e-reader that also pays Syncthing traffic for every blob.
  After a successful write, `Session.save` calls `Session.prune(ui, keep)`, which reuses `Session.list`
  (already sorted `updated` desc, conflicts filtered) and `Session.delete`s everything past the newest
  `keep` (and `Session.delete` reaps the matching persistent `.bak`). **`prune` also sweeps stale
  staging litter (Round 5; age gate corrected Round 11):** a crashed save leaves a fresh-unique
  `<id>.<proc>.<rand>.tmp` that is never
  overwritten, so `prune` removes any plugin-shaped `*.tmp` **older than a few minutes — the age gate
  ALWAYS applies** (Round 11: the old "no live `.json` OR old" rule deleted a *young* first-save tmp,
  which is exactly the in-flight shape of a brand-new session — and, after a crash mid-first-save,
  can briefly be the only surviving copy). **And it reaps aged Syncthing conflict copies (Round 11):**
  any `.sync-conflict-*.json` older than ~30 days (§12), bounding `.sdr` / Syncthing litter without
  touching recent manual-recovery material. This is a **pure blob-model addition — no
  journal, no index.** A `session_keep < 1` disables the count cap (the `.tmp`/conflict sweeps still
  run). Pruning
  is best-effort (`pcall`-wrapped) and never fails the save.
- **Rollout:** the picker entry appears only when `Session.hasContent` is true, so existing users see
  nothing until a chat has auto-saved. No on-disk migration (no prior format).

---

## 14. Testing plan (Tier-1 busted + targeted Tier-2)

Reuse `tests/support/{stubs,sse}.lua` and the `tests/memory_spec.lua` temp-dir idiom.

**Tier-1 fs-shim contract (mirrors `memory_spec.lua`).** Tier-1 has **no KOReader frontend**:
`memory_spec.lua` only works because it **hand-rolls** fs shims and uses the system `lfs`, and the
stub `util` defines only `cleanupSelectedText`. So `bbsession_spec` must inject hand-rolled
`util` / `ffi-util` / `docsettings` shims with the **exact 5-arg** signature
`writeToFile(data, path, force_flush, lua_dofile_ready, directory_updated)` and **no-op** `fsync`
functions, and must also shim `splitToChars` and `partialMD5`. **Round 7 — `rapidjson.array` shim:**
the Tier-1 `rapidjson` stub (`tests/support/stubs.lua:234-247`) historically exposed only
`encode`/`decode`/`object`/`null`, so `tagArrays`'s `rapidjson.array({})` MT lookup (§9.0) was a nil
call that threw on every Tier-1 `serialize()` (swallowed by `_persist`'s pcall → silent save no-op;
the round-trip tests error inside `serialize()`). The stub now adds
`array = function(t) local r = t or {}; r.__array = true; return r end`, and `tagArrays` is
pcall-guarded so it still no-ops if `array` is ever absent (§9.0). The deep-equal baseline ignores
the resulting array-ness tag (value-equality, metatable-blind — see the baseline note below).
Consequence: `force_flush →
fsyncOpenedFile` and `fsyncDirectory` **cannot actually run** in Tier-1 — a shim no-ops them, so a
durability assertion would prove nothing. The **fs-actually-called durability assertion is therefore
NOT Tier-1** (it is a code-review invariant or a Tier-2 check). The **tmp-ignored-by-`list`** and
**rename-to-final** behaviors ARE Tier-1-testable with the shims; `fsync` is not.

### `tests/bbsession_spec.lua` (real temp dir, hand-rolled shims per the contract above)

- `save` → `load` deep-equals (messages / transcript / usage / anchor / meta / `config_fingerprint` /
  `seed` / `loc_seq`). **Baseline pin (Round 3):** the round-trip contract is **`load(save(serialize()))` deep-equals
  `serialize()`** — i.e. compare the restored-from-disk blob against `serialize()`'s **output** (post
  cache_control-strip, post input-coercion, post signatureless-thinking-drop, post `max_referenced_page`
  merge), **NOT** against the live `self.messages`. `serialize()` legitimately diverges from the live
  array (a zero-arg `tool_use` gains `input = rapidjson.object({})`; a signatureless `thinking` is
  dropped and may roll back a tool round; `max_referenced_page` is merged onto the deep copy), so a
  deep-equal against live `self.messages` would spuriously fail. Compare against `serialize()`.
  **Value-equality, metatable-blind (Round 7):** the deep-equal helper compares **values only** — it
  **ignores metatables AND the stub's `__array` marker key**. `tagArrays` (§9.0) sets the rapidjson
  array metatable on the serialize side (or the stub's `__array` field under Tier-1, since the Tier-1
  stub's `array` shim tags via a plain key, not a metatable), while the decoded side carries the stub
  decoder's own array marker; an MT-/marker-sensitive comparison would spuriously diverge. So the
  helper recurses on keys/values, skips a key named `__array`, and never consults `getmetatable`.
- **tmp ignored / rename-to-final (Tier-1):** after `save`, the dir holds exactly one `<id>.json` and
  no `*.tmp`; a stray unique `*.tmp` planted in the dir is ignored by `list` (only `.json` lists).
  (The fsync-on-disk durability assertion is **out of Tier-1** — shims no-op fsync.)
- `list` sorts by `updated` desc; corrupt / invalid `.json` skipped (not fatal);
  `.sync-conflict-*.json` **excluded**.
- `load` of `schema_version = 999` returns `nil` and `list` omits it (no disabled-row machinery).
- **Torn / NUL blob (read-side contract):** a NUL-padded or truncated `.json` → `load` returns `nil`
  (no crash); a NUL-tail file **> `LIST_DECODE_CAP`** → `list` omits it (regex path NUL sentinel +
  required schema marker).
- **`.bak` power-loss fallback (FAT durability):** save once, then plant a torn/missing `final`
  (`<id>.json`) while a valid `<id>.json.bak` is present → `load` returns the `.bak` contents (same NUL
  sentinel + schema gate); a `*.json.bak` is **not** listed by `list`. (Bounds loss to one turn, §6.)
- **Rename failure rolls the live file back from `.bak` (Round 8/Round 11, §5.1/§6/§11):** save once
  (creates `<id>.json`); stub `os.rename` so the **direct** `tmp → final` rename fails (FAT-EEXIST
  shim) AND the retry after the fallback `final → bak` move also fails; save again → assert `save`
  (a) returns `false`, (b) removed the
  `.tmp`, and **(c) restored `<id>.json` from `<id>.json.bak`** (`os.rename(bak, final)` ran), so a
  subsequent `Session.list` **still shows the row** (it was not silently lost). Without the rollback,
  `list` would omit it (scans `*.json` only) — pins the unlistable-session loss is closed.
- **Rename-first: no remove on the happy path (Round 11, §5.1/§6):** save once, then save
  again **immediately** (final < 60s old) with recording `os.remove`/`os.rename` stubs; assert the
  second save called `os.rename(tmp, final)` **directly over the existing destination** and
  `os.remove(final)` was **never** called (the atomic replace-over path — no unlink window on
  POSIX), and exactly one `<id>.json` remains with the new contents. Then repeat on a shim whose
  `os.rename` **rejects** rename-over-existing (the FAT-EEXIST case): assert the save fell back —
  freed the destination (`final → bak` move, else remove), retried, succeeded — and exactly one
  `<id>.json` remains.
- **`.bak` refresh is a COPY, not a move (Round 11, §5.1/§6):** save once, back-date `<id>.json` past
  60s, save again → assert the freshness gate produced `<id>.json.bak` with the prior contents
  **while `<id>.json` still existed at rename time** (the direct rename found a destination to
  atomically replace — e.g. assert via the recording stub that no `final → bak` rename ran on the
  happy path, only `ffiUtil.copyFile`).
- **First-write parent-dir fsync (Round 8, STEAL-FAT-1, code-review/Tier-2 — shims no-op fsync):** the
  first-ever `save` (no pre-existing `bookbuddy_sessions/`) calls `ffiUtil.fsyncDirectory` on the
  **parent `.sdr`** (the `DocSettings:getSidecarDir(file)` dir) exactly once, after `makePath` and
  before the file is written; a second save (subdir already exists) does **not** re-fsync the parent.
  (Like the other fsync assertions this is **out of Tier-1** — the shim no-ops `fsyncDirectory`; assert
  it as a code-review invariant or via a Tier-2 recording stub.)
- **Persistent `.bak` is NOT removed after save, refreshed only past 60s (Round 5):** save once
  (creates `<id>.json`, no `.bak` yet since there was no prior final); back-date the `<id>.json` mtime to
  > 60s ago, then save again → assert a `<id>.json.bak` now **exists** and is the prior contents (the 60s
  freshness gate fired). Then save a third time **immediately** (final < 60s old) → assert `.bak` is
  **not** refreshed (still the older copy), proving the gate only backs up a likely-already-sync'ed final.
- **Power-off-after-close recovery from a stale `.bak` (Round 5, the real failure mode §1/§6):** save,
  back-date the final past 60s, save again so a persistent `<id>.json.bak` exists; simulate a hard
  power-off DURING a later interrupted save by leaving a **torn** `<id>.json` (NUL tail) with the intact
  older `.bak` still present → assert `load` recovers the chat from `.bak` (NUL sentinel + schema gate),
  proving the whole conversation is not lost when the crash is arbitrarily long after the last good save.
- **`delete`/`prune` reap `.bak` and stale `.tmp` — age gate ALWAYS applies (Round 5/Round 11):**
  after a save that left a `<id>.json.bak`,
  `Session.delete(ui, id)` removes both `<id>.json` **and** `<id>.json.bak`. Plant (a) a **stale**
  (> ~3 min) `<id>.<proc>.<rand>.tmp` whose `<id>.json` stem is absent, (b) a stale `.tmp` for a
  live `<id>`, (c) a **fresh** `.tmp` for a live `<id>`, and **(d) a fresh `.tmp` whose `<id>.json`
  does NOT exist** (the in-flight shape of a brand-new session's FIRST save) → `Session.prune`
  removes (a) and (b), and **leaves (c) AND (d)** — Round 11: the age gate is AND, not OR; a young
  tmp is never deleted even without a live `.json` (post-crash it can briefly be the only surviving
  copy).
- **Aged sync-conflict copies reaped, young ones kept (Round 11, §12/§13):** plant a
  `.sync-conflict-*.json` back-dated > 30 days and a recent one → `Session.prune` removes only the
  aged one; neither is ever counted toward, nor deleted by, the `session_keep` cap; `list` excludes
  both throughout.
- `delete` / `clear` / `hasContent` behave; `dir(ui)==nil` → all entry points no-op.
- **Header-cap path:** a file > `LIST_DECODE_CAP` with a valid schema marker is listed via the regex
  header scan (`title_snippet` still shown), not a full decode.
- `id` with a path separator (`"../evil"`) is rejected by `load`/`delete` (no traversal).
- **Retention prune (§13):** write `keep + 3` distinct sessions with ascending `updated`, then `save`
  with `keep` (or call `Session.prune(ui, keep)`); assert exactly the newest `keep` `*.json` survive and
  the oldest 3 are deleted (oldest-by-`updated`). A `keep < 1` disables pruning (all survive). A
  `.sync-conflict-*.json` is never counted toward, nor deleted by, the cap.
- **Per-row delete is confirmation-gated (UI, Round 4):** the manage-chats per-row Delete action does
  **not** call `Session.delete` directly — it raises a `ConfirmBox` whose `ok_callback` deletes (matching
  bbmemory's destructive-op pattern). Asserted at the UI/code-review level (the destructive per-row
  action requires confirmation); the underlying `Session.delete(id)` removal is covered by the
  `delete`/`clear` Tier-1 test above.

### `tests/session_resume_spec.lua` (reuse `sse.new_fake_stream`, `capture_build_body`)

- Scripted multi-turn (grep tool_use → tool_result → text), `serialize()`, `restore`, deep-equal on
  `messages` **after asserting `serialize()` stripped `cache_control`** (run a `buildBody` first so a
  stale breakpoint exists, then serialize, then assert no block has `cache_control`; C1).
  **Round 10 — pin a string-content interior user turn:** the scripted history MUST include at least one
  **interior follow-up user turn whose `content` is a plain STRING** (not a block array) — the real shape
  for every follow-up before `buildBody` rewrites only the LAST message (`bbconversation.lua:254/256`,
  `bbanthropic.lua:73-76`). This exercises the `type(content) ~= "table"` short-circuit in
  `coerceToolResultContent` / `coerceToolUseInput` / `dropSignaturelessThinking` / `mergeReferencedPages`
  (§9.1), proving the block-order walk does not misclassify a string-content user turn as an empty/orphan
  block list, and that the turn round-trips byte-for-byte as a string.
- **`serialize()` does NOT truncate the transcript (C7):** build a conversation with a tool round
  whose `_clean_transcript_len` is pinned at chain start, serialize, assert the persisted transcript
  still contains the tool line **and** the final answer.
- **`validateMessages` passes** on the restored array (incl. a thinking+tool_use turn and a
  web-search turn): `#errs == 0`.
- **Pair-then-drop order (C8):** restore a `messages[]` whose final assistant turn carries an orphan
  `server_tool_use`; assert the answer is **kept** (paired), not dropped.
- **Dangling-tail self-heal:** a tail dangling client `tool_use` with no `tool_result` is trimmed;
  `validateMessages` passes.
- **Reverse-orphan web-search heal (Round 4):** restore a `messages[]` carrying a **non-tail** assistant
  message with a `web_search_tool_result` whose `server_tool_use` id is **absent** in that message
  (Syncthing-merge / hand-edit artifact); assert `restore` **succeeds** (not refused), the orphan block
  was dropped, and `validateMessages` passes (`#errs == 0`) on the first `buildBody` — mirroring
  Approach C's journal web-search case.
- **Reverse-orphan removal does not leave empty content (Round 5, §7.3; Round 6 — pin the setup):**
  restore a `messages[]` whose interior assistant message contains **only** a reverse-orphan
  `web_search_tool_result` (its `server_tool_use` id absent in that message), **surrounded by `user`
  messages** (`[user seed, assistant(reverse-orphan-only), user follow-up, assistant text]`) so the
  placeholdered turn is **not adjacent to another assistant**; assert the removal does not leave
  `content == {}` — the message is **placeholdered** with `{type="text", text="(no response)"}` — and
  `validateMessages` passes (`#errs == 0`) with no empty-content turn that would 400 on resend.
  **Belt-only counter-case (Round 6):** the **same** reverse-orphan-only assistant placed **adjacent to
  another assistant** (`[user, assistant(text), assistant(reverse-orphan-only), …]`) is **refused** by
  the interior-alternation check (`restore` returns `nil`) — the placeholder does not rescue an
  adjacent-assistant file; interior alternation is not self-healed (§9.3/§11).
- **Leading-non-user refusal (C-firstmsg):** a `messages[]` that begins with an `assistant` message
  (lost user seed) → `restore` returns `nil` (unrestorable), does not crash.
- **Interior-alternation refusal:** a `messages[]` with two consecutive same-role messages (merge
  artifact) → `restore` returns `nil`; documented as NOT self-healed.
- **usage coercion + non-table guard (C4/C-usage):** a stored `usage.input = json.null` restores as
  `0`; a stored `usage = 0` (a **number**) restores without "index a number value" (table-ness guard);
  `_usageText` does not throw in either case.
- **Absent `tool_use.input` coerced (C3, shape-level):** a serialized zero-arg `tool_use` block with
  **no `input` field** comes out of `serialize()` with `input` present (empty object). (Object-vs-array
  proof is Tier-2; this asserts the field is no longer absent.)
- **Signatureless thinking dropped:** a `thinking` block with `signature = nil`/`""` is **absent** from
  `serialize()` output; a signed one survives and `validateMessages` still passes.
- **Signatureless-thinking-only message dropped, not persisted as empty content (§9.1, Round 4):**
  serialize a history whose assistant message is `[thinking(no sig)]` **standalone** (no `text`, no
  `tool_use`); assert the message is **absent** from `serialize()` output (removed, with its paired
  `[user tool_result]` if any rolled back) — **not** persisted as `{role="assistant", content={}}` — and
  the resulting array validates (`validateMessages` clean, no empty-content turn that would 400 on
  resend).
- **Signatureless thinking sharing a tool_use turn rolls back (§9.1 CRITICAL, Round 3):** serialize a
  history of `[assistant: thinking(no sig), tool_use]` + `[user: tool_result]` + `[assistant: text]`
  while **thinking is ON**; assert the restored history (a) **validates**, and (b) has **no `tool_use`
  in a message lacking a preceding signed `thinking`** — i.e. the orphaned tool round was rolled back to
  the last clean assistant turn (not left as a bare `[tool_use]` that would 400 on resume with
  `body.thinking` emitted). (`validateMessages` does NOT catch thinking-before-tool_use, so this asserts
  the rolled-back shape directly.)
- **Serialize-side rollback does not desync the persisted transcript (§9.1/§7.3, Round 4):** serialize a
  history of `[assistant: thinking(no sig), tool_use]` + `[user: tool_result]` + `[assistant: text]`
  with **thinking ON**; the rollback shortens `messages[]` but `serialize()` persists the full transcript.
  `restore` the blob; assert the unconditional `_syncTranscriptToMessages` trimmed `self.transcript` so it
  no longer retains the rolled-back tool line/answer — i.e. `_render` shows no turn absent from the
  surviving `messages[]` (the short-`messages`/long-`transcript` desync is healed even though restore's
  OWN `_dropDanglingTail` removed nothing).
- **`max_referenced_page` never on the live wire block (§5.2/§3.3, Round 3):** after a grep/read tool
  round, assert **no** `tool_result` block in **`self.messages`** carries `max_referenced_page` (it lives
  only in `self._mrp_by_tool_use_id`); then assert `serialize()`'s output **does** carry it on the
  matching `tool_result` (merged onto the deep copy by `mergeReferencedPages`). Guards the
  "400 on every multi-turn tool chat" regression.
- **`web_search_tool_result` content not coerced:** a block whose `content` is the error **OBJECT**
  `{type="web_search_tool_result_error", error_code=…}` round-trips with the table intact (not
  flattened to `""`).
- **Non-string client `tool_result.content` coerced (Round 6, §9.1):** serialize (or restore) a
  `messages[]` carrying a **client** `tool_result` whose `content` is a **number** (e.g. `0`) and one
  whose `content` is an **arbitrary table** (not a content-block array) — the foreign/hand-edited/synced
  shape; assert `coerceToolResultContent` (serialize-side) / `_normalizeToolInputs` belt (load-side)
  coerced each to a legal client shape (`tostring(...)` / `""`), so the resent block is a string and
  cannot 400 the real API. A `web_search_tool_result` with a table content is **left untouched** (still
  excluded).
- **config_fingerprint posture re-assert (C1/§9.6):** serialize a **thinking-ON** session; flip the
  live setting to thinking-**OFF**; `restore`; assert `conv:_effectiveConfig().enable_thinking == true`
  **and** a captured `buildBody` emits `body.thinking`, **and** the restored history validates. Then
  the **reverse**: thinking-**OFF** session, live ON, restore → `_effectiveConfig().enable_thinking ==
  false` and `buildBody` omits `body.thinking`.
- **Re-saved fingerprint follows the EFFECTIVE posture, not the live one (§9.1, Round 4):** serialize a
  **thinking-ON** session; set the **live** setting to thinking-**OFF**; `restore`; **re-serialize** the
  restored chat; assert the re-saved `config_fingerprint.enable_thinking == true` (matches the resumed
  history's thinking blocks, NOT the live OFF). Then `restore` that twice-resumed blob and assert a
  captured `buildBody` emits `body.thinking` **and** validates — proving a chain of resumes does not
  drift back into the R1 thinking-400 by re-saving the live fingerprint.
- **Resume continues:** after restore, `ask("follow up")` appends a **plain user message** (not a
  re-seed); `buildBody` resends the full restored history (via `capture_build_body`).
- **Empty-history re-seed from `data.seed` (§3.1/§7.3, Round 3):** restore a file whose only assistant
  content was an **orphan `server_tool_use`** that `_dropDanglingTail` removes, leaving
  `#self.messages == 0`; assert `self.selected_text`/`self.note` were restored from `data.seed`, so the
  next `ask()` takes the seed branch and re-seeds at the live position **with the original highlight**
  (not contextless). With `data.seed` absent, the seed branch re-seeds without it (no crash).
  **Round 11 — the field survives re-saves:** restore a NON-empty-history blob carrying `data.seed`,
  re-serialize, and assert the re-saved blob still carries `seed` (restore rehydrates
  `selected_text`/`note` unconditionally; no generation-2 decay).
- **Taint survives a save generation (Round 11, §7.3/§9.1/§3.3 — the generation-2 rewind leak):**
  serialize a session whose `tool_result` carries `max_referenced_page = SPOILER_SENTINEL` (a
  spoiler read) at p.500; **resume FORWARD** at p.520 (no redaction), `ask()` one question, and let
  the terminal save re-write the blob. Assert the **re-saved** blob's matching `tool_result` still
  carries the sentinel (restore's taint harvest fed `_mrp_by_tool_use_id` before Step 7b stripped
  the decoded blocks; `mergeReferencedPages` re-emitted it). Then **resume that re-saved blob
  BACKWARD** at p.100: assert `assessResume` reports `tainted == true` (the dialog fires) and Step 7
  redacts the block — pins that the rewind-with-prior-consent protection does not decay after one
  resume→ask→save cycle.
- **Absent `config_fingerprint` infers the thinking posture (Round 11, §7.3/§9.6):** restore a blob
  with **no** `config_fingerprint` whose history carries signed `thinking` blocks, with the **live**
  setting thinking-**OFF**; assert `conv:_effectiveConfig().enable_thinking == true` and a captured
  `buildBody` emits `body.thinking` (inference from block presence). Conversely a fingerprint-less
  blob with **no** thinking blocks under live thinking-**ON** → `enable_thinking == false`,
  `buildBody` omits `body.thinking`.
- **Locator mint counter restored (Round 11, §3.1/§7.3/§8.3 LEAK-4):** serialize a session whose
  live `ui._bookbuddy_loc_seq` is 7 (blob carries `loc_seq = 7`); `restore` on a ui whose live seq
  is 2 → assert `ui._bookbuddy_loc_seq == 7` (max of live/stored), the locator TABLE is empty
  (entries never restored), and a subsequent grep mints `loc:8` — never re-minting a `loc:N ≤ 7`
  that stale tokens in the restored history could name. A blob with no `loc_seq` (pre-Round-11)
  restores with the live seq unchanged (no crash).
- **Refused/cancelled resume leaves the live chat's scratch intact (Round 11, §7.3):** with a live
  conversation whose `ui._bookbuddy_locators` holds entries, call `resumeSession` on (a) a blob that
  fails the identity guard, (b) a blob whose `currentPage` stub is nil (Step 0.5 refusal via
  `assessResume`), and (c) a tainted blob whose ConfirmBox is **cancelled**; in all three cases
  assert **no** `Conversation.restore`/`Conversation:new` ran and `ui._bookbuddy_locators` /
  `_bookbuddy_loc_seq` / `_bookbuddy_last_search` are **unchanged** (the pure pre-flight constructs
  nothing). Only the committed path (Resume hidden / Reveal everything / untainted) constructs the
  conv and clears scratch.
- **Transcript resync on tail-drop (§7.3, Round 3):** restore a file whose transcript is **longer** than
  the resendable history after `_dropDanglingTail` removes a wire message (Syncthing-merged dangling
  tail); assert `_syncTranscriptToMessages` trimmed `self.transcript` back to the surviving last
  assistant turn (no orphaned trailing transcript turn that `_render` would show but `messages` lacks).
- **Load-side input normalization (§9.2, Round 3):** restore a **foreign-written** blob whose
  `tool_use.input` is a bare `{}` (not the rapidjson object sentinel); assert `_normalizeToolInputs`
  forced it to `rapidjson.object({})` so a subsequent `buildBody` resend cannot 400 (proven against real
  rapidjson in Tier-2; Tier-1 asserts the field was replaced with the sentinel).
- **Memory store rebuilt when posture re-enables memory (§9.6/C12, Round 3):** serialize a
  **memory-ON** session; with the **live** config memory **OFF**, `restore`; assert
  `conv:_effectiveConfig().enable_memory == true`, `conv.memory ~= nil` (store rebuilt from
  `Memory.baseDirForBook`), and the memory **spec** is present in `tool_specs` — so a resent memory call
  has a backing store to dispatch against.
- **model is NOT enforced (§9.6/§16, Round 3):** serialize a session whose `config_fingerprint.model`
  differs from the live model; `restore`; assert `conv:_effectiveConfig().model == <live model>` (the
  saved model is **not** applied) and no `_model_override` field exists.
- **`_isResumableState` rejects orphan-server_tool_use tail (§7.3, Round 3):** a live conversation whose
  last assistant message carries an **orphan `server_tool_use`** (paired result missing) →
  `_isResumableState()` returns **false** (reuses the exact `_dropDanglingTail` danglingness test), so
  `resumeSession` refuses to replace it; a clean terminal assistant turn → true.
- **Resume banner survives the streaming-viewer rebuild, in the TITLE string (§7.1/§8.2 Step 6, Round 4
  / Round 5):** after a resume that armed `self._resume_banner` (e.g. `"resumed · now at p.100 (spoilers
  reset)"`), `_render` builds the viewer with `title == T(_("BookBuddy — %1"), self._resume_banner)`; then
  trigger `_ensureStreamingViewer` (the Reply path rebuild) and assert the rebuilt viewer's **title
  string** still carries the reset notice (the banner is folded into the title at all three build sites,
  not a subtitle slot — `TextViewer` forwards no `subtitle`) — it does **not** revert to the plain
  `_("BookBuddy")` title. A fresh (non-resumed) chat with `_resume_banner == nil` builds with the plain
  `_("BookBuddy")` title (zero change).
- **`self.conversation` is wired so the guards see the live chat (Round 5, §5.3/§7.3, UI):** after a chat
  is started (the `Conversation:new` site, `main.lua:166`), assert `self.conversation` is **non-nil**
  (the conversation is stored on `self`, not just a function-local). Then: (a) `onCloseDocument` with a
  resumable live conversation calls `conv:_persist()` (a file is written) — proving the close-flush is not
  dead code; (b) `resumeSession` with a live conversation present invokes the mid-turn guard / closes the
  live chat and reassigns `self.conversation` to the restored conv (no two live conversations); (c) on
  viewer close `self.conversation` is nulled. (Currently untested — which is why the close-flush +
  resume-replace data-loss story slipped four rounds; this test pins the single wiring step.)
- **`_persist` self-guards on `_isResumableState` (STEAL-1, Round 9, §5.2):** call `conv:_persist()`
  **directly** on a conversation whose live history is at a **dangling/mid-turn** boundary (e.g. a
  trailing `tool_use` with no `tool_result`, the `_isResumableState()==false` shape from the
  orphan-tail test); assert **no file is written** (`Session.list` unchanged) — i.e. `_persist` refuses
  the dangling tail even when invoked outside the four pinned terminal sites, so the call sites are
  scheduling hints, not correctness-load-bearing.
- **`_persist` skips an unmodified resumed session and keeps its saved anchor (STEAL-2, Round 9, §5.2):**
  save a session at p.300 (record its `anchor.xpointer`), then `restore` it and **resume backward** to
  p.100 **without** asking a question (so `_dirty` stays `false`); call `conv:_persist()` (or trigger
  `onCloseDocument`) and assert (a) the on-disk blob's `anchor.xpointer` is **unchanged** (the originally
  saved p.300 anchor — NOT re-snapshotted to the rewound p.100), and (b) `updated` is unchanged (no
  re-write). Then `ask()` one question (flips `_dirty=true`), `_persist`, and assert the blob **is** now
  re-written (`_dirty` was the gate). Pair: after a successful `Session.save`, assert `_dirty` is cleared
  back to `false`. **Round 11 — a FAILED save leaves `_dirty` true:** stub `Session.save` to return
  `false` (disk full), `_persist`, assert `_dirty` is **still true**; un-stub, `_persist` again (or
  trigger `onCloseDocument`) and assert the write now lands — pins that `_persist` checks the save's
  return and the close flush genuinely retries a previously failed terminal save (§5.2/§5.3).
- **Picker omits the current session row (Round 6, §7.2, UI):** with a live `self.conversation` whose
  `_session_id` matches one of the saved sessions on this book, `showResumePicker` builds an
  `item_table` that **excludes** that session's row (one `_session_id` compare), so the chat the reader
  is currently viewing is not a tappable self-restore row. With no live conversation (or a non-matching
  id), all rows are present.
- **Primary entry shows Continue-or-New only when a resumable session exists (Round 8, §5.3, UI):**
  with `enable_sessions` ON and `Session.hasContent(self.ui)` **true**, tapping the primary "Chat about
  this book" callback shows a `ConfirmBox` (`showContinueOrNew`) whose "Continue last chat" action calls
  `resumeSession(Session.list(self.ui)[1].id)` (the newest-first first row) and whose "Start new chat"
  action calls `promptAndStart(nil)`. With `enable_sessions` **off**, OR `Session.hasContent` **false**
  (no sessions for this book), the same callback falls **straight through** to `promptAndStart(nil)` —
  **no** `ConfirmBox` shown (zero behavior change). This pins that the familiar primary entry no longer
  silently forks a forgotten parallel session.
- **Picker row leads with turn_count and disambiguates same-sitting chats (Round 7, §7.1/§7.2, UI):**
  build two sessions with **identical `title_snippet`** and **identical `anchor.page_at_save`** (the
  "asked twice in one sitting" case — the reader did not move), one with `turn_count = 2` and one with
  `turn_count = 14`; assert `showResumePicker`'s `item_table` rows have **distinguishable** `mandatory`
  strings (the leading `"<n> turns"` differs: `"2 turns · …"` vs `"14 turns · …"`), and that **neither
  `mandatory` contains `page_at_save`** (the reflow-dependent, within-sitting-constant page number is
  dropped from the row). A row with an absent/old `turn_count` falls back to `0 turns` (no crash).
- **Resume-while-mid-turn guard (UX, §7.3):** with a live conversation at a non-terminal state
  (seed-only, or last message `role=="user"`), `resumeSession` is refused
  (`_isResumableState()==false`) — the live chat is untouched and the "Finish or close the current
  chat first." message is shown; at a terminal state the resume proceeds and closes the live chat.
- **pause_turn turn:** a single assistant message with extended content (interleaved
  server_tool_use/web_search_tool_result) round-trips and validates.

### `tests/session_spoiler_spec.lua` (the real threat, not just the string rewrite)

- **Nil live position fail-closed (Step 0.5 / LEAK-0):** stub `currentPage → nil`;
  `_reanchorPosition` returns `ok==false` with the "Reading position unavailable" reason, **arms no
  marker** (`self._resume_note` stays nil), and does not restore. (Pairs with the `bbtools` gate fact
  that a nil `cur` bypasses both the start-page refusal and the forward clamp.)
- **Table-content seed re-anchor (C1):** seed is a `{type=text}` block array (post-buildBody); stub
  `currentPage→300`, `getXPointer`/`getPageFromXPointer`/`compareXPointers`; `_reanchorPosition`
  rewrites the book_context block to "Current page: 300" and the post-condition passes.
- **Rewrite-no-op fail-closed (DRIFT-1):** feed a seed where the book_context block is absent; assert
  `_reanchorPosition` does **not** silently keep a stale boundary — the authoritative
  `<resume_context>` marker is still armed for the next `ask`.
- **Forward over-block fix (FALSE-BLOCK-1):** `compareXPointers(stored, live)→1` (live after stored ⇒
  forward), current 300; assert the armed resume marker tells the model `max_page=300`.
- **Rewind leak fix (LEAK-1/2):** `data.spoiler_consent=true`, `compareXPointers(stored, live)→ -1`
  (live before stored ⇒ backward), current 100; assert `self._spoiler_consent` is reset to `false`
  **and** the marker forbids `spoiler=true` and sets boundary 100.
- **Transcript scrubbed on rewind via the id/turn mapping, shares the wire stub (Round 6/7, §7.3/§8.2
  Step 7):** restore a `messages[]` + `transcript[]` where a `tool` line (e.g. a `read p.300` summary,
  whose persisted `tool` entry carries `_tool_use_id`) and the following `assistant` answer have backing
  wire blocks with `max_referenced_page > cur_page`; on a backward resume to a lower page, assert
  (a) the wire blocks are redacted to the stub (as the LEAK-5 test), **(b) the rendered `transcript[]`
  `tool` entry whose `_tool_use_id` is in `redacted_ids` now carries the SAME redaction stub**
  (`REDACTION_STUB`) — keyed by id (Rule 1), and **(c) the trailing `assistant` answer line of that same
  redacted turn is ALSO scrubbed** to the stub (Rule 2 — it has no `tool_use_id`, so it is redacted by
  turn). Assert the original future-page summary **and** the original future-page answer text are gone
  from the rendered transcript — i.e. the screen and the wire match. On a forward/same resume the
  transcript lines are left intact. (Pins that the scrub is **not** dead code: a `tool` entry whose id
  is **not** in `redacted_ids` is left intact, and — provided at least one OTHER line matched Rule 1 —
  a `tool` entry with **no** `_tool_use_id` is left intact too.) **Round 11 — untagged-blob
  fallback:** the same rewind against a blob whose `tool` entries carry **no** `_tool_use_id` at all
  (foreign/pre-tagging) → Rule 1 matches nothing, and assert the **entire transcript** is replaced
  with the single placeholder line `"[Earlier discussion hidden — it referenced parts of the book
  ahead of your current position.]"` (wire redacted ⇒ screen never shows what the wire hides).
- **Consent-revoked resume raises the one-shot InfoMessage (Round 6, §8.2 Step 6):** on a backward resume
  whose `data.spoiler_consent` was `true`, assert an `InfoMessage` is **shown** carrying the spoiler-reset
  text (in addition to the title banner), and that it is a **one-shot** (a second `_render` does not
  re-show it — `_resume_notice_shown` guard). On a forward/same resume, or a resume with no prior consent,
  assert **no** such `InfoMessage` is shown.
- **"Reveal everything" resume does NOT claim "(spoilers reset)" (Round 10, §8.2 Step 3/Step 6):** on a
  backward resume whose `data.spoiler_consent` was `true` **and** `conv._reveal_all = true` (the reader
  tapped "Reveal everything"), assert (a) the title banner contains `" (showing everything)"` and **does
  NOT contain `"(spoilers reset)"`**, and (b) **no** spoiler-reset `InfoMessage` is shown — even though
  `_resume_consent_reset` is set, because both UX surfaces gate on `_resume_consent_reset and not
  _reveal_all`. (Pins that the title-tail/popup track the reader's actual choice, not just the
  consent-was-revoked flag.)
- **In-history redaction on rewind (LEAK-5), single sentinel channel:** a restored `messages[]` with a
  `tool_result` carrying `max_referenced_page = 250` **and** one carrying `max_referenced_page =
  SPOILER_SENTINEL` (the persisted spoiler-read marker — there is **no** unpersisted spoiler flag); on a
  backward resume to page 100, assert **both** `tool_result.content`s are **replaced with the redaction
  stub** via the single `> cur_page` predicate, the `max_referenced_page` annotation is **stripped from
  all** surviving `tool_result` blocks (the unconditional Step 7b pass), and `validateMessages` still
  passes. On a **forward** resume nothing is redacted **but the strip still runs** (assert no surviving
  block carries `max_referenced_page` so a forward resume's first `buildBody` cannot 400).
- **`book_context` result redacted on backward resume (LEAK-8, §5.2/Step 7, Round 4):** after a
  `book_context` tool round (its tool_result annotated with `max_referenced_page` = the live page at
  dispatch), serialize + restore; on a **backward** resume to a lower page, assert the `book_context`
  tool_result content is replaced with the redaction stub (the chapter-title/`Current page` line no
  longer re-quotable), the `max_referenced_page` annotation is stripped from all surviving blocks (Step
  7b), and `validateMessages` passes. On a forward/same resume it is left intact.
- **Seed `book_context` chapter title scrubbed on rewind — SPAN-BOUNDED (Round 6/Round 11, §8.2
  Step 7 / LEAK-8):** build a seed as **one** text block (the real shape, §3.1) whose
  `<book_context>` span contains `"Current page: 300 of 610"` **and**
  `"Current chapter: Chapter 30: Ahab's Death"` (a future chapter), **and whose
  `<highlighted_passage>` text — in the SAME block — itself contains the literal lines
  `"Current chapter: The Whale"` and `"Current page: 9 of 9"`** (Round 11); on a **backward** resume
  to a lower page, assert (a) the `<book_context>` span's `"Current chapter:"` line is **stripped**
  and its `"Current page:"` line re-anchored to the live page — even when Step 2's post-condition
  fails open (feed a malformed seed so Step 2 bails) — **and (b) the passage's own
  `"Current chapter:"`/`"Current page:"` lines are byte-for-byte UNTOUCHED** (the surgery is
  span-bounded; patterns never run outside `<book_context>…</book_context>`). On a forward/same
  resume the seed chapter line is left intact.
- **Foreign `book_context` `tool_result` with NO annotation scrubbed on rewind (Round 6, §8.2 Step 7 /
  LEAK-8 channel 3):** restore a `messages[]` carrying a `book_context`-shaped `tool_result`
  (`"Current page: 300 of 610\nCurrent chapter: …"`) with **no** `max_referenced_page` (older-A /
  foreign / hand-edited blob); on a backward resume to a lower page, assert the block is **redacted
  anyway** by the shape-match fail-safe and `validateMessages` passes. On forward/same it is left intact.
  **Round 9 — unknown-page case:** restore a foreign block whose content is `"Current page: ? of 610"`
  with **no `"Current chapter:"` line** and **no** `max_referenced_page`; on a backward resume, assert
  the `[%w?]+` page-shape arm still **redacts** it (a `%d+` arm would have missed the literal `"?"`).
- **Web-search result redacted on backward resume (LEAK-7, Step 7, Round 4):** a restored `messages[]`
  containing a `web_search_tool_result` block (string or error-object content); on a **backward** resume
  to a lower page, assert the block's `content` is replaced with the **error OBJECT**
  `{type="web_search_tool_result_error", error_code="unavailable"}` (NOT a string stub —
  `web_search_tool_result.content` is never a string on the wire, §3.3/§9.1; a string would 400 the
  real API), its `tool_use_id`/`type` are preserved, and `validateMessages` still passes (`#errs == 0`).
  On a
  **forward/same** resume the web-search content is **left intact** (the reader moved past the saved
  position). Also assert the armed `_resume_note` carries the Step 5c web-search-quarantine clause on the
  backward case and omits it on forward/same.
- **Web-search-ONLY turn scrubs both the search summary AND the answer line on rewind (Round 8,
  §3.3/§5.2/§8.2 Step 7):** restore a session with a **web-search-only** assistant turn — no client
  `grep`/`read`, a `server_tool_use{id="srv_1", name="web_search", input={query="how does Moby-Dick
  end"}}` paired with a `web_search_tool_result{tool_use_id="srv_1", content=…}`, a transcript `tool`
  line stamped `_tool_use_id="srv_1"` (the second stamping site at `_renderAssistantTurn`), and a
  trailing `assistant` answer line that quotes the web result. On a **backward** resume to a lower page,
  assert (a) the wire `web_search_tool_result` is redacted and its `tool_use_id` (`srv_1`) is added to
  `redacted_ids`; **(b) the `transcript[]` web-search summary line — which carries the spoiling query —
  is scrubbed to the redaction stub** (Rule 1 keyed on `_tool_use_id ∈ redacted_ids`, the second
  stamping site); **and (c) the trailing `assistant` answer line is ALSO scrubbed** (Rule 2 — the
  matched web-search line armed `turn_was_redacted` even though there is no client `tool_result`). Assert
  the original query string and the original answer text are **gone** from the rendered transcript.
  Regression guard (Round 11 semantics): a web-search summary line with **no** `_tool_use_id`
  (pre-Round-8 file) cannot be matched by Rule 1 — when it is the **only** redacted-wire line, the
  Round-11 fallback replaces the whole transcript with the single placeholder (screen never shows
  the spoiling query the wire hid); when other lines DID match, the untagged line is left intact —
  documenting why the second stamping site is load-bearing for *surgical* (line-level) scrubbing. On
  a forward/same resume both lines are left intact.
- **Equal-position resume is forward/safe (Step 1, cmp==0):** stub `compareXPointers(stored, live)→0`
  (same device, no movement — the common case); assert the **forward** branch is taken — no Step 5
  passage-gate clause, no `"(spoilers reset)"` banner, Step 7 does not redact (reconciles §8.3).
- **Highlighted-passage gate on rewind (LEAK-3):** rewind case → marker includes the passage-gating
  instruction; forward case → it does not.
- **Memory-quarantine clause on EVERY memory-enabled resume (LEAK-6, Step 5b, Round 9):**
  `_effectiveConfig().enable_memory == true` → the armed `_resume_note` **carries** the
  memory-quarantine clause on **both** a backward resume **and a FORWARD resume** (the clause is keyed on
  `cur_page`, not on `is_backward`, because the book-keyed memory store can hold past-`cur_page` notes
  regardless of move direction); with `enable_memory == false` → the clause is **absent** in both
  directions. (Contrast: the Step 5/5c/7 redaction and web-search-quarantine clauses remain
  backward-only — assert the forward resume omits *those* while still carrying the memory clause.)
- **compareXPointers oracle drives direction (DRIFT-3):** stub `compareXPointers` to return the
  backward verdict even when `page_at_save == cur_page` (same reflowed page); assert the rewind branch
  fires (proves the page-int compare is **not** the oracle). Conversely, a malformed stored xpointer
  that errors `compareXPointers` → fail-safe **backward** branch, no crash.
- **Identity guard (DRIFT-2):** mismatched `book.ident` → refuse; missing ident + `(unknown)` title →
  refuse; matching ident → proceed.
- **Nil-page grep records the sentinel, over `shown[]` not `visible[]` (§5.2/§8.3, Round 3/7):** a
  **non-spoiler** grep whose **rendered/shown** result carried a nil-page hit → `tool_grep` returns
  `had_unbounded_hit == true` and the loop records `max_referenced_page = SPOILER_SENTINEL` (in the
  side-table). On a backward resume, assert that block's content is redacted by the `> cur_page`
  predicate (proves a nil-page hit no longer leaks on rewind); the gate's visible/hidden partition is
  unchanged (additive-return-only assertion). **Round 7 — shown-set pin:** a grep with `max_results`
  small enough that a nil-page hit lands in `visible[]` but **past** the shown cutoff (never rendered)
  → `had_unbounded_hit == false` and the block is **not** sentinel-armed (no permanent over-redaction of
  an unrendered hit).
- **Second-resume marker not stacked — including NON-adjacent markers (§8.2 Step 4, Round 3/Round 11):**
  resume once (marker armed + baked into the user turn on the next `ask`), then resume **again** with a
  different `cur_page`; assert the history contains **exactly one** `<resume_context>` block (the prior
  one stripped), not two with conflicting page numbers. **Round 11 — the case the last-message-only scan
  missed:** after the first resume, `ask()` **two** questions (the marker now rides a user message that
  is NOT the last), then resume again; assert the whole-history scan found and stripped that older
  marker — grep **every** user message and count exactly one `<resume_context>` (the newest).
- **`_resume_note` wrap is messages-only (§5.2, Round 3):** with `_resume_note` armed, `ask("q")`; assert
  `messages[#].content` is the wrapped array `{ {text=marker}, {text="q"} }` **and** the matching
  `transcript` user entry is the **plain string** `"q"` (not a table) — `_transcriptText`/`_render` does
  not throw.
- **"Reveal everything" escape hatch disables rewind redaction (Round 6, §7.3/§8.2):** restore a
  tainted-backward blob (`spoiler_consent == true`, a `tool_result` with `max_referenced_page > cur_page`)
  and set `conv._reveal_all = true` (the dialog's "Reveal everything" path) **before** `_reanchorPosition`;
  on the backward resume assert (a) the future-page `tool_result`/`web_search_tool_result` content is
  **NOT** redacted (left intact), (b) Steps 5/5b/5c quarantine clauses are **omitted** from the armed
  `_resume_note`, **(c) Step 7b still stripped `max_referenced_page`** from all `tool_result` blocks
  (wire hygiene runs regardless), so the first `buildBody` does not 400, **and (d) Round 10 — the seed
  `<book_context>` block's `"Current chapter: …"` line and any foreign-blob `book_context` `tool_result`
  carrying a `"Current chapter:"` line are LEFT INTACT** (the seed surgery and foreign-blob fail-safe now
  honor the escape hatch — a "Reveal everything" resume hides nothing). With `_reveal_all` left false
  (the default "Resume hidden" path) the same blob redacts as the LEAK-5 test. Also assert `resumeSession`
  raises the three-button `ConfirmBox` only when the blob is tainted-backward (spoiler_consent OR
  max persisted `max_referenced_page > cur_page`), and skips it on a clean forward/same blob.
- **Per-turn nil-page guard for resumed sessions (§8.2b, Round 3):** on a successfully resumed session
  (`_resumed == true`), stub `currentPage → nil` on a **later** turn; assert `_loop` aborts the turn with
  the Step-0.5 reason and does **not** build a body (no unclamped read reaches `:381`). A non-resumed
  chat with the same nil does **not** trip the guard.
- **Mid-turn nil-page refusal before gated dispatch (Round 6, §8.2b/§8.3 LEAK-0):** on a resumed session
  (`_resumed == true`) that **passed** the loop-entry guard (page resolvable at entry), drive a tool
  round and stub `currentPage → nil` **between rounds** so the next dispatched `read`/`grep` sees a nil
  page; assert `Tools.execute` is **not** called for that gated tool and the tool_result instead carries
  the "Reading position unavailable" reason string (the round stays well-formed, `validateMessages`
  passes). A `memory`/non-gated tool (`get_toc`) in the same nil-page state is **not** refused.

### Tier-2 (`tests/integration/real/*`)

- **`session_serialize_real.lua` (C3):** over real `rapidjson`, assert a `serialize()`-coerced
  zero-arg `tool_use.input` round-trips as `{}` (**object**, not `[]`), and that a
  `web_search_tool_result` whose `content` is the **error OBJECT** round-trips with the object intact
  (the real producible case — empty `[]` content is not producible by this plugin, §9.2). These are
  the assertions the Tier-1 stub cannot make.
- **Re-serialize of a restored zero-arg tool keeps `{}` not `[]` (Round 10, §9.1 `coerceToolUseInput`):**
  over real `rapidjson`, **restore** a session carrying a zero-arg `tool_use` (so `_normalizeToolInputs`
  sets `input = rapidjson.object({})` on the live `self.messages`), then **re-serialize** it. Because
  `deepCopy` strips the rapidjson object metatable, the re-serialized block's `input` is a bare empty
  `{}`; assert `coerceToolUseInput`'s **empty-table arm** re-coerced it so the re-serialized `input`
  still `rapidjson.encode`s as `{}` (an **object**), **not** `[]` — proving a resume→re-save→resume
  chain cannot drift a zero-arg tool into the `[]` 400.
- **Empty `messages[]` encodes as `[]` not `{}` (Round 6, §9.0/§9.1):** over real `rapidjson`, drive
  `serialize()` on a fully-rolled-back history whose persisted `messages[]` is **empty** (e.g. a
  signatureless-thinking rollback that removed the only tool round and left no clean assistant turn);
  `rapidjson.encode` the result and assert the JSON text contains `"messages":[]` (an **array**), **not**
  `"messages":{}` (an object) — proving the `tagArrays` array-metatable tag fired so the wire is
  well-formed and the §14 deep-equal baseline does not spuriously diverge on the empty case. (Tier-1's
  stub encoder re-derives array-ness by content heuristic and cannot detect this — it is Tier-2 only.)
- **Interior signatureless-thinking orphan truncated (Round 5, §9.1):** over real `rapidjson`, serialize a
  history of `[user seed]` + `[assistant: text]` (clean) + `[assistant: thinking(no sig), tool_use]`
  (INTERIOR orphan — the `tool_use` has no signed thinking before it after the drop) + `[user: tool_result]`
  + `[assistant: text]`, with **thinking ON**; assert `serialize()`'s persisted `messages[]` is
  **truncated at the last clean assistant turn before the interior orphan** (the orphaned tool round and
  all subsequent rounds dropped), `restore` of the blob validates, and a captured `buildBody` (thinking
  re-asserted ON) has **no `tool_use` lacking a preceding signed `thinking`** — i.e. the interior orphan
  can never reach the wire and 400. (Tier-1 cannot detect this: `sse.lua` does not check
  thinking-before-tool_use.)
- **Block-order: a tool_use STILL preceded by signed thinking after the drop is NOT truncated (Round 7,
  §9.1):** over real `rapidjson`, serialize a history whose interior assistant message is
  `[thinking(signed), tool_use, thinking(no sig), text]` (the signatureless thinking is *after* the
  tool_use; a signed thinking precedes it) + `[user: tool_result]` + `[assistant: text]`, with **thinking
  ON**; assert `serialize()` **drops only the signatureless thinking block** and does **NOT** truncate the
  history (all subsequent rounds survive — no over-truncation of the valid resumable prefix), the
  `tool_use` still has its signed thinking before it, `restore` validates, and `buildBody` (thinking ON)
  carries the full history. Proves the trigger is block-order-aware, not the coarse "message also carries
  a tool_use" rule.
- **`session_resume_real.lua`** over `juliet.epub`: run a turn, serialize, restore, **resume at a
  different real page in both directions**. Forward: assert the gate now permits content up to the
  new page. **Rewind:** assert the gate refuses content beyond the new lower page **even though the
  saved session had `spoiler_consent`**, **and** that any in-history `tool_result` referencing the
  higher pages was redacted (Step 7) — the end-to-end proof that consent revocation + re-anchor +
  redaction close the rewind leak.

**Gate:** `nix run .#check` (stylua --check + luacheck std=luajit + busted) before commit.

---

## 15. Implementation checklist (ordered, commit-sized)

0. **Helper ownership (§9.0).** Before wiring serialize/restore: `numOr0` is a **`bbanthropic` local** —
   export it (`Anthropic.numOr0 = numOr0`) and require it, **or** define a private copy in
   `bbconversation`. `currentPage` is a **`bbtools` local** (`bbtools.lua:58`) — expose
   (`Tools.currentPage = currentPage`) or import for the §5.2 loop annotation. The new
   `deepCopy`/`safeMD5`/`safeXPointer`/`countAssistant`/`snapshotTranscript`/`sanitizeTranscript`/
   strip/coerce/`mergeReferencedPages` helpers are `bbconversation` file-locals. **`numOr0`'s private
   copy must mirror the actual source — `type(v) == "number" and v or 0`, NOT `tonumber(x) or 0`
   (Round 5, §9.0).**
0.5. **Wire `self.conversation` (Round 5 — load-bearing prerequisite for items 4 and 7).** At
   `main.lua:166` the conversation is a function-local (`local conversation = Conversation:new{…}`) that
   survives only via the viewer widget, so `self.conversation` is **never created** — and §5.3's
   close-flush + §7.3's resume-replace guards (which read/write it) are dead code. **Store the active
   conversation on `self.conversation`** at `main.lua:166` and **null it on viewer close / on replace**
   (`resumeSession` sets `self.conversation = conv` after closing the old one). Add a Tier-1/UI test that
   `onCloseDocument` and `resumeSession` see the live conversation (§14). Do this **before** items 4/7,
   which depend on it.
1. **`bbsession.lua` + `tests/bbsession_spec.lua`:** `dir` (with `sdr==""`→nil), `newId`
   (**delimited + zero-padded** `"%d-%x-%06x"` so seq/random never collide within one `os.time()`
   second — §5.1; **mixed-entropy seed** — `os.time` + sub-second `os.clock` + `tostring({})` pointer
   digits, Round 11) + `_proc`
   module constant (NO `getpid`), atomic+fsync `save` (rand-suffix tmp; **`force_flush=true` is
   `fdatasync` — file DATA only, not metadata, §5.1/§6/§11**; **first-ever save also `fsyncDirectory`s the
   PARENT `.sdr` once after `makePath` — STEAL-FAT-1, Round 8**; **RENAME-FIRST, Round 11: try
   `os.rename(tmp, final)` directly — atomic replace-over on POSIX; only on failure (FAT-EEXIST) free
   the destination (`final`→`.bak`, else remove) and retry, with `os.rename(bak, final)` rollback so
   the row never silently vanishes**; **PERSISTENT `.bak`
   refreshed only from a >60s-old `final` — by `ffiUtil.copyFile` COPY, Round 11, so `final` survives —
   and NEVER removed — mirrors `LuaSettings:backup`'s gate, Round 5; needs
   `lfs.attributes(final,"modification")`**, **`prune` to `keep` after a successful write — §13**), `load`
   (NUL sentinel + schema gate + shape + id-traversal reject, **`.bak` fallback**), `list` (header-cap +
   NUL/schema-marker regex path + conflict filter + sort), **`prune`** (oldest-by-`updated` beyond `keep`
   **+ sweep plugin-shaped `*.tmp` older than ~3 min — the age gate ALWAYS applies, Round 11 — and
   `.sync-conflict-*.json` older than ~30 days, Round 11**),
   `delete` (**also reaps `<id>.json.bak` — Round 5**) / `clear` / `hasContent`. Spec uses hand-rolled
   fs/`ffi-util`/`docsettings` shims (§14 contract); fsync durability is **not** Tier-1, but the
   **persistent-`.bak` 60s-gate + power-off-after-close fallback**, the **`.bak`/`.tmp` reaping**, and the
   **retention-prune** are.
2. **`Conversation:serialize()`** — deep-copy, **strip cache_control**, `coerceToolResultContent`
   (client only), `coerceToolUseInput` (absent **OR empty** →`rapidjson.object({})`), `dropSignaturelessThinking`
   (**roll back an orphaned tool round — §9.1 CRITICAL**), **`mergeReferencedPages` from
   `_mrp_by_tool_use_id` onto the DEEP COPY only**, **single `getProps()`**, `config_fingerprint`
   (model = display only), **`seed` field**, **no `_dropDanglingTail`** — + round-trip, no-truncate,
   input-coerce, signatureless-drop (+ orphan-rollback), mrp-not-on-live-block, web-search-object specs
   (`tests/session_resume_spec.lua`).
3. **`Conversation.restore`** — **`_normalizeToolInputs` belt (load-side)**, **pair-then-drop**,
   **table-usage guard** + `numOr0`, **posture re-assert** via `config_fingerprint` + `_rebuildToolSpecs`
   (**model NOT enforced**; **rebuild memory store when posture re-enables memory — C12**; **Round 11:
   absent fingerprint → INFER `enable_thinking` from thinking-block presence + log**),
   **Round 11 TAINT HARVEST — copy every decoded `max_referenced_page` into `_mrp_by_tool_use_id`
   before any strip (generation-2 rewind leak)**, **Round 11 `loc_seq` — set the live
   `ui._bookbuddy_loc_seq` to `max(live, stored)`**,
   **`_syncTranscriptToMessages` UNCONDITIONALLY (algorithm pinned §7.3, Round 11)**, **rehydrate
   `selected_text`/`note` from `data.seed` unconditionally (consume on the empty-history path only)**,
   **leading-non-user / interior-alternation refusal**
   (return `nil,reason`), transcript sanitize — + self-heal / order / usage / refusal / posture /
   validateMessages / resume-continues / re-seed+carry / transcript-resync / normalize-input /
   memory-store / model-not-enforced / taint-generation-2 / loc-seq / fingerprint-inference specs. Add
   `_effectiveConfig`/`_rebuildToolSpecs`/`_isResumableState` (reuse the
   exact `_dropDanglingTail` danglingness test — §7.3), the **pure `Conversation.assessResume(ui, data)`
   pre-flight (Round 11 — §7.3)**, and route `_loop`'s config read through
   `_effectiveConfig`.
4. **`_persist`** (skip when `safeXPointer(ui)` is nil — paging docs not persisted; **pass `session_keep`
   to `Session.save`**; **STEAL-1 (Round 9): early `if not self:_isResumableState() then return end` so the
   four call sites are scheduling hints, not correctness-load-bearing**; **STEAL-2 (Round 9): `_dirty`
   gate — `o._dirty=false` in `new()`, set true in `ask()` + `_storeAssistant`, cleared after a
   successful `Session.save` — Round 11: `_persist` CHECKS `Session.save`'s return; a failed save
   leaves `_dirty` true so the close flush retries — left false by `restore()`, so a
   resumed-but-unasked session keeps its saved
   `anchor.xpointer`**) **+ four verified save sites** (`:582, :590, :305, :514` — 2026-06-05 anchors;
   drifted, see the top note) + `_session_id` /
   codepoint-safe `_title_snippet` + spoiler-consent tracking **and `max_referenced_page` annotation
   re-derived in the tool loop into the `_mrp_by_tool_use_id` SIDE-TABLE (never the live block)** from
   `currentPage(ui)` + `tu.input` (spoiler reads **and grep `had_unbounded_hit`** record
   `SPOILER_SENTINEL`; expose `currentPage` to the loop; consume `tool_grep`'s additive third return).
   **`bbtools.lua` `Tools.execute` MUST thread a third return — `return result or "", summary, extra`
   (Round 5, §5.2): without it `had_unbounded_hit` is always nil and the nil-page-grep fail-safe is dead
   code.** **Stamp `transcript[]._tool_use_id` at BOTH sites (Round 8, §3.3/§5.2): the client-tool dispatch
   line (`= tu.id`, `:562`) AND the web-search summary line in `_renderAssistantTurn`
   (`= b.id`, the `server_tool_use` id, `:800-809`) — without the second site the spoiling search query
   and a web-search-only answer line leak on a rewind (Step 7 Rule 1/2).** (Depends on Checklist 0.5
   wiring for `self.conversation`.)
5. **`_reanchorPosition`** — **Step 0.5 nil-page fail-closed refusal** (capability-specific reason for
   paging docs), identity guard, `compareXPointers` direction oracle (pcall, fail-safe backward;
   **`cmp==0` is forward/safe**), deterministic table-seed rewrite from captured `cur_page` +
   post-condition (Round 11: seed surgery **span-bounded** — plain-`find` the
   `<book_context>…</book_context>` span, splice via `string.sub`; the untrusted passage shares the
   single seed block), consent revocation, authoritative `<resume_context>` marker (armed via
   `_resume_note`/`ask`; **strip any prior `<resume_context>` before arming — scan ALL user messages,
   Round 11 — no stacking**; **wrap is
   messages-only, transcript keeps plain string**), rewind passage gate, **Step 5b memory-quarantine
   clause** (Round 9: armed on **every memory-enabled resume** — `_effectiveConfig().enable_memory`,
   independent of `is_backward`, modulo `not _reveal_all` — keyed on `cur_page`), **Step 7 rewind-only
   `tool_result` redaction** (single `max_referenced_page > cur_page` predicate), **Step 7b unconditional
   `max_referenced_page` strip** (every direction, at the close of `_reanchorPosition`, on the decoded
   persisted blocks, so a forward/same resume's first `buildBody` cannot 400), **set `_resumed = true`
   (Step 6)**, persistent `_resume_banner` threaded into the viewer title — + `tests/session_spoiler_spec.lua`.
5b. **§8.2b per-turn nil-page guard in `_loop`** — for a resumed session (`_resumed`), abort the turn with
   the Step-0.5 reason when `currentPage` is non-numeric (the `:381` gate itself stays unfixed — §8.3).
6. **`bbsettings.lua`** — `DEFAULTS.enable_sessions=true` / **`DEFAULTS.session_keep=20`** / `getConfig` /
   "Save chats" toggle + "Manage saved chats" `showSessions` UI (**per-row delete ConfirmBox-gated —
   Round 4**, matching bbmemory's destructive-op pattern + clear-all ConfirmBox) + settings spec.
7. **`main.lua`** — **store `self.conversation` at `:166` + null on viewer close / replace (Checklist 0.5,
   Round 5 — prerequisite for the guards below)** + **primary "Chat about this book" callback (`:94-99`)
   gated on `enable_sessions and Session.hasContent(self.ui)` → `showContinueOrNew()` ConfirmBox
   ([Continue last chat] → `resumeSession(Session.list(self.ui)[1].id)` / [Start new chat] →
   `promptAndStart(nil)`), else straight through to `promptAndStart(nil)` — closes the invisible-fork
   data-loss mode (Round 8, §5.3)** + `showResumePicker` (sparse rows + `<turn_count> turns ·
   datetime.secondsToDateTime(updated, nil, true)` turn-count + date+time discriminator — Round 7 leads with
   turn_count and drops the reflow-dependent page number; date+time from Round 5) + `resumeSession`
   (`_isResumableState` mid-turn guard — reuses `_dropDanglingTail` danglingness; **Round 11: pure
   `Conversation.assessResume` pre-flight BEFORE any construction — identity/nil-page refusals and the
   taint dialog run with zero side effects, and only the committed path constructs the conv**;
   restore-`nil` handling,
   close-live-after-success, reassign `self.conversation`) + **`onCloseDocument` close-document flush
   gated on `_isResumableState` (Round 4 — fires before document nulling)** + gated menu entry at index 2
   + viewer-title banner threading via the **title STRING** (`title = self._resume_banner and
   T(_("BookBuddy — %1"), self._resume_banner) or _("BookBuddy")`) in `_render` **and
   `_ensureStreamingViewer`** **and `bbchatviewer.lua:55`** (Round 5 — NOT a subtitle slot; `TextViewer`
   forwards no `subtitle`).
8. **Tier-2** `session_serialize_real.lua` + `session_resume_real.lua` (forward **and rewind**).
9. **Docs:** AGENTS.md note (session store, `.sdr` lifecycle, orphaned-litter caveat,
   locators-never-restored invariant); `_meta.lua` version bump.
10. **Full `nix run .#check`;** manual KOReader smoke: chat → close → reopen → resume → reply;
    advance → resume → verify higher boundary + can discuss read pages; rewind with prior spoiler
    consent → resume → verify spoilers refused + banner shows "spoilers reset".

---

## 16. Risks, trade-offs & open questions

**Accepted trade-offs:**
- Destructive-in-place resume (no branching) — a resumed chat replaces the live one; documented and
  made legible by the viewer-title banner and `resumeSession` closing the live conv first. **Live-side
  loss is guarded:** because Resume closes the live chat without a close-time save (§5.2), it is only
  allowed to replace a live chat that is itself at a terminal/clean state (`_isResumableState()`);
  otherwise it shows "Finish or close the current chat first." so a deliberate Resume tap cannot
  silently discard unsaved mid-turn work (§7.3).
- Seed-only / first-turn-crash state is not persisted — accepted gap in the "always here" promise.
- Book move in `doc`/`dir` mode orphans sessions as litter at the old `.sdr` — parity with bbmemory;
  prune affordance deferred.
- No **within-conversation** size cap — wire cost caps practical length; manual delete is the escape
  hatch. (Per-book **file-count** growth IS capped now — `session_keep` retention, §13.)
- **Saved `model` is not enforced** — a resumed session runs against the reader's **live** model, not
  the model it was saved under. Trade-off: a deprovisioned saved model cannot 400 every resumed turn
  (the failure mode pinning would cause), at the cost of thinking-signature validity being only
  *nominally* model-scoped across a model switch. In practice the resent thinking blocks carry their own
  signatures and the gateway accepts them; if a future gateway rejects cross-model signatures, the
  signatureless-drop / orphan-rollback path (§9.1) is the belt. `model` stays in `config_fingerprint`
  for the picker/diagnostics (§3.3/§9.6).

**Risks:**
- The spoiler marker is instructional, not enforced in code. For *new* tool calls the floating gate
  (`bbtools.lua` untouched) is the enforced backstop and consent is revoked, so the marker only needs
  to suppress the model's *habit* of passing `spoiler=true`. For payload **already in the resent
  history**, the gate does **not** apply — §8.2 **Step 7 redacts** future-page `tool_result` content on
  a rewind, so the marker is belt and the redaction is suspenders. Residual: redaction fidelity is
  bounded by the per-tool `max_referenced_page` annotation.
- **Memory recall (LEAK-6) is marker-guarded only, not redacted.** Step 7 redacts `tool_result.content`
  in `self.messages`; it does **not** touch the bbmemory store, which `restore` rebuilds from the live
  book dir and the MEMORY_PROTOCOL surfaces at conversation start. On a backward resume of a
  memory-enabled book, the Step 5b marker clause is the **only** guard against later-page plot notes
  reaching context — an honest residual, accepted because redacting/quarantining the memory store would
  need a store change this approach explicitly avoids.
- Header regex scan for >256 KB files is heuristic; acceptable because it only affects the picker row
  text of pathological sessions (full `load` still uses real decode).
- Move **direction** is decided by `compareXPointers` (the gate's own oracle), not by any page
  integer, so a reflow that shifts `getPageFromXPointer` relative to `page_at_save` does not mislead
  it; `cur_page` only feeds the UX banner and the marker's boundary number (both intentionally live).
  `compareXPointers` errors, a **nil return** (either xpointer invalid — `credocument.lua:750-752`),
  or a missing xpointer all fail **safe** to the rewind branch.

**Rejected:**
- *Pin-to-saved spoiler position* — contradicts the floating live gate, needs deep `bbtools`
  threading, and still splits on later in-session movement. Re-anchor-to-current with xpointer +
  consent revocation is safer and simpler.
- *`index.json`* — adds a desync surface under partial Syncthing sync; dir scan is self-healing.
- *Automatic compaction/pruning* — would alter wire history and risk alternation/pairing.

**By design (not deferred):**
- **Paging docs (PDF/CBZ) are not persisted or resumable.** They have a structurally `nil`
  `currentPage` and no `getXPointer`, so the entire §8 spoiler argument (which rests on the xpointer
  oracle and the floating page gate) cannot hold. `_persist` skips when `safeXPointer(ui)` is nil
  (§5.2) — no unresumable blobs litter every PDF's `.sdr` — and Step 0.5 refuses a resume with a
  capability-specific reason ("This book type can't be resumed spoiler-safely", not "open the book to a
  page"). This is a deliberate scope boundary, not a gap to close later.

**Open (deferred, no schema impact):**
- A "continue last chat" quick-resume (autoload most-recent — the `updated` sort already supports it).
- A "prune orphaned session dirs" maintenance action.
- A *visible* over-long-chat notice if `.sdr` bloat is observed in the field.
- (Relative-date formatting is **resolved**: the picker uses
  `datetime.secondsToDateTime(updated, nil, true)` — date+time so two same-day chats are distinguishable, §7.2.)

---

## 17. Verified source anchors (re-checked 2026-06-05)

- `bbanthropic.lua:21-83` — `buildBody`: strips all `cache_control` (`:60-69`), sets one ephemeral
  breakpoint on the last block of the last message (`:71-79`), rewrites string content to a
  `{type=text}` array in place (`:73-76`); `rapidjson` keeps object/array distinct across
  decode→encode (`:1-3` comment). **`body.thinking` is set ONLY under `cfg.enable_thinking` (`:53-54`)
  yet history thinking blocks are always resent ⇒ the §9.6 posture-reconciliation bug.**
- `bbanthropic.lua` stream parser: `content_block_stop` assigns `.input` **only** when
  `accum and #accum > 0` (`:281-285`) ⇒ a zero-arg tool_use leaves `input` ABSENT (§9.1
  `coerceToolUseInput`).
- `bbsettings.lua:61-` (`getConfig` builds and returns a fresh table), `:24/:29/:34`
  (`enable_memory`/`enable_thinking`/`enable_web_search` defaults), `:72-74` (config exposure).
- `ffi/util.lua` — **no `getpid` export**; `getpid` appears only as `C.getpid()` inside
  `runInSubProcess` (`:412`) ⇒ `ffiUtil.getpid()` would nil-error (§5.1 uses `_proc` + rand instead).
- `koreader/frontend/document/document.lua:153/159/166` — `getProps` calls `getDocumentProps()` (an
  uncached crengine C round-trip) every invocation, mapping `""`→nil ⇒ call once per save (§9.1).
- `bbtools.lua:369` (`if start_page and cur ...` start-page refusal) and `:381` (`if cur then` forward
  clamp) — **both bypassed when `currentPage` is nil** ⇒ §8.2 Step 0.5 fail-closed refusal.
- `bbtools.lua:465-466` (comment; uses at `:480/:494/:505`; capability check `:380`) —
  `compareXPointers` is the read gate's own oracle (`1` = second arg after
  first; upstream `credocument.lua:750-752`: `1`/`-1`/`0`, **`nil` when either xpointer is invalid**
  — the nil falls to Step 1's backward fail-safe) ⇒ §8.2 Step 1 uses it for direction, not page-int
  compare. (Anchors re-verified 2026-07-02.)
- `bbconversation.lua:171-223` (`new`/scratch-clear/usage), `:176-208` (tool_specs assembly →
  `_rebuildToolSpecs`), `:274` (`cfg = self.settings:getConfig()` in `_loop` → `_effectiveConfig`),
  `:225-260` (`ask`/seed/title),
  `:305-306` (pause resume-limit save site), `:514` (empty-200 placeholder save site), `:566-578`
  (tool loop + nil-guarded `content`), `:580` (mid-loop tool_result append — NOT a save site),
  `:582` (terminal no-tool save site), `:590` (budget-exhausted save site), `:599-608`
  (`_storeAssistant` / pause merge), `:620-655` (`_dropDanglingTail` → always `_trimTranscript`;
  orphan `server_tool_use` treated dangling `:642-645`), `:665-673` (`_trimTranscript` pins on
  `_clean_transcript_len`), `:528` (unconditional `pairDanglingWebSearch`).
- `bbtools.lua:58` (`currentPage` is a **bbtools-local** — must be exposed/imported for the §5.2 loop
  annotation), `:196-211` (max_page only tightens; `cap` computed locally, never returned;
  `spoiler=true` removes cap), `:199` (`currentPage` fresh per call), `:216-223` (visible/hidden
  partition: a **nil page is treated as VISIBLE** — `:219` requires `page ~= nil` to hide — so a
  non-spoiler grep can surface a nil-page hit past the reader ⇒ §5.2 `had_unbounded_hit` additive return
  + §8.3 sentinel fail-safe; **note this return only reaches the loop once `Tools.execute` threads a
  third value — `bbtools.lua:1088-1099`, Round 5**), `:336` (stale-locator not-found branch), `:381-383` (`read` `cur+1` clamp,
  computed locally, never returned via `Tools.execute`; **bypassed when `cur` is nil** ⇒ §8.2b per-turn
  guard),
  `:455-476` (`book_context` shape; `currentPage(ui)` re-read at `:464`; `"Current page: %s of %s"` at
  `:466`; **`"Current chapter: " .. title` at `:472` — a spoiling chapter title ⇒ §5.2 book_context
  annotation + §8.3 LEAK-8**), `:458-459` (`(unknown)` title/author sentinels).
- `bbconversation.lua:73-96` — `pairDanglingWebSearch` heals **only** the forward orphan (append a
  synthetic `web_search_tool_result_error` for a `server_tool_use` lacking its result); it does **not**
  drop a reverse-orphan `web_search_tool_result` ⇒ §7.3/§9.3 reverse-orphan heal (Round 4).
- `bbconversation.lua:506-513` — live loop stores a `(no response)` placeholder for an empty-content
  assistant turn (avoids the empty-content 400) ⇒ §9.1 drop-whole-message on empty content (Round 4;
  `serialize()` has no placeholder path).
- **Title build sites (all hardcoded `_("BookBuddy")`):** `bbconversation.lua:957` (`_render`),
  `bbconversation.lua:864` (`_ensureStreamingViewer`), `bbchatviewer.lua:55` (`ChatViewer.build`
  default) ⇒ §7.1/§8.2 Step 6 banner must thread all three (Round 4).
- `koreader/frontend/ui/widget/textviewer.lua:177-184` — `TextViewer.build` forwards **only**
  `title`/`title_face`/`title_multilines`/`title_shrink_font_to_fit` to its `TitleBar`, **never
  `subtitle`** (TitleBar supports `subtitle` at `titlebar.lua:37`, but only an upstream patch could pass
  it through `TextViewer`) ⇒ §7.1/§8.2 Step 6 fold the resume banner into the **title STRING**, not a
  subtitle slot (Round 5).
- `koreader/frontend/luasettings.lua:252-267` — `LuaSettings:backup` keeps a **persistent** `.old` and
  refreshes it only when the current file is >60s old (so the OS has likely sync'ed it), with automatic
  `.old` fallback on open ⇒ §5.1/§6 persistent `.bak` with the 60s freshness gate (Round 5).
- `bbtools.lua:1088-1099` — `Tools.execute` destructures `local ok, result, summary = pcall(fn, …)` and
  `return result or "", summary` — **only two values** ⇒ §5.2 must thread a third return
  (`return result or "", summary, extra`; `Returns (result_string, summary, extra)`) for the grep
  `had_unbounded_hit` fail-safe to be live, not dead code (Round 5).
- `bbanthropic.lua:200-202` — `numOr0` is `type(v) == "number" and v or 0` (**not** `tonumber(x) or 0`;
  a string usage field returns `0`) ⇒ §9.0/§9.1 private-copy option (b) must mirror this (Round 5).
- `main.lua:94-99` — the primary "Chat about this book" menu item's callback **always** calls
  `self:promptAndStart(nil)` (mints a fresh `Conversation`/`_session_id`/file) ⇒ §5.3 gates it on
  `enable_sessions and Session.hasContent(self.ui)` → `showContinueOrNew()` to close the invisible-fork
  data-loss mode (Round 8).
- `main.lua:166` — the conversation is a function-local `local conversation = Conversation:new{…}`,
  **never stored on `self`** ⇒ §5.3/§7.3 wire `self.conversation` (assign + null on close/replace) so the
  close-flush and resume-replace guards are not dead code (Round 5, Checklist 0.5).
- `main.lua` — **no `onCloseDocument` handler** today ⇒ §5.3 adds the gated close-document flush
  (CloseDocument fires before `ui.document` is nulled) (Round 4).
- `bbsettings.lua:182` — destructive op (`Clear memory`) is `ConfirmBox`-gated ⇒ §5.4 per-row delete
  confirmation pattern (Round 4).
- `bbconversation.lua:565-578` — tool loop sees only `tu.input`/`result`/`summary` (the gate's clamp is
  never exposed) ⇒ §5.2 re-derives `max_referenced_page`; **the client-tool dispatch `tool_entry` is
  where `_loop` stamps `tool_entry._tool_use_id = tu.id` (`:562`)** ⇒ §3.3/§8.2 Step 7 Rule 1; `:825`
  (`_transcriptText` else-branch, unguarded `out[#out+1]=turn.text`) → `:832` (`table.concat`) ⇒ §7.3
  `sanitizeTranscript` + `tostring` hardening.
- `bbconversation.lua:800-809` — `_renderAssistantTurn`'s `server_tool_use`/`web_search` branch builds
  the `"  → Searched the web for … — N result(s)"` transcript entry as `{role="tool", text=text}` with
  **NO `_tool_use_id`** ⇒ §3.3/§5.2/§8.2 Step 7 Rule 1: stamp `_tool_use_id = b.id` (the
  `server_tool_use` id) here too, so a rewind scrubs the spoiling web-search query line and the
  web-search-only answer line (Round 8). The paired wire `web_search_tool_result.tool_use_id == b.id`,
  which §8.2 Step 7's web redaction already collects into `redacted_ids`.
- `koreader/frontend/datetime.lua:274` (`datetime.secondsToDate(seconds, use_locale)` — **date ONLY**,
  no hour/minute) and `:296` (`datetime.secondsToDateTime(seconds, twelve_hour_clock, use_locale)` —
  date+time; absolute, localized; **no `relativeDate` exists in-tree**) ⇒ §7.2 picker row uses
  `secondsToDateTime(updated, nil, true)` so two same-day chats are distinguishable (Round 5).
- `koreader/frontend/util.lua:830` (`util.fileExists`) ⇒ §5.1 `.bak` retention guard.
- `bbmemory.lua:101-108` (sidecar dir + `sdr==""`→nil), `:430-434` (pcall discipline), `:445`
  (`util.findFiles`), `:471` (`ffiUtil.purgeDir`), `:220/:264/:406` (`util.makePath`).
- `koreader/frontend/util.lua:1141-1160` (`writeToFile(data, filepath, force_flush, lua_dofile_ready,
  directory_updated)`; `force_flush`→`fsyncOpenedFile(file)` **with `sync_metadata` nil** `:1152-1154`;
  `directory_updated`→`fsyncDirectory` `:1156-1158`), `:1111` (`util.partialMD5`).
- `koreader/base/ffi/util.lua:570-583` — `fsyncOpenedFile(fd, sync_metadata)`: with `sync_metadata`
  true → `C.fsync` (data **and** metadata); else → **`C.fdatasync`** (data only, **not** the inode
  metadata). `Session.save`'s `writeToFile(json, tmp, true)` takes the `fdatasync` branch ⇒ §5.1/§6/§11
  durability wording is **fdatasync (data) + `fsyncDirectory` (rename entry)**, at parity with
  KOReader's own `LuaSettings` metadata writes, **not** a full file-inode fsync (Round 8).
- `koreader/frontend/docsettings.lua:118` (`getSidecarDir(doc_path, force_location)`), `:433`
  (`DocSettings.updateLocation`; the metadata/custom-cover copy body at `:441-463` copies metadata only, never subdirs).
- `koreader/frontend/document/credocument.lua:884` (`getXPointer`), `:888-889` (`getPageXPointer`),
  `:900` (`getPageFromXPointer`).
- `tests/support/sse.lua` — `validateMessages` (alternation, dangling/orphan tool checks; does NOT
  check signature/object-ness/cache_control/usage).
- `tests/memory_spec.lua` — temp-dir idiom for `tests/bbsession_spec.lua`.
