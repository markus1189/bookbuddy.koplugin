## Context

BookBuddy is a single tool-using agent. `bbconversation.lua` holds two parallel structures:
`messages` (exact Anthropic wire format, **resent in full every turn**) and `transcript` (the
human-readable viewer log). The whole turn loop runs under one `Trapper:wrap` coroutine; each
Claude call is streamed from a forked subprocess (`bbstream.lua`) that captures
`coroutine.running()` and yields the main thread while the network runs; tool calls execute
**in-process** on the live document via `Tools.execute(name, input, ui)` (`bbtools.lua:1088`).
There is exactly one cancel slot (`self._cancel` / `bbstream.lua:61-67`) and one stall clock.

Because every turn resends the full `messages`, any wide exploration (many `grep`/`read`
rounds) permanently bloats the resent history, drives token spend, and pushes the live context
toward the 250k flag. Subagent delegation isolates that churn: a child loop does the grunt work
in its **own** `messages` array and returns only a condensed string to the parent.

This design was produced by a 5-subject Opus design panel over two rounds; the decisions below
record the resolved convergence and the two reader-decided product calls (spoiler crossing →
opt-in flag; child toolset → reads only, no web_search).

## Goals / Non-Goals

**Goals:**
- Context isolation: a delegated sub-task's intermediate tool churn never enters the parent's
  resent `messages`; only a condensed result does.
- A child with the **same reading capability** as the parent (`grep`, `read`, `get_toc`,
  `book_context`, `get_highlights`) but **no** ability to mutate, reach the web, or recurse.
- Spoiler-safety preserved across the boundary, with the reader's existing right to opt into
  reading ahead surviving delegation.
- The smallest honest diff: one clean extraction from the fragile `_loop`, a new self-contained
  module, and a flag-gated, default-off rollout.

**Non-Goals:**
- Concurrent / parallel children. The single-coroutine + single-cancel-slot + single forked
  transport make true parallelism a `bbstream` multi-fd rewrite — explicitly deferred.
- A child viewer or token-by-token child streaming (re-introduces transcript-rollback
  bookkeeping the child exists to avoid, and is itself a leak surface).
- `web_search` inside children (drags in `pause_turn` + the Vertex `server_tool_use` pairing
  dance; the chosen toolset is reads-only).
- Mutating tools in children (`navigate`/`create_highlight`/`edit_highlight_note`): the parent
  acts on the child's findings, so every side-effect stays in the parent's visible turn.
- A model-level spoiler-guard reviewer pass (a possible later, default-off follow-up).

## Decisions

### D1 — Subagent-as-a-tool: one `delegate` tool
A subagent is just another synchronous tool step. Add a single `delegate` tool (`task: string`,
`allow_spoiler: boolean` default false). On a `delegate` `tool_use`, the dispatch loop
special-cases it (like the existing `memory` branch) and calls `bbsubagents.runSubagent()`,
returning the child's final text as the tool_result.
*Alternative considered:* a standalone orchestrator object that owns multiple children —
rejected for v1; the tool form fits the existing "a tool is one synchronous step" contract with
no new lifecycle.

### D2 — Standalone driver `bbsubagents.lua`, NOT `Conversation:new`
The child is a plain function over its own `messages` array, in a new module. It MUST NOT be
built via `Conversation:new`: the constructor **clears** `ui._bookbuddy_last_search`,
`_locators`, and `_loc_seq` (`bbconversation.lua:193-196`). A child built mid-conversation would
**wipe the parent's live locator table**, silently breaking any later parent
`create_highlight{search_result=N}` or `read{from=loc:N}`. (Code-verified: this is a wipe, not a
clobber — the clearest resolved split in the panel.) The standalone driver sidesteps the
constructor entirely.

### D3 — Sequential execution on the parent's coroutine; nested stream is legal
The child reuses the parent's existing `Trapper` coroutine and runs to completion before the
parent advances. A nested `Stream.run` from inside the tool executor is legal because the tool
dispatch site (`bbconversation.lua:591`) is reached only **after** the parent's own stream has
fully returned — the coroutine is parked at an ordinary call site, not mid-yield. The child MUST
NOT spin its own `Trapper:wrap` (two Trapper coroutines both scheduling `UIManager` ticks is a
deadlock footgun). A load-bearing comment at the dispatch site records this reentrancy
invariant.
*Alternative considered:* concurrent children — deferred to D-future (multi-fd rewrite).

### D4 — Extract a reusable single-call helper from `_loop`
Lift the `for attempt = 1, MAX_STREAM_ATTEMPTS` block + `classifyAttempt` + `register_cancel`
(`bbconversation.lua:~385-468`) into a function returning `(r, res)` with retry/backoff/classify
intact, shared by parent and child. Leave `_dropDanglingTail` / `_clean_transcript_len` /
`_trimTranscript` in `_loop` as **injectable/optional** hooks — the child has no transcript and
needs none of that machinery. `classifyAttempt` and `MAX_STREAM_ATTEMPTS` stay the single source
of truth (exported, never copied).
*Alternative considered:* splitting the whole ~330-line `_loop` — rejected; read-only children
need none of its `pause_turn` / transcript bookkeeping, and a careless split desyncs wire history
from transcript (the exact bug the load-bearing comments guard).

### D5 — Read-only child tool subset (reads only, no web_search)
The child gets exactly `{grep, read, get_toc, book_context, get_highlights}` via a
`CHILD_TOOL_NAMES` whitelist / `Tools.getSpecs` filter, reusing the `web_search`-removal shape
in `Conversation:new` (`bbconversation.lua:182-188`). Mutators and `web_search` are excluded
(reader-decided). This also keeps the child loop free of all server-tool machinery: no
`pause_turn`, no `pairDanglingWebSearch`, no Vertex pairing — a flat, special-case-free loop.

