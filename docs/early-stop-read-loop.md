# Failure: agent stops reading early, then fabricates the unread part

## Summary

In a Tier 3 promptfoo run (`eval-JCl-2026-06-03T06:44:47`, 26/27 passing), the one
failure was a whole-previous-chapter recap of the obscure book *Jan Vedder's Wife* at
the start of Chapter VI. The scenario passed twice and failed once — non-deterministic:
the same prompt, a different draw. The agent stopped its read loop partway through the
chapter, then omitted the chapter's climax, fabricated a different ending from a
half-remembered version of the book, and spoiled the next chapter.

This document records the failure, the root cause from the tool trace, the fix (which
took **two** layers, not one), and the A/B measurements that justify it.

## Symptom (what the graders saw)

On the failing draw both prose graders fired:

- **Completeness:** the recap covered the son's birth and the Doctor Balloch / Peter
  scenes but *omitted the chapter's climax* — the wreck of *The Solan* on the Quarr
  rocks, the very event that gives the chapter its title "Shipwreck."
- **Spoiler:** it (a) **invented an ending** ("Jan plans to sell the boat and repay the
  £600") that contradicts the real chapter ending, and (b) **spoiled forward** by naming
  the next chapter ("Margaret's Heart") and describing its content.

## Root cause (from the tool trace, not the grader's opinion)

Chapter V ("Shipwreck") spans pages 81–100. The agent's own `metadata.trace` shows it
read only ~pages 81–92, hit an explicit `(More follows … loc:24)` continuation marker,
**ignored it**, opened its answer with *"I have the full arc of the chapter now,"* and
stopped. The `loc:24` read was never issued; the last ~8 pages — containing the actual
shipwreck — were never loaded into context.

All three grader complaints are downstream of that one premature stop. You cannot recap
what you never fetched; the "invented" ending is verbatim Jan's *mid-chapter* plan (which
the real ending inverts — he sets out and is wrecked); the forward spoiler is editorial
off the TOC title.

This is an **agent-behavior bug, not a model-knowledge bug.** The `read` tool correctly
emits the breadcrumb; the model is free to ignore it, and on a ~1-in-6 draw it does. The
flakiness *is* that coin flip: "keep reading to the chapter boundary" vs. "I've read
enough, ship it."

## Fix (two layers — one wasn't enough)

### Layer 1 — the `read` tool itself (`bbtools.lua`)

The tool's own text was the load-bearing excuse for the early stop. Two changes:

1. **Description.** Dropped the old tail *"Read only what you need — every chunk you read
   stays in context"* (the model judged it had read "enough" and the tool pre-supplied the
   rationalization). Replaced with *"keep going to the end of what you were asked about; a
   chunk ending in `(Not the end …)` means there is more, so don't stop or conclude there.
   Reflowable (EPUB) books only; don't re-read chunks you already pulled."* — keeps the
   real token win (no re-reads) while deleting the stop-early license.
2. **Continuation trailer.** The informational *"(More follows — read again with from: N.)"*
   became the firmer *"(Not the end — call read again with from: N to continue.)"* — the
   breadcrumb the model used to shrug off now reads as a contract.

### Layer 2 — a `<completeness>` block in the system prompt (`bbprompts.lua`)

A general (not recap-specific) instruction: before answering, read all the text the answer
depends on; treat an outstanding `(Not the end …)` as binding; keep going to a real end
(next chapter in the TOC, end of book, or the reader's current page when spoiler-safe);
and do not call an account "complete" until then. It explicitly names the failure mode it
targets — *"A partial read tempts you to fill the gap from a half-remembered version of the
book — which is exactly the mistake to avoid."*

### Why both

Layer 1 was tried alone first and **measurably under-performed** — it cut the early-stop
rate but left ~7% residual (see below). The redundancy we feared turned out not to be
redundant: two independent nudges against the same satisficing behavior compound, and only
the stacked pair drove the failure to zero across 30 draws. The block was adapted to cite
the new "Not the end" trailer so the prompt and tool agree.

### Grounded in Anthropic's prompting guidance

From the Claude 4 best-practices guide: **define clear success criteria**; **"never stop
early / complete tasks fully"** (canonical persistence phrasing, adapted from token budget
to passage boundary); and since Opus 4.8 **"favors reasoning over tool calls,"** the
recommended lever is to **"explicitly instruct the model about when and how to properly use
its tools."** Reasoning-instead-of-reading is precisely the failure; both an explicit tool
description and an explicit prompt instruction are the prescribed fix.

