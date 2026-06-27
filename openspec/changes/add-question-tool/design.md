## Context

BookBuddy is a single tool-using agent. `bbconversation.lua` runs the whole turn loop inside one
`Trapper:wrap` coroutine (`:370`). Each Claude call streams from a forked subprocess
(`bbstream.lua`); tool calls then execute **in-process** at the dispatch site (`:656-687`),
which special-cases `memory` and `delegate` (`:671-677`) and otherwise calls
`Tools.execute(name, input, ui)`. The loop already knows how to **park its own coroutine and be
resumed from a UI callback**: `backoff` (`:177-191`) captures `coroutine.running()`, schedules a
one-shot resume, and `coroutine.yield()`s. There is exactly one cancel slot (`self._cancel`) and
the loop honors `self.stop_requested` at each UI-boundary yield.

Today the only reader input is **between** turns: the Reply dialog (`_promptFollowup`,
`:1141-1175`) calls `self:ask()` to start a *new* turn. There is no way for the agent to obtain a
single disambiguation **inside** a turn and keep going. A clarifying-question tool closes exactly
that gap by reusing the coroutine-park idiom at the tool-dispatch site.

## Goals / Non-Goals

**Goals:**
- A mid-turn `ask_user` tool: the agent asks one disambiguating question, the loop parks, the
  reader answers with a button or free text, and the **same turn** continues with the answer as
  the tool result.
- An absolute **no-hang** guarantee: no dialog close path can leave the coroutine parked, and no
  `ask_user` `tool_use` can be left unanswered in the wire history.
- Spoiler-safety with **no new surface**: the question/options are bound by the same contract as
  the answer; nothing structural to add.
- The smallest honest diff: one new spec entry, one dispatch branch + one method, one setting,
  one prompt note — no surgery on the streaming/retry core.

