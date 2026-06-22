## 1. Extract the reusable single-call helper (D4)

- [x] 1.1 In `bbconversation.lua`, lift the `for attempt = 1, MAX_STREAM_ATTEMPTS` block +
  `classifyAttempt` + `register_cancel` (~385-468) into a standalone function returning
  `(r, res)` with retry/backoff/classify intact. Keep `classifyAttempt` and
  `MAX_STREAM_ATTEMPTS` as the single exported source of truth (never copied).
- [x] 1.2 Leave `_dropDanglingTail` / `_clean_transcript_len` / `_trimTranscript` in `_loop`,
  refactored as injectable/optional hooks so a transcript-less caller (the child) can omit them.
- [x] 1.3 Verify the parent's own behavior is unchanged: run the existing retry/streaming specs
  before and after the extraction and confirm identical results (`nix run .#test`).

## 2. Child tool subset + `delegate` spec (D1, D5, D6)

- [x] 2.1 Add a `CHILD_TOOL_NAMES` whitelist (`{grep, read, get_toc, book_context,
  get_highlights}`) and a `Tools.getSpecs` filter to `bbtools.lua`, reusing the
  `web_search`-removal shape. Confirm `delegate`, `web_search`, and the mutators are excluded.
- [x] 2.2 Add the `delegate` tool spec to `Tools.getSpecs()`: `task` (string, required) and
  `allow_spoiler` (boolean, default false). Give it a description stating `allow_spoiler` is set
  only when the reader explicitly asked to read ahead. Ensure `delegate` has **no**
  `Tools.execute` dispatch (handled in `bbconversation`, like `web_search`).
- [x] 2.3 Gate the `delegate` spec on `enable_subagents`: when the setting is off, omit it from
  the parent's advertised specs.

## 3. The subagent driver `bbsubagents.lua` (D2, D6, D7, D8, D9)

- [x] 3.1 Create `bbsubagents.lua` with
  `runSubagent({ui, settings, cfg, task, allow_spoiler, depth, stop, set_cancel, on_status})
  -> text`. It owns its own `messages` array seeded with the researcher child system prompt, the
  task, and a fresh `book_context` (via `Tools.execute('book_context', {}, ui)`). It MUST NOT call
  `Conversation:new` (avoids the locator-state wipe).
- [x] 3.2 Implement the bounded loop (up to child `max_turns`, ~6): call `Anthropic.buildBody`
  with the child specs, invoke the single-call helper from task 1.1, parse `tool_use`, run
  `Tools.execute(name, sanitized, ui)`, append the `tool_result`, repeat until `end_turn` or the
  turn limit; return the concatenated final assistant text.
- [x] 3.3 Implement the per-call input sanitizer: when `allow_spoiler` is false, force
  `spoiler=false` and clamp `max_page <= currentPage(ui)` on every child tool input before
  `Tools.execute`; when true, pass inputs through unchanged.
- [x] 3.4 Snapshot `ui._bookbuddy_last_search` before the run and restore it after, so a child
  search cannot re-point a later parent `create_highlight{search_result=N}`.
- [x] 3.5 Enforce the depth bound: refuse to start when `depth` exceeds the allowed level.
- [x] 3.6 Report progress via `on_status` only; render no tokens and create no viewer.

## 4. Wire the `delegate` branch into the turn loop (D3, D9)

- [x] 4.1 In `bbconversation.lua`, add a `delegate` branch next to the `memory` branch (~:588):
  show one attributed `Researching: <task>…` status line via the `tool_entry` idiom (:584).
- [x] 4.2 Call `bbsubagents.runSubagent` passing `self.ui` / `self.settings` / `cfg`,
  `allow_spoiler` from the tool input, `depth = (self._subagent_depth or 0) + 1`, a `stop` closure
  reading `self.stop_requested`, and a `set_cancel` hook that saves/restores `self._cancel` around
  the child stream so a Stop aborts the child and unwinds to the parent tool boundary.
- [x] 4.3 Return the child result as the `delegate` tool_result; on child error or Stop, return a
  recoverable error tool_result the parent can continue from. Fold the result into a brief
  completion summary on the status line.
- [x] 4.4 Add a load-bearing comment at the dispatch site asserting the reentrancy invariant
  (`delegate` is only reached after the parent stream fully returned, never mid-yield; the child
  must not spin its own `Trapper:wrap`).

## 5. Settings + prompts (D10)

- [x] 5.1 Add `enable_subagents` (default off, mirroring `show_streaming_thinking`) and a child
  `max_turns` default to `bbsettings.lua`, with menu entries matching the existing toggles.
- [x] 5.2 Add the read-only researcher child system prompt (spoiler-safe, return a condensed
  answer) and a one-line parent-prompt note on when to delegate to `bbprompts.lua`.

## 6. Tests (tier-1)

- [x] 6.1 Create `tests/subagents_spec.lua` over the `tests/support/sse.lua` Stream fake + a stub
  `ui`. Assert: child tool inputs are scrubbed (`spoiler=false`, `max_page` clamped) even when the
  child prompt demands ahead-reading; `allow_spoiler=true` passes inputs through.
- [x] 6.2 Assert `delegate`, `web_search`, `navigate`, `create_highlight`, and
  `edit_highlight_note` are absent from the child specs; the five read tools are present.
- [x] 6.3 Assert `ui._bookbuddy_last_search` is restored to its pre-delegation value after a child
  search; assert the depth cap halts recursion.
- [x] 6.4 Assert a stopped/errored child yields an error tool_result the parent recovers from, and
  that intermediate child tool rounds do not appear in the parent's `messages`.

## 7. Gate

- [x] 7.1 Run `nix run .#check` (stylua + luacheck + busted) and make it green; keep the feature
  default-off.
- [x] 7.2 Run tier-2 (`nix run .#test-real`) to exercise nested-stream timing that tier-1 fakes,
  before any future change defaults the flag on.
