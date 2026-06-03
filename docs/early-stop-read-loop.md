# Failure: agent stops reading early, then fabricates the unread part

## Summary

In a Tier 3 promptfoo run (`eval-JCl-2026-06-03T06:44:47`, 26/27 passing), the one
failure was the **OBS2** scenario — a whole-previous-chapter recap of the obscure
book *Jan Vedder's Wife* at the start of Chapter VI. The scenario runs three times
(`evaluateOptions.repeat = 3`, commit `4dcefab`); it **passed twice (score 1.0) and
failed once (score 0.45)**. This is non-deterministic: the same prompt, a different
draw.

The repeat bump paid for itself here — a single run would have either missed the
flake or falsely indicted a good draw.

## Symptom (what the graders saw)

Both graders fired on the failing draw:

- **Completeness (`llm-rubric`):** the recap covered the son's birth and the
  Doctor Balloch / Peter scenes but *omitted the chapter's climax* — the wreck of
  *The Solan* on the Quarr rocks, "the very event that gives the chapter its title
  'Shipwreck.'"
- **Spoiler (`llm-rubric`):** it (a) **invented an ending** — "Jan plans to sell the
  boat and repay the £600" — that contradicts the real chapter ending, and (b)
  **spoiled forward** by naming the next chapter ("Margaret's Heart") and describing
  its content.

## Root cause (from the tool trace, not the grader's opinion)

The agent's own `metadata.trace` shows the read loop. Chapter V ("Shipwreck") starts
at `loc:8` / page 81; Chapter VI starts at page 101. So the chapter spans pages
81–100. The agent read:

| read | from     | reached  | tool trailer                                  |
|------|----------|----------|-----------------------------------------------|
| 1    | `loc:8`  | p81–83   | `(More follows — read again with from: loc:20.)` |
| 2    | `loc:20` | p84–87   | `… loc:21.`                                    |
| 3    | `loc:21` | p88–90   | `… loc:22.`                                    |
| 4    | `loc:22` | p91–94   | `… loc:23.`                                    |
| 5    | `loc:23` | ~p92–95  | **`(More follows — read again with from: loc:24.)`** |

Then it stopped and opened its answer with *"I have the full arc of the chapter now."*

It did not. It read roughly **pages 81–92 of a 20-page chapter**, hit an explicit
`(More follows … loc:24.)` continuation marker, **ignored it**, and declared the read
complete. The `loc:24` read was never issued. The last ~8 pages — containing the
actual shipwreck — were never loaded into context.

Both grader failures are downstream of that one premature stop:

1. **Omitted climax** — the shipwreck simply isn't in the text the agent read. In
   pages 81–92 *The Solan* is fine; you cannot recap what you never fetched.
2. **"Invented" ending** — the line about selling *The Solan* and repaying the £600
   is verbatim on page 91, but there it is Jan's *mid-chapter resolution* about his
   **next** voyage. The real chapter ending *inverts* that plan (he sets out and is
   wrecked). The agent reported the setup as the payoff because it never read the
   payoff.
3. **Forward spoiler** — a separate, minor sin: pure editorializing off the TOC
   title for a chapter it also never read.

This is an **agent-behavior bug, not a model-knowledge bug.** The `read` tool
correctly emits the `(More follows …)` breadcrumb; the model is free to ignore it,
and on this ~1-in-3 draw it did. The flakiness *is* this coin flip: "keep reading to
the chapter boundary" vs. "I've read enough, ship it."

## Fix

The fix lives in the **`read` tool itself** (`bbtools.lua`), not the system prompt — the
guidance sits next to the tool it governs and costs no system-prompt real estate. Two
changes:

1. **Description.** The old tail *"Read only what you need — every chunk you read stays in
   context"* was the load-bearing rationalization for the early stop (the model judged it
   had read "enough" and the tool pre-supplied the excuse). Replaced with: *"keep going to
   the end of what you were asked about; a chunk ending in `(Not the end …)` is not the
   end, so don't stop or conclude there. Reflowable (EPUB) books only; don't re-read chunks
   you already pulled."* This keeps the real token win (no re-reads) while deleting the
   stop-early license.
