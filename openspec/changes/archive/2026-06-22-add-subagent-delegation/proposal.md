## Why

BookBuddy runs one tool-using agent whose entire `messages` history is resent on every
turn. A question that needs wide exploration — "where does the narrator first doubt his
brother?", "trace every mention of the locket" — makes the agent fire a dozen `grep`/`read`
rounds, and all of that noisy intermediate churn lands permanently in the resent-every-turn
history. It inflates token spend, pushes the live context toward the 250k flag, and buries
the actual answer under tool transcripts. There is no way to do focused background work
whose mess stays out of the main thread.

## What Changes

- Add a **`delegate`** tool: the main agent hands a focused sub-task to a child agent loop
  that runs to completion and returns **one condensed string**. The child's own multi-round
  `grep`/`read` churn lives in the child's private `messages` array and never enters the
  parent's resent history — the headline win is **context isolation**.
- The child runs in a new standalone module **`bbsubagents.lua`** as a plain function over
  its own message array — deliberately **not** via `Conversation:new`, which would wipe the
  parent's live locator/search state on construction.
- Children run **sequentially** on the parent's existing `Trapper` coroutine (one coroutine,
  one cancel slot, one forked-stream transport). A nested stream is legal because the tool
  dispatch site is reached only after the parent stream has fully returned, never mid-yield.
- The child gets a **read-only tool subset**: `grep`, `read`, `get_toc`, `book_context`,
  `get_highlights`. It is **denied** the mutators (`navigate`, `create_highlight`,
  `edit_highlight_note`), `web_search`, and `delegate` itself.
- **Recursion is bounded** by stripping `delegate` from the child's tool specs (primary) plus
  a depth cap (backstop) — children have the same *reading* capability as the parent but
  cannot spawn further agents.
- **Spoiler-safety** crosses the boundary structurally: the child shares the live `ui`, so
  every child read re-derives the reader's current page. A `delegate{allow_spoiler}` flag
  (default `false`) governs crossing — when false the child's tool inputs are scrubbed
  (`spoiler=false`, `max_page<=currentPage`); the parent sets it `true` only when the reader
  explicitly asked to read ahead, preserving today's "spoiler-safe unless asked" contract.
- The child runs **headless**: no viewer, no transcript, no token-by-token streaming — just a
  single attributed `Researching: <task>…` status line that folds into a summary on return.
- Gated behind a new **`enable_subagents`** setting, **default off** (mirroring the
  `show_streaming_thinking` opt-in precedent).
- Extract the streamed-Claude-call-with-retries core out of `bbconversation.lua:_loop` into a
  **reusable single-call helper** shared by parent and child — the one piece of surgery on the
  fragile turn loop, independently valuable and tier-1 testable.

## Capabilities

### New Capabilities
- `subagent-delegation`: a `delegate` tool that runs a bounded, read-only, spoiler-safe child
  agent loop to completion and returns a condensed result, with non-recursive tool access,
  sequential execution on the shared coroutine, and an explicit opt-in for spoiler crossing.

### Modified Capabilities
<!-- None — no existing OpenSpec spec covers the tool loop or tool registry as a capability;
     this is a self-contained addition layered on the current single-agent loop. -->

## Impact

- **New module** `bbsubagents.lua` — `runSubagent({ui, settings, cfg, task, allow_spoiler,
  depth, stop, set_cancel, on_status}) -> text`: owns the bounded child loop, the read-only
  child spec subset, the per-call input sanitizer, the `ui._bookbuddy_last_search`
  snapshot/restore, and the depth cap.
- **`bbtools.lua`** — add a `delegate` spec to `Tools.getSpecs()` (`task: string`,
  `allow_spoiler: boolean` default false); add a `CHILD_TOOL_NAMES` whitelist / `getSpecs`
  filter reusing the `web_search`-removal precedent. `delegate` has **no** `Tools.execute`
  dispatch — like `web_search` it is handled in `bbconversation`, because the child needs
  `settings`/`Stream`/`cfg` that `bbtools` must not import (cycle).
- **`bbconversation.lua`** — extract the `for attempt = 1, MAX_STREAM_ATTEMPTS` block +
  `classifyAttempt` + `register_cancel` (~385-468) into a reusable single-call helper (leave
  `_dropDanglingTail`/`_clean_transcript_len`/`_trimTranscript` as injectable/optional hooks);
  add a `delegate` branch next to the `memory` branch (~:588) that shows the status line,
  calls `runSubagent`, threads `self.stop_requested` + a `set_cancel` hook, and asserts the
  reentrancy invariant in a load-bearing comment.
- **`bbsettings.lua`** — new `enable_subagents` (default off) and a child `max_turns` default,
  with menu entries mirroring the existing toggles.
- **`bbprompts.lua`** — a short read-only researcher child system prompt (spoiler-safe, return
  a condensed answer) and a one-line note in the parent prompt on when to delegate.
- **New tier-1 spec** `tests/subagents_spec.lua` — over the existing `tests/support/sse.lua`
  Stream fake + a stub `ui`.
- **No new runtime dependencies** — reuses the existing `Stream`, `Anthropic`, `Tools`,
  `LuaSettings`, and `rapidjson` machinery. Latency on e-ink is strictly additive
  (sequential); bounded by a low child `max_turns` and the default-off gate.
