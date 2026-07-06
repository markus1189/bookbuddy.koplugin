## Context

`bbmemory.lua` implements Anthropic's client-side memory protocol over a real directory:
`Memory.baseDirForBook(ui)` resolves `<sidecar>/bookbuddy_memory` (`:101-108`),
`Memory.new(base_dir)` wraps it in a `Store`, and `Store:_resolve` (`:119-143`) maps every
virtual `/memories/...` path into `base_dir`, refusing escapes (`..`, NUL, out-of-root). The
store is built once per conversation (`bbconversation.lua:311-317`) when `enable_memory` is on
and the book has a resolvable sidecar. The header comment records two load-bearing properties:
memory **travels with the book** (sidecar syncs via Syncthing) and is **naturally isolated per
book**. This change keeps the first and deliberately opens a one-way window through the second.

KOReader-side facts (verified against master, 2026-07-04, and recorded in
`.plans/koreader-tools-gap.md`):

- `require("readhistory").hist` — newest-first array of `{ time, file, text }` for every book
  the reader has opened; entries for missing files carry `dim = true`.
- `DocSettings:getSidecarDir(file)` locates any book's sidecar without opening the document;
  `DocSettings:open(file):readSetting("doc_props")` reads its stored title/authors/series
  metadata (cheap Lua-table load, no document open, no flush).

## Goals / Non-Goals

**Goals:**
- Reading book N, the agent can *read* the memories BookBuddy wrote for the reader's other
  books — the Red Rising 1 → Red Rising 2 case — through the same memory tool and protocol it
  already knows.
- **Zero risk to other books' data**: no command can create, modify, rename, or delete anything
  outside the current book's memory directory. Read-only must be enforced in the resolver, not
  by tool-description politeness.
- **Zero migration, zero behavior change when off**: existing memories stay where they are;
  with the setting off (or no mounts found) the store behaves byte-for-byte as today.
- The model can *identify* which mounted book is which (series name + index in a legend), since
  slugs alone can't order a series.

**Non-Goals:**
- **Shared writable memory** (e.g. a per-series notebook both books write to). It breaks the
  travels-with-the-book property (which sidecar owns it?) and adds merge semantics. A future
  change can add a writable `/memories/shared` backed by the settings dir if wanted; nothing
  here precludes it.
- Cross-*device* memory sync. That remains Syncthing's job, unchanged.
- Mounting anything other than BookBuddy memories (not other books' highlights/annotations —
  that is a tool-surface question for `bbtools`, tracked in `.plans/koreader-tools-gap.md`).