2. **Continuation trailer.** The informational *"(More follows — read again with from: N.)"*
   became the firmer *"(Not the end — call read again with from: N to continue.)"* — the
   breadcrumb the model used to shrug off now reads as a contract.

Crucially this is scoped to *"the end of what you were asked about"*, so it does **not**
cause over-reading: asked for one chapter with the reader positioned past it, the model
stops at that chapter's boundary even though the trailer keeps inviting it on (verified
below).

### Grounded in Anthropic's prompting guidance

From the Claude 4 best-practices guide:

- **Define clear success criteria** for a complete answer (§Research and information
  gathering). The description defines "read to the end of what you were asked about" as
  the bar.
- **"do not stop tasks early … complete tasks fully … Never artificially stop any task
  early"** — Anthropic's canonical persistence phrasing (§Managing context limits),
  adapted from "token budget" to "passage boundary."
- Opus 4.8 **"favors reasoning over tool calls"**, and the recommended lever is to
  **"explicitly instruct the model about when and how to properly use its tools"**
  (§Tool usage). Reasoning-instead-of-reading is precisely the failure; an explicit tool
  description is the prescribed fix.

### Approach not taken (kept in history)

An earlier commit (`dbf6def`) put the same idea in the system prompt as a general
`<completeness>` block. It also verified 10/10, but it left the read tool's
contradictory *"Read only what you need"* line in place — a brittle equilibrium where the
block only won the tie by outranking the tool text. The read-tool fix removes the
contradiction at the source, so this commit supersedes it (the block is dropped).

## OBS2 now also guards against over-reading

The OBS2 scenario was retargeted to test *both* failure directions with the same setup:
reader at **page 130** (mid Ch VII), task **"Summarize Chapter V."** (by number — the
title "Shipwreck" is withheld so it can't leak the climax or trivialize grounding). Ch V
ends at p100, leaving ~22 pages of Ch VI as headroom with **no spoiler clamp at the V/VI
boundary** — so stopping is the model's own judgment, not the clamp's. The trace assert
(`asserts/summarized_full_chapter.js`) gained a hard **over-read fail** (any read reaching
p≥102 = drifted into Ch VI) alongside the existing grounding and read-ahead teeth.

## How to reproduce / verify

```sh
BB_PLUGIN_DIR=$(pwd) \
BB_BASE_URL=https://router.eu.requesty.ai BB_API_KEY=$(pass api/requesty/playground) \
BB_EVAL_MODEL=vertex/claude-opus-4-8@eu \
BB_GRADER_BASE_URL=https://router.eu.requesty.ai/v1 \
BB_GRADER_MODEL=vertex/claude-sonnet-4-6@europe-west1 \
  nix run .#eval -- --filter-pattern OBS2 --repeat 10
```

A fixed run reads Chapter V end-to-end (reaching the wreck climax) and **stops at the
Ch V/VI boundary** — the trace shows `maxReadHdrPage ≤ 100`, never ≥102.

## Verification results (2026-06-03)

- **Read-tweak, original OBS2** (`eval-pI2-…T07:23:14`): **10/10 pass.** Every run issued
  6 reads to `loc:24` and reached the shipwreck — identical to the system-prompt block's
  10/10 (`eval-9BM-…T07:10:02`).
- **Read-tweak, over-read OBS2** (`eval-UkM-…T07:51:19`): **10/10 pass.** Every run read
  Ch V `loc:8`→`loc:24` (6 chunks, last header p98–99, reaching the climax) and **none
  drifted into Ch VI** (`maxReadHdrPage = 99`), despite 22 pages of headroom and the
  trailer inviting continuation at every step. The over-reading concern is refuted across
  10 draws.
