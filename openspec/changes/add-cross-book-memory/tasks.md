## 1. Store: mounts + read-only resolver (D1, D2, D4, D8)

- [ ] 1.1 Change `Memory.new(base_dir)` to `Memory.new(base_dir, mounts_fn)`; `mounts_fn` is an
  optional zero-arg function returning an array of `{ slug, dir, label }`. Store it on the
  instance; nil means no mounts (today's behavior, byte for byte).
- [ ] 1.2 Extend `Store:_resolve(vpath)` to return `(real, err, read_only)`. When the first
  virtual segment is `library`: no further segments → a sentinel for the library root; second
  segment must match a slug from `mounts_fn()` (else the protocol's "does not exist" wording);
  the remainder resolves inside that mount's `dir` through the **same** segment loop (`..`/NUL
  guards shared, not duplicated). All mount resolutions set `read_only`.
- [ ] 1.3 Refuse mutations: `_create`, `_strReplace`, `_insert`, `_delete` error on
  `read_only`; `_rename` errors when either endpoint is read-only. Error text (load-bearing,
  teaches the fix): `Error: <path> is read-only — /memories/library holds other books'
  memories. Files under /memories are writable.`
- [ ] 1.4 Reserve the name: `_create`/`_rename` refuse a destination at or under
  `/memories/library` even when `mounts_fn` is nil or returns none. If a **real** `library`
  entry exists in `base_dir` while mounts are active, log one warning that it is shadowed
  (comment: shadowed files stay intact on disk and reappear when the feature is off).

## 2. Store: views over mounts (D5)

- [ ] 2.1 Root `view` of `/memories`: after the real `collectTree` walk, append synthesized
  lines for `library/` and one level of slugs (same size-then-path format; slug line size = that
  mount's directory size). Only when `mounts_fn` yields at least one mount.
- [ ] 2.2 `view` of `/memories/library`: list each mount's files via `collectTree(mount.dir,
  "/memories/library/<slug>", …)` capped at the existing 2 levels, then append the legend — one
  `slug: <label>` line per mount (label = `Title — Authors (Series #N)` when known).
- [ ] 2.3 `view` of a mounted directory or file: flows through the existing directory/file code
  untouched (including `view_range`); verify no write-path helper is reachable from `view`.
- [ ] 2.4 Sort mounts same-series-first, then recency (design open question resolved: yes —
  cheap and zero-risk).

## 3. Discovery (D3)

- [ ] 3.1 Implement `Memory.libraryMounts(ui)`: iterate `require("readhistory").hist`
  (newest first); per entry resolve `DocSettings:getSidecarDir(file) .. "/bookbuddy_memory"`;
  keep existing, non-empty dirs; skip the current book by comparing against
  `Memory.baseDirForBook(ui)` (resolved paths, not titles); cap at 50.
- [ ] 3.2 Labels from `DocSettings:open(file):readSetting("doc_props")` (title, authors,
  series incl. trailing `#N`); fallback to the file basename. Never `flush()` these read-only
  DocSettings objects (comment this — an accidental flush rewrites a foreign sidecar).
- [ ] 3.3 Slugs: title lowercased, non-alphanumeric runs → `-`, trimmed, ≤ 60 chars, empty →
  `book`; dedup collisions with `-2`, `-3`, … in mount order.
- [ ] 3.4 Call `mounts_fn` lazily per command that needs it (root view, any `library` path) so
  mid-conversation syncs appear; no caching on the Store beyond the single command.

## 4. Wiring: spec, conversation, settings, prompts (D5, D7, D8)

- [ ] 4.1 `Memory.spec(include_library)`: when true, append the description paragraph — what
  `/memories/library` is, read-only, check it when the question spans the reader's other books
  (esp. earlier books in a series), and that memories from later books are spoilers for this
  one. When false, description identical to today.
- [ ] 4.2 `bbconversation.lua:311-317`: when `enable_memory` **and** `enable_cross_book_memory`
  are on, construct with `Memory.new(base, function() return Memory.libraryMounts(o.ui) end)`
  and advertise `Memory.spec(true)`; otherwise exactly the current construction.
- [ ] 4.3 `bbsettings.lua`: `enable_cross_book_memory` default **on** — defaults table,
  `getConfig()`, and a menu toggle nested with the existing memory entries.
- [ ] 4.4 `bbprompts.lua`: one line extending the spoiler contract — earlier-book memories are
  fair game; later-book (series-order) memories are past-the-reader's-position content.
- [ ] 4.5 `Memory.clear`/`summaryText` untouched; add the D9 invariant comment at
  `libraryMounts` (nothing writes foreign sidecars).

## 5. Tests (tier-1)

- [ ] 5.1 New `tests/memory_library_spec.lua` on the `tests/memory_spec.lua` harness (temp dirs
  via luafilesystem, stub `mounts_fn` returning fabricated `{ slug, dir, label }`).
- [ ] 5.2 Views: root listing includes `library/` + slugs when mounts exist and is unchanged
  when `mounts_fn` is nil/empty; `/memories/library` shows files + legend; mounted file `view`
  and `view_range` return contents.
- [ ] 5.3 Read-only: every mutating command against a mount path fails with the read-only error
  AND the mounted tree's bytes are unchanged (D9 assertion); `rename` refused in both
  directions; `create` at `/memories/library/...` refused with no mounts (reserved name).
- [ ] 5.4 Escapes: `..` inside a `library` path refused; unknown slug → protocol "does not
  exist" wording; slug dedup produces `-2` on collision.
- [ ] 5.5 Discovery unit test for `Memory.libraryMounts` with stubbed `readhistory`/
  `docsettings` (extend `tests/support/stubs.lua`): current book excluded by dir, empty memory
  dirs skipped, cap respected, label fallback to basename.
- [ ] 5.6 Spec/description: `Memory.spec(false)` byte-identical to today's; `Memory.spec(true)`
  mentions `/memories/library`; conversation built with the setting off never lists `library/`
  (assert via a scripted turn on `tests/support/sse.lua` if cheap, else store-level).

## 6. Gate

- [ ] 6.1 `nix run .#check` green (stylua + luacheck + busted), `tests/memory_spec.lua`
  untouched and green.
- [ ] 6.2 Decide tier-2: add a second fixture book with a pre-seeded `bookbuddy_memory` sidecar
  to exercise real ReadHistory/DocSettings resolution, or record as follow-up in the design's
  open questions. Run `nix run .#test-real` either way.
- [ ] 6.3 Consider a Tier-3 scenario (`.plans/tier3-scenarios.md`) probing D6: reading book 2
  with spoilery book-3 memories mounted, grader checks nothing leaks.
