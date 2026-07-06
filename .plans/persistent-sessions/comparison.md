# Persistent Sessions — Comparison & Recommendation

Three complete, build-from specs exist for making a BookBuddy chat survive KOReader
restart / book close / plugin reload and resume spoiler-safely. This document compares them
head-to-head and recommends a path. All three share the same correctness bedrock (the wire
`messages[]` is the source of truth, resent verbatim every turn; `buildBody` mutates it in
place by stripping `cache_control` and coercing the last message's string content to a block
array; rapidjson preserves the object/array distinction across one decode→encode), the same
load-time self-healing (`_dropDanglingTail`, web-search pairing), and the same hard rule that
**`bbtools.lua`'s spoiler gate is never touched** — it always reads `currentPage(ui)` fresh.
They differ in *where* state lives, *how durably* it is written, and *how aggressively* they
handle the resume spoiler problem.

---

## 1. One-paragraph summary of each approach

**A — Per-book sidecar session store.** Persist each conversation as **one JSON file** in the
open book's `.sdr` sidecar (`bookbuddy_sessions/<id>.json`), mirroring `bbmemory.lua`'s
per-book store exactly. Autosave the whole blob at the four verified terminal/clean-history
render points (overwriting one file per session, a natural debounce). Resume scans the current
book's sidecar dir (no index), shows a sparse e-ink picker, and rebuilds a live `Conversation`
via `restore` (pair-then-drop, usage `numOr0`). Spoiler safety on resume is an xpointer-anchored
re-anchor that **revokes prior spoiler consent unconditionally** and injects an authoritative
`<resume_context>` marker on the next user turn; the live gate stays floating. Sessions travel
with the book (Syncthing-friendly via the sidecar the reader already syncs). Default-ON (zero
token cost). One new `bbsession.lua` module + focused changes to `bbconversation`, `main`, `bbsettings`.

**B — Global hash-sharded blob store (scoped to per-book MVP).** Persist each conversation as a
self-describing rapidjson blob in a **device-global** content-hash-sharded directory keyed by
`partialMD5(file)` (`settings/bookbuddy_sessions/<hh>/<hash>/<id>.json`), so sessions survive a
book move/rename. Debounced 3s autosave from a single `_render()` hook, with the firing guarded
by `_in_flight`/`_isResendable` and a deep-copy snapshot so saving never mutates the live conv;
sync flush on `onCloseDocument`. Its two load-bearing additions beyond storage are a **config
fingerprint** that reconciles `enable_thinking`/`enable_web_search`/`enable_memory` drift before
any resend (thinking-drift is a guaranteed 400) via per-conversation overrides, and a
**history-quarantine** spoiler model for backward resume (instruct the model to treat its own
prior messages and ahead-describing memory notes as spoiler surfaces). FAT/exFAT-safe writes. The
global index and cross-book library are explicitly deferred. Default-ON.

**C — Append-only event-log / journal with replay.** Persist each conversation as a
**per-conversation NDJSON journal** in the `.sdr` sidecar, appending a few independently-decodable
records per turn (`header`/`user_turn`/`anchor`/`assistant_blocks`/`tool_result`+`bb_meta`/
`usage_delta`/`checkpoint`). There is **no save-on-close moment** — every record is
`flush`+`fsync`'d per append (no cached fd), so a crash loses at most the in-flight round.
Checkpoints (full resendable snapshot) are byte-threshold-gated (16 KiB) to bound cold replay.
Resume replays the journal through the live invariants. Its spoiler model is the most aggressive:
backward resume **redacts stored tool_results that drew from now-ahead positions** (xpointer
oracle `bb_meta.max_referenced_xp`, page fallback) to a structural stub — **reversibly**: the
original content is stashed in the checkpointed taint map and auto-restored when the reader
catches up (or on "Reveal everything") — re-gates the re-derived transcript, injects a
memory-spoiler note, and gates the whole thing behind an explicit consent dialog. Adds
`bbjournal.lua` + `bbwire.lua` (extracted+extended web-search healer); minimal read-only
instrumentation in `bbtools.lua`. Default-ON.

---

## 2. Comparison matrix

Scores 1 (weak) – 5 (strong). "Risk" dimensions score *lower risk = higher number*.