## Two eval scenarios, two failure directions

- **OBS2** (`asserts/summarized_full_chapter.js`) — reader at page 130 (mid Ch. VII), task
  *"Summarize Chapter V."* by number. Ch. V ends at p100 with ~22 pages of Ch. VI as
  headroom and no spoiler clamp at the V/VI boundary, so it catches **over-reading** (a hard
  fail on any read reaching p≥102). This scenario is *hardened* — the named, far-away chapter
  makes the task so explicit the model reliably reads the whole unit, so OBS2 is **inert to
  the early-stop bug** (10/10 even with the broken tool).
- **OBS3** (`asserts/recapped_previous_chapter.js`) — the **original flake**, kept
  deliberately un-hardened: reader at page 101 (start of Ch. VI), task the vague *"Summarize
  the previous chapter."* (no number, no name). That vagueness is what lets the model
  satisfice, so OBS3 is the **sensitive early-stop probe**. It is the scenario all the A/B
  numbers below were measured on.

## Measurements (2026-06-03, OBS3, 30 draws per arm via Requesty)

Early-stop = the targeted bug: a short read (4–5 reads, max header page ≤95, never reaching
the wreck at page 99/`loc:24`) producing a confident but incomplete recap. Classified from
the trace, not the grader's prose opinion.

| arm | eval id | early-stop | rate | vs broken (Fisher 2-sided) |
|-----|---------|-----------:|-----:|---------------------------:|
| broken tool (no fix) | `eval-cri` | 5/30 | 16.7% | — |
| read-tweak only (Layer 1) | `eval-Ps2` | 2/30 | 6.7% | p = 0.42 (not significant) |
| **stacked (Layer 1 + 2)** | `eval-OF0` | **0/30** | **0.0%** | **p = 0.052; pooled 7/40 vs 0/30 → p = 0.017** |

Monotone: **16.7% → 6.7% → 0%.** The stacked arm is the only one to clear significance
against broken. Caveats worth keeping honest:

- **Stacked is not provably better than the read-tweak alone** (6.7% → 0% is p = 0.49; both
  arms are small). The case for Layer 2 rests on the monotone trend plus the fact that the
  stack cleared significance vs broken where Layer 1 alone did not. To *prove* a 17%→7%
  effect at p<0.05 would need ≈130–150 draws per arm — not spent.
- **A new, different failure surfaced once in the stacked arm** (`eval-OF0` #5): the model
  read the whole chapter to `loc:24`, then returned literally `(no response)` — read fully,
  answered nothing. This is a degenerate empty completion, not satisficing; n=1, so it is
  not confidently attributable to the completeness pressure, but it is worth watching in
  future runs.
- **Forward-spoiler slips persist across all arms** (1–3/30: the model reads the whole
  chapter, then editorializes the next chapter's title). Orthogonal to the read-loop fix;
  neither layer targets it.

## How to reproduce / verify

```sh
BB_PLUGIN_DIR=$(pwd) \
BB_BASE_URL=https://router.eu.requesty.ai BB_API_KEY=$(pass api/requesty/playground) \
BB_EVAL_MODEL=vertex/claude-opus-4-8@eu \
BB_GRADER_BASE_URL=https://router.eu.requesty.ai/v1 \
BB_GRADER_MODEL=vertex/claude-sonnet-4-6@europe-west1 \
  nix run .#eval -- --filter-pattern OBS3 --repeat 30
```

To re-run the falsification, `git checkout <pre-fix> -- bbtools.lua bbprompts.lua` and
expect the early-stop rate to climb back toward ~17%.
