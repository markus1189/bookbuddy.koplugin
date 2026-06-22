## 1. Serialization foundation

- [ ] 1.1 Add a busted spec asserting a `messages` array with a thinking block round-trips
      through `rapidjson` (save→load) with its `signature` field byte-identical
- [ ] 1.2 Add a busted spec asserting a message whose content is an empty list serializes as
      `[]` (not `{}`) and reloads as a resendable array
- [ ] 1.3 Choose and pin the `rapidjson` encode option (empty-table-as-array) or a sentinel
      so 1.1–1.2 pass; document the choice in a load-bearing comment

## 2. `bbchats.lua` store module

- [ ] 2.1 Create `bbchats.lua` with `Chats.baseDirForBook(ui)` returning
      `<sidecar>/bookbuddy_chats` (nil when no sidecar), mirroring `Memory.baseDirForBook`
- [ ] 2.2 Implement `Chats.save(ui, state)`: assign an id (`os.time()` + monotonic suffix) if
      absent, write `<id>.json` payload first, then upsert the `index.json` metadata entry
- [ ] 2.3 Implement `Chats.list(ui)`: read `index.json` only, returning metadata rows sorted
      newest-first; fall back to scanning payloads if the index is missing/corrupt
- [ ] 2.4 Implement `Chats.load(ui, id)` returning the full payload state
- [ ] 2.5 Implement `Chats.delete(ui, id)` (payload + index entry) and `Chats.clear(ui)`
- [ ] 2.6 Implement `Chats.prune(ui, n)`: keep the newest N by `ts_updated`, unlink the rest;
      run it at the end of `save` and never evict the just-saved chat
- [ ] 2.7 Add a `Chats.title(state)` helper deriving a codepoint-safe title from the first
      user question (reuse the `splitToChars`/`clip` truncation idiom)
- [ ] 2.8 Busted specs for save/list/load/delete/clear/prune, including the per-book
      isolation and the N-cap eviction (oldest dropped, just-saved retained)

## 3. Conversation persistence hook

- [ ] 3.1 Extend `Conversation:new` to accept `opts.resume_state` and, when present, restore
      `messages`/`transcript`/`usage`/`id` instead of starting empty
- [ ] 3.2 Add `Conversation:_persist()` that strips derived display caches
      (`_md_src`/`_md_out` and other `_`-prefixed transients) from a transcript copy and
      calls `Chats.save(ui, state)`; no-op when `Chats.baseDirForBook` is nil
- [ ] 3.3 Call `_persist()` from `Conversation:_render` so every completed turn saves; verify
      a turn-one failure (no `_render`) writes nothing
- [ ] 3.4 Busted specs: a completed turn produces a stored chat ending on the assistant
      answer; a turn-one error produces no payload; a follow-up overwrites the same id

## 4. Resume flow

- [ ] 4.1 Add the load→reconstruct→render path (build `Conversation` with `resume_state`,
      then `_render` in reply mode)
- [ ] 4.2 Busted spec: reopening a stored chat shows prior turns including a client-tool line
      with its outcome summary, and a follow-up resends the restored history under the same id

## 5. Menu & settings wiring

- [ ] 5.1 In `main.lua:addToMainMenu`, insert a "Chat history" submenu after "Chat about this
      book", building `sub_item_table` from `Chats.list(ui)`: row = `title · relative-time`,
      tap = resume (section 4), long-press = delete via `ConfirmBox`
- [ ] 5.2 Add a trailing "Clear all chats" row calling `Chats.clear(ui)` behind a `ConfirmBox`
      (mirror `Settings:showMemory`'s "Clear memory")
- [ ] 5.3 Show an empty-state row when `Chats.list(ui)` is empty
- [ ] 5.4 Add `max_saved_chats = 20` to `DEFAULTS` and a number editor in `Settings:getMenu`;
      thread the value into `Chats.prune`

## 6. Gate & docs

- [ ] 6.1 Run `nix run .#check` (stylua + luacheck + busted) and fix any drift
- [ ] 6.2 Update `AGENTS.md`/`README` to document chat persistence, the
      `bookbuddy_chats` sidecar layout, and the `max_saved_chats` setting
