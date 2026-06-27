## Why

BookBuddy's agent has only two ways to deal with an ambiguous request, and both are bad. It
can **guess** — "the brother" when the book has three, "earlier" without knowing how much
earlier — and a wrong guess wastes a full streamed turn plus the tool rounds under it. Or it
can **punt the ambiguity back as prose** ("Did you mean Tom or his brother Sid? Let me know")
and *end its turn*, which on an e-reader means the reader has to re-open the Reply dialog and
type a free-text answer before anything happens. Neither path lets the agent pause **mid-turn**,
get one cheap disambiguation, and keep working in the same turn — the exact move
opencode / Claude Code / pi expose as an "ask the user a question" tool.

The mechanism this needs already exists in the tree: `_loop` pauses its own coroutine and
resumes it from a UI callback today (the `backoff` yield/resume at `bbconversation.lua:177-191`),
and the tool-dispatch site already special-cases non-`Tools.execute` tools (`memory`,
`delegate` at `:671-677`). A clarifying-question tool is those two patterns combined: a tool
step that shows a dialog, parks the coroutine, and resumes with the reader's choice as the
tool result.

## What Changes

- Add an **`ask_user`** tool: the agent calls it with a `question` and an optional short list of
  `options`; the turn loop shows a KOReader dialog, **parks the conversation coroutine**, and
  resumes with the reader's pick (or typed text) as the `tool_result`. The agent continues the
  **same turn** with the ambiguity resolved — no turn ends, no re-prompt.
- The tool is **special-cased in `bbconversation` like `memory`/`delegate`**, not given a
  `Tools.execute` executor: it needs the live conversation coroutine and the viewer, neither of
  which `bbtools.lua` may touch. It has **no `DISPATCH` entry**.
- The reader-facing dialog offers **one button per option**, plus a **"Type my own…"** path
  (an `InputDialog`, reusing the `_promptFollowup` shape at `:1141-1175`) and a **"Skip"**
  button. With no `options` it goes straight to free-text. A `Skip`/dismiss returns a
  recoverable note ("the reader skipped the question") the agent can proceed from — it is
  **never** left as an unanswered `tool_use` (that would 400 on the next resend, the same
  dangling-tool_use hazard the file's pairing comments already guard).
- **No-hang is the load-bearing invariant.** *Every* way the dialog can close — each option
  button, the typed-answer path, Skip, and any dismissal (tap-outside / Back) — resumes the
  coroutine **exactly once** through a one-shot `resumed` guard (the `backoff` idiom). A close
  path that forgets to resume freezes the agent forever.
- **Spoiler-safety** is preserved by the existing contract: the `question` and `options` are
  model-authored, reader-facing text rendered verbatim, so they fall under the **same**
  spoiler rule as the final answer (a one-line reinforcement in the system prompt). There is no
  new structural boundary to enforce because the tool surfaces nothing from the book the agent
  could not already say in its answer.
- Gated behind a new **`enable_clarifying_questions`** setting. Unlike `enable_subagents`
  (off — it double-bills tokens and adds latency), this tool adds **no extra token cost** and
  **no new spoiler surface**, and a guessing agent is strictly worse than an asking one, so it
  ships **default on** with a menu toggle to disable it.

## Capabilities

### New Capabilities
- `clarifying-question`: an `ask_user` tool that pauses the turn loop mid-turn to ask the reader
  a single disambiguating question (button options and/or free text), resumes the same turn with
  the answer as the tool result, can never leave the agent hung or the tool_use unanswered, and
  is spoiler-safe by the existing answer contract.

### Modified Capabilities
<!-- None — no existing OpenSpec spec covers the tool loop or the tool registry as a capability;
     like add-subagent-delegation this is a self-contained addition layered on the single-agent
     loop. -->

## Impact

- **`bbtools.lua`** — add an `ask_user` spec to `Tools.getSpecs()` (`question: string` required,
  `options: array<string>` optional). Like `delegate`/`web_search` it gets **no `DISPATCH`
  entry and no executor** — a load-bearing comment says so and points at the `bbconversation`
  branch. Excluded from `Tools.childSpecs()` (`CHILD_TOOL_NAMES`) so a subagent — which is
  headless and has no reader at the keyboard — can never call it.
- **`bbconversation.lua`** — add an `ask_user` branch in the tool-dispatch loop (next to the
  `memory`/`delegate` branches, `:671-677`) calling a new `Conversation:_askUser(input,
  tool_entry)`. The method builds the dialog, parks the coroutine with the `backoff`
  yield/resume idiom (`:177-191`) behind a one-shot `resumed` guard wired into **every** close
  path, and returns the chosen string. A load-bearing comment records the reentrancy invariant
  (the dispatch site is reached only after the parent stream fully returned, so the coroutine is
  parked at an ordinary call site — never mid-yield — making the dialog-park legal) and the
  no-hang rule. The transcript gets an `Asked: <question>` `tool_entry` that folds to
  `— <answer>` / `— skipped`, reusing the `:667-680` status-line idiom.
- **`bbsettings.lua`** — new `enable_clarifying_questions` (default **on**), surfaced in
  `getConfig()` and `getMenu()` with a toggle mirroring the existing entries.
- **`bbprompts.lua`** — a short note on when to call `ask_user` (genuine ambiguity about what the
  *reader* wants — not facts resolvable by reading the book) and a one-line reminder that the
  question text itself is spoiler-bound.
- **New tier-1 spec** `tests/question_tool_spec.lua` over the `tests/support/sse.lua` Stream
  fake plus a stubbed `ask_user` dialog driven by the existing `nextTick` pump
  (`tests/support/stubs.lua`).
- **No new runtime dependencies** — reuses `InputDialog`/`ButtonDialog`, `UIManager`, the
  conversation coroutine, and the existing tool-dispatch machinery. The only added latency is the
  reader's own think time, which is the point of the tool.
