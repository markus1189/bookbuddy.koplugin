# Tier 2 — real-crengine in-tree tool tests

> **STATUS: ✅ DONE.** `nix run .#test-real` now runs a real-crengine suite of 26 checks over
> `juliet.epub` (was a 2-check smoke spec). The hand-rolled-fakes file `tests/integration/tools.lua`
> (111 checks) is retired; its coverage was split by what each check actually needs (see Decision).
> Pure suite `.#test` is 83 checks (was 64); `.#check` green (stylua + luacheck + busted).

> One of three tiers in the BookBuddy testing concept. Tier 1 = pure-luajit unit tests
> (`tier1-busted.md`, done); Tier 2 = this; Tier 3 = promptfoo agent evals. Tier 2 was gated on the
> spike (`spike-sdl3-pin.md`, done), which established the hermetic emulator + `.#test-real` harness.

## Context
After the spike, `.#test-real` ran a single 2-check smoke spec (`tests/integration/smoke_real.lua`)
proving the hermetic real-crengine harness worked. The real tool-executor coverage still lived in
`tests/integration/tools.lua` — 111 checks driven against **hand-rolled fake** `ui`/document objects
(synthetic xpointers like `"xpA"`, word-tapes `"tp:5"`, controlled `page_of` maps). Those fakes
prove branch logic but can't prove the fakes told the truth about crengine's real API shapes. Tier 2
re-expresses the engine-touching behaviours as assertions against the **real** `juliet.epub`.

## Decision — hybrid split (not a 1:1 port)
The fakes' synthetic fixtures can't be reproduced against a real book (you get real xpointers and
whatever positions/pages juliet.epub actually yields). So coverage was split by need, and
`tools.lua` retired:
- **Engine-touching → Tier 2** (`tests/integration/real/*_real.lua`): real hits/pages, sentence
  segmentation, word-stepping, `GotoXPointer` movement, the annotation round-trip.
- **Engine-agnostic → Tier 1** (`tests/tools_spec.lua`, pure-luajit, fake `ui`s): input validation,
  the dispatch contract (which `Event` + args a tool emits), occurrence/ambiguity math, error guards
  — plus the two cases a real EPUB *can't* trigger (the paging/non-reflowable guard; an
  xpointer-less TOC entry).

## Harness / layout
- Files: `tests/integration/real/<tool>_real.lua`. The **`_real` suffix** (not `_spec`) keeps them
  out of the pure `.#test` (its `.busted` scans `ROOT=tests` for `_spec`); the existing convention
  (`smoke_real.lua`, `tools.lua`) already avoided `_spec` for the same reason.
- `.#test-real` (`flake.nix`): `BB_SPEC` defaults to the `tests/integration/real` **directory**;
  busted discovers specs with `--pattern=_real`. (Confirmed: directory discovery + `--pattern` work
  under the embedded `busted.runner {standalone=false}` invocation.) Single-file override via
  `BB_SPEC` still works (a file path bypasses the pattern scan).
- Shared scaffolding: `tests/integration/real/support.lua` (`open_book`/`close_book`/`current_page`/
  `reset_annotations`) — NOT a `_real` file, so discovery skips it; specs pull it in by short path
  (`require("tests.integration.real.support")`, resolved via `$PLUGIN_DIR/?.lua` on `LUA_PATH`).

## Specs (26 checks)
- `context_real` — book_context (title/author/real page count, current chapter); get_toc (Acts &
  scenes, every entry's `loc` token, and a toc `loc` that `read` resolves to that chapter's start).
- `grep_real` — real page-tagged + `loc`-tagged hits and `last_search` lock-step; the `regex` flag
  flowing to crengine (`Rom.o` literal→none vs regex→Romeo); fuller span in sentence context; the
  spoiler page-cap hiding hits past the reader's real page (and `spoiler=true` / `max_page`); no-match.
- `read_real` — current-page read clamps (no forward locator without spoiler); spoiler forward read
  + a resolvable continuation locator; start from a page-number string, from a grep span `loc`;
  refuse a start past current page; real end-of-book termination from the last page.
- `navigate_real` — absolute page jump lands there; percent moves directionally; chapter jump via
  real xpointer lands on the TOC's own page for that entry; back returns; empty-stack message on a
  fresh book.
- `highlight_real` — create by occurrence / by grep `search_result` / by grep span `locator`;
  get_highlights lists with real page/chapter; edit sets then appends a note (non-destructive);
  ambiguous text asks and highlights nothing.
- `smoke_real` — the original minimal sanity check, folded into the suite dir.

## Gotcha captured (for future specs)
Highlights **persist to the `.sdr` sidecar under the shared `KO_HOME`**, so a second `open_book()`
of juliet.epub in the same run loads what an earlier describe saved. Count-sensitive specs call
`support.reset_annotations(readerui)` in `setup()` for a clean slate independent of suite order;
prefer delta assertions over absolute counts otherwise.

## Verification
- `nix run .#test-real` → 26/26 (real crengine, hermetic).
- `nix run .#test` → 83/83 (pure, incl. the new `tools_spec`).
- `nix run .#check` → stylua + luacheck + busted, exit 0.

## Out of scope
Tier 3 (promptfoo agent evals over a real book). `web_search` (network) stays untested here.
