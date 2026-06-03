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

A **general** system-prompt addition (not recap-specific) in `bbprompts.lua`, a new
`<completeness>` block after `<grounding>`. It establishes, for *any* question about a
span of text:

- read all the text the answer depends on; do not stop early;
- an outstanding `(More follows — read again with from: …)` marker means the passage
  is unfinished — keep calling `read` until a *real* end (next TOC chapter,
  `(End of book reached.)`, or the reader's current page when spoiler-safe);
- do not describe how something turns out, or call an account "complete"/"the full
  picture", until actually read to that end — a partial read tempts filling the gap
  from a half-remembered version of the book.

### Grounded in Anthropic's prompting guidance

From the Claude 4 best-practices guide:

- **Define clear success criteria** for a complete answer (§Research and information
  gathering). The block defines "read to a real end" as the bar.
- **"do not stop tasks early … complete tasks fully … Never artificially stop any
  task early"** — Anthropic's canonical persistence phrasing (§Managing context
  limits), adapted here from "token budget" to "passage boundary."
- Opus 4.8 **"favors reasoning over tool calls"**, and the recommended lever is to
  **"explicitly instruct the model about when and how to properly use its tools"**
  (§Tool usage). Reasoning-instead-of-reading is precisely the failure; the explicit
  instruction is the prescribed fix.

## Known tension / follow-up

The `read` tool description (`bbtools.lua`) still says *"Read only what you need —
every chunk you read stays in context"*, and `<grounding>` warns against re-reading.
These are about token economy and remain correct, but "read only what you need" can
read as license to stop early. The `<completeness>` block is meant to win that tie for
span questions (read *forward* fully, once; never *re-read*). If the flake persists,
the next lever is a more robust, deterministic fix: compute the chapter's `loc` span
from the TOC and loop `read` in code until `current_page` reaches the next chapter,
removing the coin flip entirely.

## How to reproduce / verify

Re-run the OBS2 scenario several times (it is non-deterministic, so use the repeat):

```sh
BB_PLUGIN_DIR=$(pwd) \
BB_BASE_URL=https://router.eu.requesty.ai BB_API_KEY=$(pass api/requesty/playground) \
BB_EVAL_MODEL=vertex/claude-opus-4-8@eu \
BB_GRADER_BASE_URL=https://router.eu.requesty.ai/v1 \
BB_GRADER_MODEL=vertex/claude-sonnet-4-6@europe-west1 \
  nix run .#eval -- --filter-pattern OBS2
```

A fixed run should show the agent issuing `read` calls all the way to the
Chapter VI boundary (page 101) before recapping, and the completeness grader passing.

## Verification result (2026-06-03, `eval-9BM-2026-06-03T07:10:02`)

A 10× billed run of OBS2 with the `<completeness>` fix in place: **10/10 pass.**
Every single run issued **6** `read` calls ending at `loc:24` (the failing draw had
stopped at 5, ignoring the `loc:24` breadcrumb). The 6th read reaches page 99 — "Jan,
the sole survivor of The Solan" — i.e. the shipwreck the old draw never loaded, then
clamps at "(Stopped at your current page to avoid spoilers.)" at the page-101 Ch VI
boundary. All 10 recaps mention the wreck. The previously ~1-in-3 flake did not recur
in any of the 10 draws.