| Dimension | A — Sidecar blob | B — Global blob | C — Journal |
|---|---|---|---|
| **Diff size / low risk** | **5** — one new module, 4 clear save sites, no refactor of existing logic | 3 — new module + `_effectiveConfig` config-override plumbing + `_snapshotForPersist`/`_isResendable`/debounce state machine + `tool_book_context` refactor | 2 — two new modules, journal write threaded into ask/loop/_storeAssistant/tool_result/usage, `Tools.execute` return-shape change, transcript re-derivation |
| **Robustness / crash-safety** | 4 — atomic per-turn blob (tmp+fsync+rename+dir-fsync); worst case loses the last completed turn only if it never reached a save site; debounce-free | 3 — same atomic write, but a **≤3s debounce window is lost on hard power-off** (the *common* e-reader shutdown) | **5** — per-record fsync, no save-on-close needed, truncate-and-stop FAT recovery; worst case loses only the in-flight round |
| **Spoiler-safety rigor** | 4 — consent revoked + authoritative marker + floating gate; in-context history stays present but instruction-gated | 4 — adds explicit history-quarantine note + memory clause + paging-doc warning; still instruction-level for in-context text | **5** — actually **redacts** ahead-content from resent `messages[]` and the transcript (not just instructs); per-session consent; only approach that removes the payload |
| **UX value** | 4 — sessions travel with the book; sparse picker; viewer-title banner | 4 — survives book move/rename; Continue/New chooser kills invisible forking | 4 — resume button on existing dialog (no extra refresh); honest dropped-tail toast; consent dialog |
| **KOReader feasibility** | **5** — copies the proven `bbmemory` sidecar pattern verbatim; smallest API surface | 4 — global store + hash reuse is sound but introduces FAT rename-onto-existing handling and a debounce/lifecycle dance | 4 — NDJSON append+fsync is sound, but per-record fsync latency on cheap eMMC and the truncate-and-rewrite-on-open path are real moving parts |
| **Future extensibility** | 3 — clean base; cross-book browsing would need a redesign (sidecar is inherently per-book) | **5** — hash store is the natural substrate for the deferred cross-book library/resume; config fingerprint generalizes | 4 — event log is the richest substrate (branching/undo/export/audit all natural), but per-book sidecar limits cross-book like A |
| **Test burden** | 3 — 3 Tier-1 specs + 2 Tier-2; bounded | 4-worth-of-tests but **2** for *burden* — needs a faithful rapidjson fake, `assertWireValid`, config-drift, debounce-firing, dirty-tracking specs | **1** — the largest surface: roundtrip, torn-tail/NUL/garbage, dangling, websearch-both-directions, usage-delta, locator-merge, symmetric-spoiler, errors — 7+ new spec files |

**Aggregate read:** A is the lightest and most clearly shippable; C is the most durable and the
most spoiler-rigorous but by far the heaviest; B sits in the middle on effort while owning the
config-drift problem the other two underweight and the cross-book future the other two can't reach.

---

## 3. Spoiler-position-drift handling — head to head (the crux)

All three agree on the foundation: **the live `grep`/`read`/`book_context` gate is never
subverted** (it recomputes `currentPage(ui)` fresh, and `max_page` only tightens), so the
**forward** direction (reader advanced) is benign and at worst over-blocks. All three correctly
identify that **page integers are reflow/font/device-dependent** and use **xpointer**
(`getPageFromXPointer` / `compareXPointers`) as the device-stable drift oracle, never a stored
page number. The real divergence is the **backward** case — the reader resumes a chat that
discussed chapter 9 while now sitting at chapter 2 — where the *frozen history itself* (prior
tool_result quotes, prior answers, the stale seed `book_context`, and ahead-written memory notes)
is a spoiler surface the live gate cannot touch.

| Mechanism | A — Sidecar | B — Global | C — Journal |
|---|---|---|---|
| Drift oracle | xpointer→page via `getPageFromXPointer`; compares xpointer-derived pages | `compareXPointers(stored, live)`; unresolved ⇒ quarantine | `compareXPointers`; unresolved ⇒ backward (conservative) |
| Forward (advanced) | authoritative marker raises `max_page` (fixes over-block) | live gate allows more; light position note | seed `book_context` rewritten in place; re-anchor only on chapter+ advance |
| Backward — in-context history | **instructed**: `<resume_context>` marker forbids re-quoting prior content + `spoiler=true` | **instructed**: explicit history-quarantine note ("treat our own prior messages as spoiler surface") | **redacted**: stored `tool_result`s whose furthest-drawn position is ahead of the live one (xpointer oracle `max_referenced_xp`, page fallback) replaced with a structural stub — payload removed from resend but **stashed reversibly** in the checkpointed taint map |
| Prior `spoiler=true` consent | **revoked unconditionally**; must be re-requested | reset; quarantine note forbids re-issuing | redacted unless reader picks "Reveal everything"; **consent does not travel** (and redaction is reversible — originals ride the checkpoint and auto-restore when the reader catches up) |
| Frozen highlighted passage | instruction-gated on rewind | covered by quarantine note | covered by redaction + transcript re-gate |
| Memory-note leak (ahead notes) | not explicitly addressed | quarantine note names memory notes as gated too | memory-spoiler note injected into seed |
| Transcript replay on screen | banner in viewer title; history visible (accepted) | gated behind backward/paging ConfirmBox; pickers preview titles only | re-derived from **already-redacted** messages ⇒ stub shows on screen too |
| Paging docs (nil page) | **never persisted** — `_persist` requires a resolvable xpointer, so the feature is silently absent for paging docs (no stale session can resurface, but PDF readers get nothing) | spoiler-degraded class: ConfirmBox + always-quarantine | `position_unavailable` ⇒ **refuse to open** until reader sets a page (closes the nil-clamp `read` hole) |
| Consent UX | none (silent revoke + visible banner) | ConfirmBox only on paging/backward | full ButtonDialog: Resume hidden / Reveal everything / Cancel |

