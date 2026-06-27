## 1. The `ask_user` tool spec (D1, D10)

- [x] 1.1 Add an `ask_user` spec to `Tools.getSpecs()` in `bbtools.lua`: `question` (string,
  required) and `options` (array of short strings, optional). Description: ask the reader one
  disambiguating question when it is genuinely unclear what *they* want; keep `options` to 2–4
  concise labels; the reader can always type their own answer or skip. State that the question is
  shown verbatim and must obey the spoiler rule.
- [x] 1.2 Give `ask_user` **no `DISPATCH` entry and no executor**, with a load-bearing comment
  (mirroring the `delegate`/`web_search` comment) saying it is handled by the `bbconversation`
  branch because it needs the conversation coroutine and viewer, and that dispatching it through
  `Tools.execute` off-coroutine would deadlock.
- [x] 1.3 Exclude `ask_user` from `Tools.childSpecs()` (keep it out of `CHILD_TOOL_NAMES`) so a
  headless subagent — which has no reader at the keyboard — can never emit it.
- [x] 1.4 Gate the parent spec on `enable_clarifying_questions` in `Conversation:new`, reusing the
  `delegate` removal shape (`bbconversation.lua:~278-285`): when the setting is off, remove the
  `ask_user` spec from the advertised list.

## 2. The `_askUser` method + dispatch branch (D2, D3, D4, D5, D8)

- [x] 2.1 Add an `ask_user` branch in the tool-dispatch loop next to `memory`/`delegate`
  (`bbconversation.lua:671-677`): call `result, summary = self:_askUser(tu.input)` and let the
  generic loop fold the outcome — the `Asked: <question>` line comes from `_toolActionPhrase`, the
  truncated `— "<answer>"` / `— skipped` tail from the returned `summary`, and `result` is appended
  as the `tool_result` for `tu.id`.
- [x] 2.2 Implement `Conversation:_askUser(input)`: capture `co = coroutine.running()`, build the
  dialog (D7), `UIManager:show`, then `coroutine.yield()`; return the chosen string plus a short
  transcript summary. Use a one-shot `resumed` guard and a single `resume(answer)` helper, exactly
  like `backoff` (`:177-191`).
- [x] 2.3 Wire the `resume` helper into **every** close path: each option button, the typed-answer
  Send, the typed-answer Cancel, the Skip button, **and** the dialog's dismissal hook
  (tap-outside / Back). The dismissal and Skip paths resolve to the recoverable note
  `"[The reader closed the question without answering. Proceed with your best judgement, or ask differently.]"`.
- [x] 2.4 Add the load-bearing comment at the branch recording the reentrancy invariant (dispatch
  site is reached only after the parent stream fully returned, so the coroutine is parked at an
  ordinary call site — never mid-yield — making the dialog-park legal) **and** the no-hang rule
  (every close path resumes exactly once).
- [x] 2.5 Guarantee the `tool_use` is always answered (D5): on Skip/dismiss return the note, never
  nil, so the `[assistant tool_use][user tool_result]` pair stays balanced and resendable. Confirm
  a buffered `self.stop_requested` still answers the tool_use first, then unwinds at the next
  UI-boundary yield (D9) — no special unwind inside `_askUser`, and `self._cancel` untouched.

## 3. Dialog UI (D7)

- [x] 3.1 With `options`: build a vertically-stacked button list (one button per option) plus a
  final row of "Type my own…" and "Skip". "Type my own…" opens the free-text `InputDialog`,
  reusing the `_promptFollowup` construction (`:1141-1175`).
- [x] 3.2 With no `options`: go straight to the free-text `InputDialog` (Send / Skip). An empty
  Send is treated as Skip (returns the note).
- [x] 3.3 Truncate over-long option labels and the echoed answer in the transcript line so the
  status entry stays one tidy line.

## 4. Settings + prompts (D6, D10)

- [x] 4.1 Add `enable_clarifying_questions` (default **on**) to `bbsettings.lua`: defaults table,
  `getConfig()`, and a `getMenu()` toggle mirroring the existing entries' shape.
- [x] 4.2 Add to `bbprompts.lua`: a short note on when to call `ask_user` (genuine ambiguity about
  what the *reader* wants — which character, how far back, which interpretation — never facts
  resolvable by reading, never gratuitously; one question, then act) and the one-line reminder
  that the question text is reader-facing and spoiler-bound.

## 5. Tests (tier-1)

- [x] 5.1 Create `tests/question_tool_spec.lua` over `tests/support/sse.lua` + a stubbed dialog
  driven by the `nextTick` pump (`tests/support/stubs.lua`). Drive a scripted assistant turn that
  emits an `ask_user` `tool_use`.
- [x] 5.2 Assert the chosen option / typed text is returned as the `tool_result` for the
  `tool_use` id, and the turn continues in the same loop (the answer appears in `self.messages` as
  a `user` `tool_result` block).
- [x] 5.3 **No-hang test:** close the dialog via the **dismissal** path (not a button) and assert
  the loop resumes with the Skip note rather than the spec's coroutine pump hanging.
- [x] 5.4 Assert Skip/dismiss yields the recoverable note and the `ask_user` `tool_use` is never
  left unanswered (the pair is balanced).
- [x] 5.5 Assert `ask_user` is absent from `Tools.childSpecs()`, and absent from the parent specs
  when `enable_clarifying_questions` is off.

## 6. Gate

- [x] 6.1 Run `nix run .#check` (stylua + luacheck + busted) and make it green.
- [x] 6.2 Run tier-2 (`nix run .#test-real`): green (31/31). Added `tests/integration/real/
  question_tool_real.lua`, which drives `Conversation:_askUser` against **real** KOReader widgets
  (ButtonDialog / InputDialog) on the **real** UIManager — the coroutine-park-under-a-live-modal
  timing tier-1 can only fake. It covers all five close paths: a real option tap, the real Skip
  button, a bare dismissal via `ButtonDialog:onClose` (the no-hang invariant, exercising the real
  `UIManager:close → CloseWidget → onCloseWidget` dispatch), the real free-text handoff, and an
  empty Send → skip. The coroutine resume crosses the real UIManager task queue, drained via
  `_checkTasks`, so the reentrancy invariant is now test-covered, not comment-asserted only.
