## Why

Memory is per-book by construction: it lives in the open book's sidecar
(`<book>.sdr/bookbuddy_memory/`, `bbmemory.lua:101-108`) and the virtual `/memories` root maps
only into that one directory. That isolation is right for storage — memory travels with the book
(Syncthing) — but wrong as an access boundary for **series and shared-world reading**. Open
*Golden Son* and everything the agent carefully recorded while you read *Red Rising* — who
betrayed whom, what the reader struggled with, running theories, spoiler sensitivities — is
invisible. The agent re-derives (or worse, half-remembers) context it already wrote down one
book ago.

The pieces to fix this already exist. Each book's memory is just a directory next to that book;
KOReader's `ReadHistory` (`frontend/readhistory.lua`) knows every book the reader has opened, and
`DocSettings:getSidecarDir(file)` locates any book's sidecar **without opening the book**. Making
book 1's memories readable from book 2 is a mounting problem, not a storage problem.

## What Changes

- **Storage does not move.** Each book's memory stays in its own sidecar; the
  travels-with-the-book property and the existing management UI (view/clear per book) are
  untouched. No migration.
- The current book's store gains **read-only mounts** of other books' memory directories under a
  reserved virtual subtree: `/memories/library/<book-slug>/…`. The current book's files stay at
  the `/memories` root exactly as today.
- **Discovery via ReadHistory**: books from the reading history whose sidecar contains a
  non-empty `bookbuddy_memory/` directory are mounted (current book excluded). Slugs derive from
  the book's title; a legend maps each slug to "Title — Authors (Series #N)" so the model can
  tell *Red Rising #1* from *Golden Son #2*.
- **Read-only is structural, not advisory**: `view` works anywhere; `create`, `str_replace`,
  `insert`, `delete`, and `rename` (either endpoint) refuse any `/memories/library/...` path with
  a protocol-style error. No code path writes into another book's sidecar — `Memory.clear` still
  purges only the current book's directory.
- The memory tool description grows a short paragraph teaching the model that
  `/memories/library` holds read-only memories from the reader's other books, useful for earlier
  books in a series, and that later-book memories are spoiler-bound for the current book.
- Gated behind a new **`enable_cross_book_memory`** setting (inside the existing `enable_memory`
  gate), **default on**, with a menu toggle. When off, the store, the virtual tree, and the tool
  description are exactly what they are today.

## Capabilities

### New Capabilities
- `cross-book-memory`: the memory tool exposes other books' stored memories as read-only mounts
  under `/memories/library/<book>/`, discovered from reading history, labeled well enough to
  identify series predecessors, impossible to write through, and removable via a setting.

### Modified Capabilities
<!-- None — no existing OpenSpec spec covers the memory store; like add-question-tool this
     layers onto an unspecced module and specs only the new capability. -->

## Impact

- **`bbmemory.lua`** — the whole change lives here plus two wiring sites:
  - `Memory.new(base_dir, mounts_fn)` gains an optional lazy mounts provider (keeps the Store
    testable with plain temp dirs, no KOReader singletons).
  - `Store:_resolve` learns the reserved first segment `library`: resolves through the mount
    table for reads, and returns a read-only marker the mutating commands refuse on.
  - `Store:_view` synthesizes the `library/` entries into the root listing (they are not real
    children of `base_dir`) and renders the slug legend when viewing `/memories/library`.
  - New `Memory.libraryMounts(ui)`: ReadHistory scan → `{ slug, dir, label }` array.
  - `Memory.spec(include_library)` appends the library paragraph only when the feature is on.
- **`bbconversation.lua`** — the one construction site (`:311-317`) passes the mounts provider
  and the spec flag when `enable_cross_book_memory` is on.
- **`bbsettings.lua`** — new `enable_cross_book_memory` (default on): defaults table,
  `getConfig()`, menu toggle under the existing memory entry.
- **`bbprompts.lua`** — one short note: check `/memories/library` when the question spans earlier
  books (same series/author); memories from *later* books are spoilers for this one.
- **New tier-1 spec** `tests/memory_library_spec.lua` (temp dirs via luafilesystem, stub mounts
  fn); `tests/memory_spec.lua` untouched and must stay green — the no-mounts path is the
  existing behavior, byte for byte.
- **No new runtime dependencies** — `ReadHistory` and `DocSettings` are already in-tree KOReader
  modules (`bbmemory` already requires `DocSettings`).