**Verdict on the crux.** A and B are **instruction-based**: the ahead-content remains in the
resent `messages[]` and only the prompt tells the model not to use it. That is genuinely robust
because the *gate* (the real enforcement) stays floating and consent is revoked — but it relies on
the model honoring an instruction, and the transcript still **renders** the prior ahead-discussion
on screen (A accepts this; B gates it behind a ConfirmBox). **C is the only approach that removes
the payload**: it redacts ahead-drawn tool_results out of both the resent history and the
re-derived transcript, so even a misbehaving model has nothing to re-quote, and the screen shows
the stub. C also uniquely closes the **nil-page `tool_read`** hole by refusing to resume a session
when the live position is unresolvable (with restored locators that hole is reachable). The cost is
that C's redaction is only as precise as `bb_meta.max_referenced_xp`/`max_referenced_page` (a
per-result furthest-position estimate that could under-report a sliver — the xpointer oracle
removes the layout-drift failure mode a raw page comparison would have), backstopped by the
consent dialog; redaction is reversible (originals stashed in the checkpointed taint map, so
"Reveal everything" and catch-up restoration work at any generation). B uniquely brings **memory
notes** and **config drift** into the same reconciliation pass.

Net: **C is the most rigorous** (payload removal + nil-page refusal), **B is the most complete on
the adjacent leaks** (memory + transcript-replay consent + config drift), **A is the leanest
defensible posture** (floating gate + consent revoke + marker) and is sufficient for the common
forward case but leaves backward leaks at the instruction level.

---

## 4. Recommendation

**Ship A first; evolve toward B's storage substrate; adopt C's redaction only where it pays for
itself.**

### Why A first

1. **Smallest, lowest-risk diff with the highest feasibility.** A is a near-verbatim copy of the
   already-shipped, already-audited `bbmemory.lua` sidecar pattern. It adds one new module
   and four well-identified save sites, with **zero refactoring of existing conversation logic** and
   `bbtools.lua` untouched. That is the cheapest way to deliver the core promise (survive restart,
   resume the current book) and the least likely to regress the wire-format invariants that all
   three depend on.
2. **Sessions travel with the book for free.** Living in `.sdr` means sessions inherit the reader's
   existing sidecar-location setting and Syncthing sync with no new mechanism — and on the *same*
   spoiler-relevant axis as memory, which already lives there. B's global store is strictly better
   for book-move survival but worse for "open this book on my other synced device and my chats are
   there."
3. **Its spoiler posture is defensible today.** The floating gate + unconditional consent revoke +
   authoritative `<resume_context>` marker handles the common forward case fully and makes the
   backward case safe-by-default (the *enforcement* gate never widens; only the model's habit needs
   suppressing). The residual (in-context text remains, transcript renders it) is real but is a
   *reader-initiated* reopen of their own chat.
4. **Lowest test burden** gets the feature validated and in users' hands fastest.

### Why not B or C as the first ship

- **B's debounce window is lost on hard power-off**, which is the *common* e-reader shutdown mode,
  and B carries a global-store + config-override + lifecycle state machine that is more surface than
  the first release needs. Its genuinely important contribution — **config-drift reconciliation** —
  is orthogonal to the storage choice and can be lifted into A.
- **C is the right *eventual* spoiler model but the wrong first step**: it is the largest diff
  (two new modules, journal writes threaded through five call sites, `Tools.execute` return-shape
  change, transcript re-derivation) and the largest test burden (7+ new spec files including
  FAT-torn-tail and symmetric-spoiler suites). Shipping it first maximizes the chance of a
  wire-format regression and delays the feature.

### Phased path

- **Phase 1 (ship): Approach A**, with two cheap, high-value steals folded in from the start
  (see §5): (a) **B's config-fingerprint thinking-drift reconciliation** — it is a *guaranteed
  400*, not a nicety, so it must not wait; (b) **C's nil-page-position refusal on resume** — a few
  lines that close a real leak when restored locators are present.
