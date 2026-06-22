## Why

A BookBuddy conversation lives only as a local variable in `promptAndStart`: when the
viewer closes (or the book closes, or KOReader restarts), the `Conversation` is
unreferenced and garbage-collected. Every exchange evaporates. The only persisted state
today is `bbmemory` — a *model-curated* note store, not the chat itself — so a reader can
never reopen a past conversation, scroll back to an earlier answer, or continue a thread
after stepping away. Chats are the plugin's core artifact and they are the one thing that
isn't saved.

## What Changes

- Persist each conversation to the book's `.sdr` sidecar so chats survive viewer-close,
  book-close, and KOReader restart (mirrors how `bbmemory` already lives in the sidecar
  and travels with the book via Syncthing).
- Keep **multiple** chats per book, each saved as its own payload, browsable as a list.
- Save at a **coarse boundary** — only when a turn fully completes (`Conversation:_render`),
  so a reopened chat always shows a finished answer, never a dangling tool line.
- Add a **"Chat history"** submenu under the BookBuddy main menu (next to "Chat about this
  book"): rows of `title · relative-time`, tap to reopen-and-continue, long-press to
  delete, plus a "Clear all chats" entry.
- **Cap at N** chats per book (default 20, configurable): when a new chat is saved past the
  cap, the oldest is auto-dropped.
- Reopening a chat reconstructs the `Conversation` from its stored wire history and resumes
  the existing follow-up path — a post-restart follow-up is byte-identical to an in-session
  one.

## Capabilities

### New Capabilities
- `chat-history`: persisting conversations to the per-book sidecar, browsing/reopening/
  deleting past chats, resuming a stored chat as a live conversation, and bounding stored
  chats per book.

### Modified Capabilities
<!-- None — no existing OpenSpec specs in this repo; this is the first capability. -->

## Impact

- **New module** `bbchats.lua` — sidecar location, save/list/load/delete/clear/prune
  (mirrors `bbmemory.lua`'s shape and the `Settings:showMemory` / `Memory.summaryText`
  pattern).
- **`bbconversation.lua`** — `:_render` gains a `:_persist` hook; `:new` accepts a
  `resume_state` to restore `messages`/`transcript`/`usage`/`id`; an `id` is assigned on
  first save.
- **`main.lua`** — insert the "Chat history" submenu in `addToMainMenu`.
- **`bbsettings.lua`** — new `max_saved_chats` default (20) and a number editor in
  `getMenu`.
- **Serialization** — chats round-trip through `rapidjson`; the resent `messages` must
  preserve thinking-block `signature` fields and emit empty content lists as `[]` (not
  `{}`), or a reopened chat 400s on its first follow-up. Both become tests.
- **Storage footprint** — each book's `.sdr` grows by a bounded `bookbuddy_chats/`
  directory (≤ N payloads + a small index), which syncs with the book.
- No new runtime dependencies; `rapidjson` and `LuaSettings`/sidecar IO are already in use.