- Series detection cleverness (auto-filtering mounts to "earlier in this series"). See D6.
- Exposing the mounts in the management UI (`summaryText`/`clear` stay current-book; the other
  books' own menus manage their own memories).

## Decisions

### D1 — Read-only mounts into the existing store, not centralized storage
Cross-book access is a *view* over per-book storage: the current book's `Store` gains a mount
table mapping `library/<slug>` to other books' `bookbuddy_memory` directories. Storage location,
the management UI, and `Memory.clear` are untouched.
*Alternative considered:* move all memory to a central `DataStorage:getSettingsDir()` tree keyed
by book identity. Rejected: loses travels-with-the-book (the header comment's stated design
value), requires migrating every existing `.sdr`, and turns "delete this book's memory" from a
directory purge into an identity-matching problem (title/author/md5 drift across editions).

### D2 — Virtual layout: current book at the root, others under reserved `/memories/library/<slug>/`
The current book's files stay at `/memories` root — existing memories, and models' habits about
them, keep working. Mounts appear under one reserved first segment, `library`. Reservation
rules in `_resolve`:
- A path whose first segment is `library` resolves through the mount table (second segment =
  slug, remainder = path inside that book's memory dir), and carries a read-only marker.
- `create`/`rename` refuse a *destination* at or under `/memories/library` even when no mounts
  exist, so the name stays reserved and a real `library` dir can never be created going forward.
- A **pre-existing** real directory named `library` at the root (possible in principle today) is
  shadowed by the virtual tree; log a warning once. Accepted: the name collides only if a model
  previously chose exactly `library`, and shadowed files remain intact on disk (visible again if
  the feature is toggled off).
*Alternative considered:* an unlikelier reserved name (`/memories/.library`, `/memories/other-books`).
Rejected: hidden-dotted paths are excluded by the existing tree walk (`collectTree` skips
dotfiles, `:197`), and `library` is the name the model will use correctly without prompting.

### D3 — Discovery: ReadHistory scan, lazy, capped, current book excluded
`Memory.libraryMounts(ui)` iterates `ReadHistory.hist` (newest first), and for each entry
resolves `DocSettings:getSidecarDir(file) .. "/bookbuddy_memory"`, keeping directories that
exist and contain at least one file. The current book is excluded by comparing **resolved base
dirs** (not titles — same title, different editions must not self-mount). Labels come from the
sidecar's stored `doc_props` (title, authors, series with its trailing "#N" index) with the
file basename as fallback. Cap at the 50 most recent qualifying books. Slugs: title lowercased,
non-alphanumeric runs → `-`, trimmed, max ~60 chars, collisions deduped with `-2`, `-3`, ….
The provider is called **lazily** — on each command that touches `library` (root view included)
— so a book synced in mid-conversation appears without restarting; the scan is directory stats
only, no document opens.
*Gotcha accepted:* `getSidecarDir` returns the *currently configured* sidecar location; if the
reader changed KOReader's sidecar-location setting after writing memories, old locations are not
searched. This exactly mirrors how `baseDirForBook` already behaves for the current book —
parity, not a regression.

### D4 — Read-only enforced in the resolver, refused in every mutator
`_resolve` returns `(real_path, err, read_only)`; mount-resolved paths set `read_only`.
`_create`, `_strReplace`, `_insert`, `_delete` refuse read-only paths; `_rename` refuses when
**either** endpoint is read-only (no moving files out of, into, or within a mount). The error is
protocol-style and teaches the fix: `Error: <path> is read-only — /memories/library holds other
books' memories. Files under /memories are writable.` The `..`/NUL guards apply to the mount
remainder exactly as to root paths (same segment loop — one resolver, not two). `view` (dir,
file, `view_range`) flows through the existing code unchanged, since reads never check the flag.

### D5 — The model finds mounts through the tree it already views
- Root `view` of `/memories` appends synthesized entries for `library/` and one level of slugs
  after the real `collectTree` walk (mounts are not real children of `base_dir`), matching the
  existing size-then-path line format and the "up to 2 levels" contract.
- `view` of `/memories/library` lists each slug's files (depth 2 from there) **plus a legend**:
  one line per slug — `red-rising: Red Rising — Pierce Brown (Red Rising #1)` — built from D3's
  labels. The legend is what lets the model pick the *predecessor* rather than a sequel.
- `Memory.spec(include_library)` appends one description paragraph when the feature is on:
  what `/memories/library` is, that it is read-only, check it when the question spans earlier
  books, and that later-book memories are spoilers here. When off, the description is unchanged
  so the model is never taught a path that will 404.

### D6 — Spoiler handling is prompt-level, not structural
Memories from *Morning Star* can spoil *Golden Son*. We do **not** filter mounts by series
order. Rationale: series metadata is too unreliable to act on silently — missing `series`
fields, unnumbered series strings, same-world-different-series books — and a wrong guess hides
exactly the book the feature exists for, with no error surface. Instead: the legend carries
series name + index so direction is *visible*, and `bbprompts` gets one line extending the
existing spoiler contract (memories from books later in a series are past-the-current-page
content; from earlier books, fair game). This mirrors how `web_search` spoilers are already
handled — the agent knows things it must not say.
*Alternative considered:* mount only `series_index < current`. Rejected as above; revisit as an
opt-in tightening if Tier-3 evals show leakage.

### D7 — `enable_cross_book_memory`, default on, nested inside `enable_memory`
No mounts are built and the spec paragraph is omitted unless both `enable_memory` and
`enable_cross_book_memory` are on. Default **on**: the feature costs nothing until the model
actually views a mounted file, and the reader value (series continuity) is the common case. The
honest cost is privacy-shaped — the root `view` listing reveals other books' *titles* (as slugs)
to the API on conversations where the model checks memory — and the menu toggle exists exactly
for readers who weigh that differently.
*Alternative considered:* default off like `enable_subagents`. Rejected: subagents double-bill
every delegated turn; this adds a few listing lines. A silent default-off would mean the flagship
use case (book 2 of a series) never happens for readers who don't spelunk menus.

### D8 — `Memory.new(base_dir, mounts_fn)`; provider injected at the construction site
The Store never touches ReadHistory/DocSettings itself: it calls `mounts_fn()` (nil → no mounts,
today's behavior) each time a `library` path or root view needs it. `bbconversation.lua:311-317`
passes `function() return Memory.libraryMounts(ui) end` when D7's gates are on, and
`Memory.spec(true)`. Tier-1 tests pass a stub returning temp dirs — no KOReader singletons in
the store's test path, keeping `tests/memory_spec.lua`'s harness shape.

### D9 — Nothing ever writes a foreign sidecar (invariant, tested)
`Memory.clear` purges `baseDirForBook(ui)` only; mounts are resolved fresh per command and never
cached into any write path. The tier-1 spec asserts every mutating command against a mount
leaves the mounted directory's contents byte-identical.

## Risks / Trade-offs

- **Title-derived slugs can be ambiguous** (translated editions, "Book 1" titles). Mitigated by
  the legend (full title + authors + series) and dedup suffixes; the model reads the legend, not
  just slugs.
- **History without sidecar-memory is invisible** — books read before BookBuddy existed have no
  memories to mount. Correct behavior, worth remembering when judging "why doesn't it see
  book 1": book 1 must have been read *with memory enabled*.
- **Large libraries** make the root listing longer (one line per mounted book). Capped at 50;
  if that's still noisy, a follow-up can list only `library/` at the root and defer slugs to
  the `library` view.
- **Later-book spoilers** rely on the prompt contract (D6). Tier-3 scenario should probe it.

## Open Questions

- Should the legend (or mounts themselves) prefer same-series books first? Cheap to sort
  (series match → recency), zero risk — default to yes at implementation time.
- Tier-2 (`test-real`) coverage: `juliet.epub` is a single book; a second fixture book with a
  pre-seeded memory dir would let tier-2 exercise ReadHistory + DocSettings for real. Decide
  when writing tasks 5.x whether the fixture cost is worth it now or a follow-up.