### D6 — Recursion bound: strip `delegate` + depth cap
`delegate` is absent from `CHILD_TOOL_NAMES`, so the child model literally cannot emit a
`delegate` tool_use (primary bound). A `depth` parameter threaded into `runSubagent`
(`depth = (self._subagent_depth or 0) + 1`) refuses past depth 1 as a backstop.

### D7 — Spoiler boundary: live `ui` + `allow_spoiler` flag + input scrub
Three structural layers, none prompt-based:
1. **Inherited free:** the child shares the parent's live `ui`, so every child `grep`/`read`
   re-derives `currentPage(ui)` (`bbtools.lua:199,:366`). The boundary is never copied, so it
   cannot drift and correctly tracks the reader turning pages.
2. **Input scrub (default):** when `allow_spoiler` is false the executor forces `spoiler=false`
   and clamps `max_page<=currentPage` on every child tool input before `Tools.execute` — so the
   child is *structurally* unable to read ahead even if argued into it. This is a net hardening
   over today, where `spoiler=true` is always reachable.
3. **Opt-in crossing:** the parent passes `allow_spoiler=true` only when the reader explicitly
   asked to read ahead (stated in the tool description so the model doesn't set it on its own
   initiative), relaxing the scrub for that one delegation.
*Alternative considered:* a frozen integer cap on a proxy-`ui` metatable — rejected (more
surface, leak-prone if one accessor is missed, and *less* safe if the reader turns back a page
mid-delegation; a live cap only ever tightens/tracks).

### D8 — Snapshot/restore `ui._bookbuddy_last_search` around the run
A child `grep` writes `ui._bookbuddy_last_search` (`bbtools.lua:244`) and the parent's
`create_highlight` reads it (`:775`). `runSubagent` snapshots it before the run and restores it
after, so a child search cannot silently re-point a later parent
`create_highlight{search_result=N}`. In the sequential design only `last_search` needs this;
full locator isolation tables become mandatory only in the deferred concurrent design (monotonic
`_loc_seq` keys don't collide across a sequential boundary).

### D9 — Headless child with one attributed status line
The child runs with no viewer and no streaming. The dispatch branch shows one `tool_entry`
status line (`Researching: <task>…`, via the `:584` idiom) that folds into a brief summary on
return. `runSubagent` reports progress through an `on_status` callback; it never renders tokens.

### D10 — Default-off setting + prompt guidance
`enable_subagents` defaults off (mirroring `show_streaming_thinking`); when off, `delegate` is
omitted from the parent specs. A child `max_turns` (~6) bounds the loop. `bbprompts.lua` gains a
short read-only researcher child system prompt and a one-line parent note on when to delegate
(wide multi-round searches yes, trivial questions no).

## Risks / Trade-offs

- **[Single-call extraction desyncs `_loop`]** → Extract ONLY the for-attempt+classify block and
  keep `_dropDanglingTail`/`_clean_transcript_len`/`_trimTranscript` in `_loop` as optional
  hooks; verify the parent's existing retry behavior is unchanged with a before/after run of the
  retry specs.
- **[Cancel slot is single]** → `self._cancel` is one slot (`bbstream.lua:61-67`); the child must
  save/restore it via the `set_cancel` hook or the parent's cancel path is orphaned. Needs a
  focused Stop-during-child spec.
- **[Reentrancy invariant]** → `delegate` is only ever reached at the tool-dispatch site after
  the parent stream fully returned, never mid-yield. Holds today but must be asserted in a
  load-bearing comment, or a future yield in the dispatch path deadlocks the child.
- **[Token double-bill]** → Delegation bills the sub-task (child input/output) even as the parent
  context shrinks; net win depends on sub-task chattiness. Bound by low child `max_turns` and a
  prompt that discourages delegating trivial questions.
- **[Additive latency on e-ink]** → Sequential delegation freezes the parent behind one
  `Researching…` line. Mitigated by low `max_turns`, default-off, and folding the summary into
  the same line on return.
- **[Over-delegation]** → The model may delegate when it should answer inline. Mitigated by the
  depth cap, the default-off gate, and prompt discipline; tunable at tier-3.

## Migration Plan

- Ship behind `enable_subagents` (default **off**). No behavior change for existing users until
  they opt in.
- Land D4 (single-call extraction) first as an isolated, independently-valuable refactor with the
  existing retry specs green, then layer the new module and the `delegate` branch on top.
- Validate with `nix run .#check` (tier-1) — note tier-1 fakes `Stream` wholesale, so nested
  stream timing is only exercised at tier-2 (`nix run .#test-real`); run tier-2 before defaulting
  the flag on in any future change. Rollback is flipping the flag off (the tool simply vanishes
  from the specs).

## Open Questions

- **When should the parent delegate?** Prompt guidance needs tuning so it delegates wide
  multi-round searches (the context-isolation win) but answers simple questions inline (no
  double-bill). Likely tier-3 iteration.
- **Token economics in practice** — measure real delegations at tier-3 before ever defaulting the
  flag on.
- **Stop granularity** — honor a Stop only at child round boundaries (simplest) or also abort the
  child's live stream instantly via the shared `_cancel` (the `set_cancel` hook enables it but
  adds save/restore that needs its own spec). Default to round-boundary; revisit if Stop feels
  laggy.
- **Concurrent fan-out trigger** — what measured multi-angle-search pain justifies the
  `bbstream` multi-fd rewrite later. Needs real usage data first.