- **Phase 2 (durability): per-turn journaling under A's sidecar.** If field reports show the
  per-terminal-save model losing in-flight turns on crash often enough to matter, adopt C's
  append-only NDJSON + checkpoint durability *within the existing per-book sidecar layout* (C
  already targets `.sdr/bookbuddy_sessions/`). This is an additive durability upgrade, not a
  storage migration.
- **Phase 3 (spoiler hardening): C's history redaction**, introduced behind the consent dialog,
  once `bb_meta.max_referenced_page` instrumentation (C §5.3a) is in and validated on real
  device. Until then, A's instruction-level posture + revoked consent is the backstop.
- **Phase 4 (cross-book), only if demanded: migrate to B's hash store.** Cross-book browsing/resume
  is the one thing the sidecar model structurally cannot do well. If users ask for it, B's
  content-hash store is the substrate; the blob schema is close enough to A's that a one-time
  migration is tractable. Do not pay for this until the demand is real (all three specs correctly
  defer the cross-book library).

This sequence ships value fast on the safest base, defers the heavy machinery until evidence
justifies it, and keeps every step additive.

---

## 5. What to steal from the non-chosen approaches

**From B (adopt into Phase 1 / Phase 4):**
- **Config-fingerprint + `_effectiveConfig` per-conversation overrides (B §9.3).** *Mandatory in
  Phase 1.* Storing `{enable_thinking, enable_web_search, enable_memory, model}` and reconciling
  before any resend fixes a **guaranteed Anthropic 400** when `enable_thinking` is toggled off
  between save and resume (stored `thinking` blocks with no `body.thinking`). A's spec does not
  cover this; it is not optional.
- **Continue / New chooser on the primary entry (B §5.3).** Eliminates *invisible forking* (silently
  starting a new chat when the user meant to continue), which B correctly names as the real
  data-loss mode. Cheap to add to A's `main.lua`.
- **Deep-copy snapshot for serialize (B `_snapshotForPersist`, C7).** A's serialize already deep-copies;
  keep B's explicit framing that **serialize must never mutate the live (still-running) conversation**.
- **The hash store itself (B §3.2/§4)** — the Phase 4 cross-book substrate.
- **Honest cold-cache usage caveat (B §9.5):** the first resumed turn has a cold prompt cache, so
  `cache_read≈0` and `input` is full; this is a display divergence, not a billing error. Document it
  rather than resetting usage (which would hide real spend).

**From C (adopt into Phase 2 / Phase 3):**
- **Per-record append + fsync durability (C §5.1).** The Phase 2 durability upgrade — no
  save-on-close moment, lose at most the in-flight round, truncate-and-stop FAT recovery. This is
  strictly more robust than any save-at-terminus model and is the answer if A's crash-loss profile
  proves inadequate.
- **History redaction with `bb_meta.max_referenced_xp` (C §8.C/§8.E).** The Phase 3 spoiler
  upgrade — the only mechanism that *removes* ahead-content from the resent history and the
  transcript rather than instructing around it. Adopt it with C's two hard-won requirements: the
  **xpointer oracle** (a raw page comparison is layout-dependent and can under-redact after a font
  change) and **reversible stashing of redacted originals in persisted state** (irreversible
  stub-only redaction destroys reader data the moment the redacted history is re-saved). Requires
  C's read-only `Tools.execute` meta instrumentation (C §5.3a), which is itself a clean, low-risk
  addition worth landing early.
- **nil-page-position refusal on resume (C §8.A).** *Adopt in Phase 1.* With restored locators
  present, `tool_read`'s `if cur then` clamp leaves an unclamped-read hole when `currentPage` is nil;
  refusing to open a resumed session until the reader sets a real position closes it for a few lines.
- **`Wire.healWebSearch` extended to reverse-orphans (C §5.2).** Extracting the web-search pairing
  into one shared module and healing *both* directions on *every* restored assistant message closes a
  `validateMessages` gap that the last-message-only `_dropDanglingTail` misses for mid-history
  records. Worth doing whenever multi-checkpoint/replay land (Phase 2).
- **Explicit consent ButtonDialog (Resume hidden / Reveal everything / Cancel, C §8.G).** The right
  UX for the genuinely risky backward-resume path; pair it with redaction in Phase 3.

**Common to keep from all three (already aligned in A):** xpointer as the drift oracle (never a
stored page int); the floating live gate untouched; `*.sync-conflict-*` filtering and random-suffix
ids for Syncthing safety; schema-version gating with no migration chain until a real installed base
exists; default-ON because journaling/sessions spend zero API tokens (unlike memory).