**Non-Goals:**
- A standalone modal/wizard UI or multi-question forms. One question, optional flat option list,
  optional free text. (Claude Code's single-question shape, not a survey.)
- Structured/typed answers back to the model. The `tool_result` is a plain string, like every
  other tool result (`:681-686`); the model re-reads it.
- Calling `ask_user` from a subagent. A child is headless with no reader at the keyboard; the tool
  is stripped from `Tools.childSpecs()`.
- Reworking between-turn input. `_promptFollowup` stays exactly as is; `ask_user` is orthogonal
  (in-turn, tool-driven) and shares only the `InputDialog` construction shape.
- Letting `ask_user` read or reveal book content beyond what the answer already may — it carries
  no book data; it only echoes the model's own question text.

## Decisions

### D1 — Question-as-a-tool, special-cased in `bbconversation` (no executor)
Add one `ask_user` tool (`question: string` required, `options: array<string>` optional). On an
`ask_user` `tool_use`, the dispatch loop branches to `Conversation:_askUser` exactly as it
branches to `memory`/`delegate` (`:671-677`). Like `delegate`/`web_search` it has **no `DISPATCH`
entry and no `Tools.execute` executor**: the tool needs the live conversation coroutine and the
viewer, which `bbtools.lua` must never import (and `Tools.execute` runs with only `(name, input,
ui)`, no coroutine contract). A load-bearing comment on the spec points at the branch.
*Alternative considered:* a placeholder `tool_question` executor in `DISPATCH` that errors —
rejected; it invites a future caller to dispatch `ask_user` through `Tools.execute` off the
conversation coroutine, where the park would deadlock. No executor = the only legal path is the
branch.

### D2 — Park the conversation coroutine with the `backoff` yield/resume idiom
`_askUser` reuses the proven shape from `backoff` (`:177-191`): capture `co =
coroutine.running()`, build the dialog whose button callbacks set the chosen answer and perform a
**one-shot** `coroutine.resume(co)`, `UIManager:show` the dialog, then `coroutine.yield()`. The
button callback runs on the `UIManager` event loop (main thread) and resumes the parked loop with
the answer in scope — identical to how `scheduleIn` resumes `backoff`. No new concurrency
primitive is introduced.

### D3 — Reentrancy invariant: parking here is legal
The dispatch site (`:656`) is reached **only after** the parent stream has fully returned — the
coroutine is parked at an ordinary call site, never mid-yield (the same invariant `delegate`
already documents and depends on at `:881-886`). Therefore yielding **again** from `_askUser` to
await the dialog is legal and re-entrant-safe. A load-bearing comment at the `ask_user` branch
records this, so a future refactor that moves tool dispatch into a mid-yield position is flagged
as the deadlock it would be.

### D4 — No-hang is enforced by a one-shot guard wired into EVERY close path
The single worst failure is a dialog that closes without resuming the coroutine: the agent
freezes with no error, no Stop target, and a half-built turn. The guard:
- A local `resumed=false` one-shot (the `backoff` `resumed` pattern); the resume helper sets it
  and resumes at most once.
- **Every** close path calls that helper: each option button, the "Type my own…" Send **and**
  Cancel, the "Skip" button, **and** the dialog's dismissal hook (tap-outside / Back). KOReader
  modals can be dismissed without pressing a custom button, so the dismissal path MUST resume
  with the Skip sentinel — it is not optional.
This is asserted in a load-bearing comment and pinned by a tier-1 test that closes the dialog via
the dismissal path and asserts the loop resumes (rather than hanging the spec's coroutine pump).
*Alternative considered:* a non-dismissable modal — rejected; KOReader's dismiss is reachable in
practice and "make it impossible to dismiss" is more fragile than "every close resumes."

### D5 — The tool result is always a plain string; the tool_use is always answered
`_askUser` returns the chosen option text, or the typed text, or — on Skip/dismiss — a short
recoverable note (`"[The reader skipped the question without answering.]"`). The dispatch loop
appends it as the `tool_result` for `tu.id` exactly like every other tool (`:681-687`), so the
`[assistant tool_use][user tool_result]` pair is always balanced and resendable. An unanswered
`ask_user` `tool_use` would dangle and 400 on the next resend — the same failure
`_dropDanglingTail` / the web_search pairing comments already guard; the Skip-returns-a-note rule
makes that state unreachable. The model treats the note like `delegate`'s "did not complete"
result: apologize, proceed on a best guess, or ask differently.

### D6 — Spoiler-safety rides the existing answer contract; no new boundary
`ask_user` carries **no book content** — it echoes the model's own `question`/`options`, which are
reader-facing text rendered verbatim, exactly like the streamed answer. The system prompt's
spoiler rule already governs everything the model says to the reader, so it already governs the
question text. The change adds one reinforcing sentence ("a clarifying question you ask is shown
to the reader verbatim — it is bound by the same spoiler rule as your answer; never phrase a
question so it reveals something past the reader's position"). There is nothing structural to
scrub because, unlike `delegate`, no tool input crosses a position boundary here.
*Alternative considered:* routing the question text through a spoiler reviewer — rejected as
over-engineering for v1; the question is no more dangerous than the answer, which has no reviewer
either.

### D7 — Dialog shape: options → buttons; always Type-my-own + Skip; no options → free text
With `options`, build a `ButtonDialog`-style stack: one button per option (vertically stacked so
long option labels are readable on a small screen), then a row with **"Type my own…"** (opens the
free-text `InputDialog`, reusing the `_promptFollowup` construction at `:1141-1175`) and
**"Skip"**. With no `options`, go straight to the free-text `InputDialog`. The model is told in
the spec to keep `options` short (2–4 concise labels) and that the reader can always type instead,
so it should not try to enumerate every case.

### D8 — Transcript: an attributed status line that folds to the answer
Before showing the dialog, append a `tool_entry` (`role="tool"`, `text="Asked: <question>"`) and
`_flushNow()` so it paints behind the modal (the `:667-680` idiom). On resume, fold the outcome
into the same line: `— "<chosen option>"`, `— "<typed answer>"` (truncated), or `— skipped`. The
viewer thus shows a faithful record of the Q and the reader's A inline in the turn, consistent
with how `grep`/`delegate` rounds render.

### D9 — Stop semantics
While the modal is up the global Stop button is not visible (the loop is not streaming); the
in-modal **Skip** is the reader's escape and resolves to the recoverable note (D5). If a Stop was
already buffered (`self.stop_requested`) when the branch is reached, `_askUser` still answers the
`tool_use` with the Skip note first (keeping history balanced, D5), and the loop's next
UI-boundary yield (`:417` region) honors the Stop and unwinds cleanly — no special-case unwind
inside `_askUser`. The single `self._cancel` slot is untouched: `ask_user` forks no stream, so
there is nothing to cancel and nothing to save/restore (unlike `delegate`).

### D10 — Default-on gate + child exclusion + prompt guidance
`enable_clarifying_questions` defaults **on** (it costs no extra tokens and adds no spoiler
surface — the cautious default-off precedent for `enable_subagents`/`show_streaming_thinking`
exists because *those* spend tokens or risk spoilers, neither of which applies here; a guessing
agent is strictly worse than one that can ask). When off, `ask_user` is omitted from the parent
specs in `Conversation:new` (the `:267-285` removal shape). It is **always** excluded from
`Tools.childSpecs()` regardless of the setting — a headless subagent has no reader to ask.
`bbprompts.lua` gains a short note: ask only about genuine ambiguity in what the *reader* wants
(which character, how far back, which interpretation), never about facts you can settle by reading
the book, and never gratuitously (one question, then act).

## Risks / Trade-offs

- **[Coroutine hang on an unhandled close path]** → The single highest-severity risk. Mitigated by
  D4: a one-shot `resumed` guard wired into every option button, the typed Send/Cancel, Skip, and
  the dismissal hook, pinned by a dismissal-path tier-1 test. Reviewed as the load-bearing
  invariant.
- **[Dangling `ask_user` tool_use]** → A Skip/dismiss that returned nothing would leave an
  unanswered `tool_use` that 400s on resend. Mitigated by D5: Skip/dismiss always returns a note,
  so the pair is always balanced; covered by a test asserting the `tool_result` is present after a
  Skip.
- **[Reentrancy assumption breaks]** → Parking in `_askUser` is legal only because the dispatch
  site is never mid-yield (D3). A future refactor could violate that. Mitigated by the
  load-bearing comment mirroring `delegate`'s; tier-2 exercises real coroutine timing tier-1 fakes.
- **[Over-asking]** → The model may interrupt with questions a quick read would answer, which is
  more annoying on e-ink than on a desktop. Mitigated by the prompt guidance (D10) and the
  default-on-but-toggleable gate; tunable at tier-3.
- **[Spoiler in the question text]** → A carelessly phrased question could leak ahead. Mitigated by
  D6's prompt reinforcement; it is no greater a risk than the answer itself, which is already
  prompt-governed.
- **[`max_turns` accounting]** → The `ask_user` round increments the loop's iteration count like
  any tool round, so a turn that asks then works has one fewer substantive round before the cap.
  Acceptable for v1 (questions are rare and bounded by the reader); revisit only if the cap is hit
  in practice.

## Migration Plan

- Ship behind `enable_clarifying_questions`. It defaults **on**, but the toggle means any reader
  who finds mid-turn questions intrusive can disable it, and the rollback is flipping the default
  to off (the tool vanishes from the specs) without code change.
- No data migration: no new persisted state, no sidecar change, no wire-format change beyond one
  more tool name the model may emit.
- Validate with `nix run .#check` (tier-1) — note tier-1 stubs the dialog and the `Stream`, so the
  real coroutine-park-under-a-live-modal timing is only exercised at tier-2
  (`nix run .#test-real`); run tier-2 before relying on the default-on behavior in a release.

## Open Questions

- **Default on vs. off** — shipped **on** here on the reasoning above (no token/spoiler cost). If
  early use shows the model asking too eagerly on e-ink, flip the default to off and lean on the
  prompt; this is the one genuine product call and is cheap to reverse.
- **Free-text-only fallback** — is the "Type my own…" path worth it in v1, or do button options
  cover the real cases? Kept because a reader's true answer is often "none of those"; measure
  whether it is used.
- **Question rate** — how often the model reaches for `ask_user` when it should just read. Needs
  tier-3 measurement before any prompt tuning is locked in.
- **Should `ask_user` rounds be exempt from `max_turns`?** Deferred (D-risk); revisit only if the
  cap is observed to bite a real ask-then-work turn.
