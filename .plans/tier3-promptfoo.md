# Tier 3 — promptfoo agent evals

> **STATUS: PLANNED** — design complete, not yet implemented. Third of three testing tiers.
> Tier 1 = pure-luajit units (`tier1-busted.md`, done); Tier 2 = real-crengine tool tests
> (`tier2-real.md`, done); Tier 3 = this. Tiers 1–2 are offline, hermetic, free, and gate `.#check`.
> **Tier 3 is categorically different** — it drives a real model, so it is non-hermetic,
> credentialed, rate-limited, billed, and therefore a separate opt-in run, **NOT** in `.#check`.

## Context

BookBuddy's two offline tiers gate `.#check`: Tier 1 (pure-luajit units, `_spec`) and Tier 2
(real-crengine tool tests over `juliet.epub`, `_real`). Neither drives a model — they stub the loop
or test tool executors in isolation. So nothing today grades the thing that actually ships: **does
the agent loop pick the right tools, in the right order, on a real book, and respect the product
constraints (plain-text-only, no-spoiler gates)?**

Tier 3 fills that gap with [promptfoo](https://promptfoo.dev) driving the **real `bbconversation`
loop** against a **real model** over the Tier-2 real-crengine harness. This session's deliverable is
a **walking skeleton** — one scenario, end-to-end, green once — that settles the risky plumbing
(decision #1) before any fan-out.

## Resolved decisions (were the seed's open forks)

1. **What promptfoo drives** → an `exec:` provider invoking a headless Lua driver that runs the
   *genuine* `bbconversation:run()`/`_loop()` over a Tier-2 `ReaderUI`. Highest fidelity; the real
   work is the headless pump (below). (Rejected: a thin re-implementation of the loop — drift risk.)
2. **First deliverable** → walking skeleton (1 scenario, 1 deterministic assertion). Fan-out later.
3. **Eval model** → a pinned **cheaper model with thinking OFF** for the suite (env/settings
   override), not the shipping Opus-4.8-+-adaptive-thinking default. Cheaper, faster, less variance.
   (Opus run can be added later.)
4. **Assertions** → deterministic trace assertions (tool order/args, juliet ground-truth page
   numbers) + no-markdown regex + spoiler-refusal checks, **plus** one `llm-rubric` for prose quality.

## How the pieces actually work (verified, don't re-derive)

- **The loop runs entirely on `UIManager`'s scheduler.** `Conversation:run()`
  (`bbconversation.lua:181`) wraps `_loop()` in `Trapper:wrap`; the loop advances by yielding to
  `UIManager` (`:243-246`), and `Stream.run` polls its subprocess via
  `UIManager:scheduleIn(0.125, …)` + `coroutine.yield()` (`bbstream.lua:60-98`). `_loop()` **returns**
  at every terminal branch (cancel `:312`, read-error `:319`, API-error `:328`, no-content `:349`,
  final answer `:401`, budget-exhausted `:408`) — there is **no completion callback**.
  ⇒ The headless pump is: run UIManager until the Trapper-wrapped `_loop()` returns.
- **The trace is already captured** in `conv.messages` (wire format): every assistant `tool_use`
  block carries `{id, name, input}`, and the following user message carries the matching
  `tool_result` blocks (`bbconversation.lua:353,369-398`). Final text is reconstructable via
  `conv:_transcriptText()` or the last assistant text blocks. No new hook needed.
- **Determinism is impossible at the token level**: `buildBody` sets no temperature
  (`bbanthropic.lua:33-55`) and adaptive thinking forces `temperature=1`. ⇒ grade the trace, not the
  prose; use `repeat` + thresholds for the rubric.
- **Credentials**: `cfg.portkey_api_key` flows from `bbsettings:getConfig()` (Portkey gateway,
  `x-portkey-api-key` header, `bbanthropic.lua:125-134`). **No env-var fallback exists today** — the
  driver injects the key into settings programmatically from an env var. Defaults: `base_url`
  Portkey, model `@vertex-eu-global/anthropic.claude-opus-4-8`.
- **Tier-2 entry**: `tests/integration/real/support.lua` `open_book()` → `(readerui, Tools)` over
  `juliet.epub`, fully hermetic; the flake's `test-real` runner assembles the koreader runtime
  (LUA_PATH/CPATH/LD_LIBRARY_PATH, `cd ${ko}`, `KO_HOME`, `SDL_VIDEODRIVER=dummy`).

## juliet.epub ground truth (anchors for deterministic asserts)

Title `Romeo and Juliet`, author `William Shakespeare`. **VERIFIED via the driver run** (v2025.10,
default layout): the first three "Verona" hits are pages **6 / 7 / 15** — the FIRST occurrence is the
Prologue line "In fair Verona, where we lay our scene" on **page 6 (`loc:1`)**, NOT page 7 (page 7 is
the later "SCENE I. Verona. A public place."). The deterministic highlight assert must key on **page 6
/ `loc:1`**. "Mantua" and "poison" both exist; TOC contains `Act I` and `SCENE I. Verona`;
`chapter_index` 5/6 resolve to real pages. From an early reader page the later hits are spoiler-hidden
unless `spoiler=true` (the model first grepped with `max_page` = current page, got "N match(es)
hidden", then re-grepped with `spoiler=true`). (Don't hardcode total page count —
crengine-layout-dependent.)

## Eval book matrix — pinned EPUBs + ground-truth anchors

Four Project Gutenberg novels are pinned alongside juliet for the fan-out, each chosen for a distinct
agentic-eval surface. They are fetched by `pkgs.fetchurl` (pinned sha256) and symlinked by stable bare
name into the `evalEpubs` derivation (`flake.nix`); `BB_EPUB_DIR` now points at `evalEpubs` (NOT the
raw test-data store), so the driver's `resolveEpub` finds each via a per-test `epub` var. A
Gutenberg-side regeneration changes the hash and fails the build LOUDLY rather than silently drifting
the anchors below. **All anchors VERIFIED via `BB_DRY_RUN=1 BB_PROBE_GREP="…"` (v2025.10 default
layout, zero model spend); re-capture the same way. Page numbers are crengine-layout-dependent — stable
only against the pinned epub + pinned koreader.**

- **`a-tale-of-two-cities.epub`** (#98) — *spoiler-gate champion.* Opener "It was the best of times" →
  **page 9 / `loc:1`** (Book I, Ch. I). Carton's last line "It is a far, far better thing that I do" →
  **page 709 / `loc:1`**. The ~700-page span between a benign early anchor and the famous-death anchor
  makes this the strongest `start_page`/`spoiler=true` matrix in the set.
- **`frankenstein.epub`** (#84) — *misconception / restraint.* Creation scene "It was on a dreary night
  of November" → **page 81 / `loc:1`** (Ch. 5). Use for the creator-vs-creature correction and the
  Walton epistolary frame.
- **`pride-and-prejudice.epub`** (#1342) — *character graph.* Novel opener "It is a truth universally
  acknowledged" → **page 35 / `loc:1`** (substantial front matter precedes it). **HAZARD baked into
  this edition:** an editorial introduction on pages **~13–28** names "Wickham" and discusses Lydia's
  elopement — i.e. the book's own front matter spoils the plot. A naive `grep "Wickham"` surfaces those
  intro hits FIRST (pages 13/14/24/25/28); the first *narrative* Wickham is **page 152 / `loc:7`**
  ("entreated permission to introduce his friend, Mr. Wickham"). Character/spoiler scenarios must anchor
  on the narrative occurrence and set `start_page` past the intro (≥35).
- **`jekyll-and-hyde.epub`** (#43) — *compact single-twist gate.* Opener "Mr. Utterson the lawyer was a
  man of a rugged countenance" → **page 6 / `loc:1`**. The reveal that Jekyll and Hyde are one man has
  two crisp anchors: Lanyon's transformation scene "there stood Henry Jekyll!" → **page 93 / `loc:1`**,
  and the thesis line "man is not truly one, but truly two" → **page 97 / `loc:1`**. ~90-page span +
  the smallest epub in the set → the cheapest spoiler-gate regression test. (Minor: the page-5 TOC
  lists the chapter title "Henry Jekyll's Full Statement of the Case", a faint structural hint — not a
  prose spoiler.)

## Progress

- **Step 1 (driver) — DONE & verified green.** `tests/eval/tier3_driver.lua` runs the genuine
  `bbconversation:_loop()` headless against the real model over a Tier-2 `ReaderUI` and prints the
  ProviderResponse JSON. The pump works (Trapper:wrap → `pcall(_loop)` → `UIManager:quit()`,
  `setRunForeverMode` + `UIManager:run()`, all UI seams stubbed). A real "Highlight the first
  mention of Verona" run produced the ideal trace: `grep` (current-page, spoiler-hidden) → `grep
  spoiler=true` → `create_highlight loc:1` (page 6), plain-text spoiler-aware answer.
- **Flake runner for isolation — DONE.** Added `.#eval-driver` (x86_64-linux only, NOT in `.#check`),
  mirroring `test-real`'s env block + the real-model call. Run it:
  `BB_PORTKEY_API_KEY=$(pass api/portkey-playground) BB_PLUGIN_DIR=$(pwd) nix run .#eval-driver -- "<task>"`.
  Knobs: `BB_EVAL_MODEL` (defaults to the Opus slug — known-good; swap to a cheaper Haiku slug for the
  steady-state suite), `BB_MAX_TURNS`, `BB_BASE_URL`, `BB_EVAL_OUT` (clean JSON capture path).
- **TLS gotcha (settled).** test-real makes no network calls, so its env never loaded OpenSSL; the
  driver's forked subprocess loads `common/ssl.so`, whose `NEEDED libssl.so.60`/`libcrypto.so.57` are
  koreader's vendored OpenSSL in `${ko}/libs`. `.#eval-driver` appends `${ko}/libs` to
  `LD_LIBRARY_PATH` (after the nixpkgs libs, so SDL2/libstdc++ still resolve to nixpkgs). The
  promptfoo runner (`.#eval`) must do the same.
- **Known edge (not yet fixed).** rapidjson encodes an empty `trace` as `{}` (object) not `[]`; only
  hit on an error/no-tool run, so the success-path skeleton is unaffected. Force-array if an assert
  ever needs to iterate the trace on a failed run.

## Steps 2 & 3 — DONE (wiring complete; offline-verified, billed run pending)

Written: `tests/eval/promptfooconfig.yaml`, `tests/eval/asserts/created_highlight_verona.js`, and
two flake derivations — `bb-tier3-exec` (the `exec:` wrapper) + `.#eval` (the promptfoo runner).
All **offline** checks pass: `node --check` on the assert, `promptfoo validate` → "Configuration is
valid", both derivations build shellcheck-clean, and the `.#eval` unset-key guard exits 2 (so no
billed call fires by accident).

**SKELETON GREEN (billed run, 2026-06-01).** `nix run .#eval` → Pass Rate 100.00% (2/2, repeat: 2),
27s. Both runs reproduced the ideal trace: `grep` (current-page, spoiler-hidden) → `grep spoiler=true`
→ `create_highlight` on page 6 (Prologue), plain-text spoiler-aware confirmation. Decision #1 (what
promptfoo drives) is now settled end-to-end. (Harmless: promptfoo warns "Could not find any valid
files in the command: bb-tier3-exec" — expected for a bare-name PATH command; only affects its own
file-hash caching, which we disable with `--no-cache` anyway.)

**Critical correction to the original Step-2 assumptions (verified against promptfoo 0.118.14
`dist/src/providers/scriptCompletion.js` + `assertions/index.js`):**
- The `exec:` provider runs `execFile(command, [prompt, optsJSON, ctxJSON])` — **NO shell** (env
  vars in the command string do NOT expand; the command is **PATH-resolved by bare name**) — and sets
  `output` = **raw trimmed stdout, NOT JSON-parsed**, with **no `providerResponse.metadata`**. So the
  plan's "promptfoo passes object output pre-parsed / read `context.providerResponse.metadata.trace`"
  was wrong. Every assertion **parses the JSON envelope string itself** (`JSON.parse(output)` →
  `.metadata.trace`, `.output`). A `file://*.js` assert is called `fn(output, context)` and may
  return a `{pass, score, reason}` GradingResult; an inline `javascript` value is
  `new Function('output','context', body)` (multi-line bodies must `return`).
- Because the provider is bare-name PATH-resolved, the exec entry is a **named wrapper**
  (`bb-tier3-exec`), not an inline shell one-liner. The wrapper — not the `.#eval` app — owns the full
  koreader runtime env (LUA_PATH/CPATH, `${ko}/libs` TLS, KO_HOME, SDL dummy, `cd ${ko}`), so the
  **Node/promptfoo process runs with a clean env** (avoids koreader libstdc++/openssl shadowing Node).
  Fresh per-call `KO_HOME` → each `repeat` gets an empty `.sdr`. The wrapper writes clean JSON via
  `BB_EVAL_OUT` and redirects the driver's own stdout (ffi-load noise) to stderr.
- The `.#eval` app runs promptfoo from a writable scratch cwd (`mktemp -d`) with `--no-cache -j 1`;
  `file://asserts/*` resolve relative to the **config dir**, not cwd.
- **DONE: the `llm-rubric` prose-quality assert.** A *second* credentialed grader, independent of the
  agent's gateway, wired **without** leaking the key into the store. NOTE the original sketch
  (`defaultTest.options.provider`, env-fed) does **NOT** work as written: promptfoo does not
  interpolate `{{env.*}}` inside provider config. The working rig: `evalRun` builds the grader from
  three env knobs (`BB_GRADER_MODEL` → `--grader openai:chat:$BB_GRADER_MODEL`;
  `BB_GRADER_BASE_URL`/`BB_GRADER_API_KEY` → `OPENAI_BASE_URL`/`OPENAI_API_KEY`, runtime-only).
  Defaults suit OpenRouter; override all three for Requesty. First consumer: C1 (P&P @160), which
  grades the PROSE ONLY via `transform: JSON.parse(output).output` so the rubric never sees the
  spoiler-laden `metadata.trace`. The deterministic asserts (trace + no-markdown) still gate every
  scenario; the rubric is additive where the prose-only channel needs it.

## Step 4 — `BB_START_PAGE` knob (DONE; verified free) — unlocks the spoiler matrix

The reader is now positionable before the turn, so spoiler gates have a real "current page"
boundary that scenarios control. Three entry paths, in precedence order:
- **per-test var** `start_page` (promptfoo passes the test context as the driver's argv[3] = JSON;
  `resolveStartPage()` reads `ctx.vars.start_page`) — the matrix enabler;
- **`BB_START_PAGE` env** — global fallback for the isolation harness (`.#eval-driver` passes only
  the task, no context arg);
- default (page ~1) if neither is set.

The book itself is parameterized the same way: a per-test `epub` var (resolved by bare name
against `BB_EPUB_DIR` = the test-data store path, or used as-is when absolute) selects which book
`open_book()` opens; `BB_SAMPLE_EPUB` (now host-overridable in `.#eval-driver`/`.#eval`) is the
global fallback. `metadata.epub` reports the resolved path. Both `epub` and `start_page` are declared
on the promptfoo test's `vars`.

Navigation reuses `Tools.execute("navigate", {page=N})` (`GotoPage`, synchronous — the Tier-2
navigate_real spec proves the reader truly lands there). `metadata` now carries `start_page` +
`current_page` so asserts can classify a hit as behind (legal) vs. ahead (spoiler) of the reader.

**`BB_DRY_RUN`** (new): position + seed, then emit reader state and skip the model call — a zero-cost
smoke path for scenario wiring. It immediately earned its keep: it caught that the `bb-tier3-exec`
wrapper forwarded only `$1` (dropping promptfoo's argv[3] context), so per-test vars silently never
reached the driver. Fixed to forward `"$@"`; re-verified via a dry-run *through* promptfoo
(`start_page: 77 -> current_page: 77`). **Lesson for the fan-out: dry-run every new scenario's wiring
(`BB_DRY_RUN=1`, dummy key) before spending on a real run.**

### (historical) original Step 2/3 sketch — superseded by the notes above
### 1. Headless driver — `tests/eval/tier3_driver.lua` (the core risk)
A self-contained luajit script, run inside the koreader runtime (same env as `test-real`):
- Read the task from `argv[1]` (promptfoo's rendered prompt) and `argv[3]` (JSON vars/context).
- `local readerui, Tools = require("tests.integration.real.support").open_book()`.
- Build a settings object exposing `getConfig()` (reuse `bbsettings` or a thin table) with:
  `portkey_api_key = os.getenv("BB_PORTKEY_API_KEY")`, `model = os.getenv("BB_EVAL_MODEL")` (pinned
  cheaper), `enable_thinking = false`, `enable_memory = false`, a modest `max_turns`.
- `local conv = Conversation:new({ ui = readerui, settings = settings })`.
- **Neutralize UI seams** on the instance (no real widgets in headless): stub
  `_ensureStreamingViewer`, `_scheduleFlush`, `_flushNow`, `_render`, `_closeViewer` to no-ops; keep
  error info capturable. (Or stub `bbchatviewer`/`InfoMessage` at the module level.)
- **Pump**: bypass `run()`'s `NetworkMgr:willRerunWhenOnline` gate by driving `_loop` directly —
  `Trapper:wrap(function() local ok, err = pcall(function() conv:_loop() end); done = true;
  UIManager:quit() end)`, then `UIManager:run()`. Follow KOReader's own busted UIManager-pump idiom
  (see `koreader` source `spec/unit/` for the `UIManager:run()`/`quit()` test pattern).
- After completion, walk `conv.messages` → ordered `trace = [{name, input}, …]` (+ paired
  `tool_result` text), final text via `conv:_transcriptText()`, and `conv.usage`.
- Print **one** ProviderResponse JSON to stdout (rapidjson):
  `{"output": "<final text>", "metadata": {"trace": [...], "usage": {...}, "error": <opt>}}`.
  Always include `output` (even `""` on error) so promptfoo doesn't choke.

### 2. promptfoo config — `tests/eval/promptfooconfig.yaml`
- `providers: ['exec: luajit <abs>/tests/eval/tier3_driver.lua']` (env + cwd supplied by the flake
  runner — the exec child inherits them).
- One prompt: passes `{{task}}` straight through.
- One test (the skeleton): `vars: { task: "Highlight the first mention of Verona." }`, with asserts:
  - `type: javascript` (`file://asserts/created_highlight_verona.js`): trace contains a
    `create_highlight` whose resolved page is the first "Verona" occurrence (page 7 region), ideally
    preceded by a `grep`/`book_context`. Reads `context.providerResponse.metadata.trace` (promptfoo
    passes object output pre-parsed).
  - `type: javascript`: no-markdown regex over `output` (`!/[*_#\x60]/`).
  - `type: llm-rubric`: "concise, plain-text, spoiler-free confirmation of the highlight" — grader is
    the pinned cheap model.
- `defaultTest.options.provider` → cheap grader; `evaluateOptions.repeat: 2`; per-test `threshold`
  to absorb rubric variance. Caching left ON (default) to avoid re-spawning on identical inputs.

### 3. Flake runner — new opt-in app in `flake.nix`
A new app (e.g. `.#eval`), **x86_64-linux only, NOT wired into `.#check`**, modeled on `testReal`:
- Reuse the exact koreader-runtime env block (LUA_PATH/CPATH/LD_LIBRARY_PATH, `KO_HOME`,
  `BB_SAMPLE_EPUB`, `SDL_VIDEODRIVER=dummy`, `cd ${ko}`).
- Add `runtimeInputs`: `promptfoo` (nixpkgs; else `nodejs` + `npx promptfoo`), `curl`.
- Require `BB_PORTKEY_API_KEY` from the host env (fail fast if unset); pass `BB_EVAL_MODEL`. **Never**
  embed the key in the derivation/store.
- `exec promptfoo eval -c <plugin>/tests/eval/promptfooconfig.yaml` (consider `-o results.json`).
- Because the `exec:` provider re-enters luajit, ensure the driver's cwd is `${ko}` — either the app
  stays `cd`'d there (child inherits) or the exec command is `sh -c 'cd ${ko} && luajit …'`.

## Verification (end-to-end)

1. `export BB_PORTKEY_API_KEY=…` and `BB_EVAL_MODEL=<cheap slug>`; run `nix run .#eval`.
2. Expect: driver spawns, opens juliet.epub, real model call returns, promptfoo reports the single
   test **passing** all asserts (highlight-on-Verona trace check, no-markdown, rubric).
3. Sanity-isolate the driver alone: `luajit tests/eval/tier3_driver.lua "Highlight the first mention
   of Verona."` inside `nix develop`/the runner env → inspect the emitted JSON (trace has
   `create_highlight`, `output` non-empty).
4. Confirm `nix run .#check` and `.#test`/`.#test-real` are **unchanged** (Tier 3 not in the gate;
   no new `_spec`/`_real` files discovered by those patterns — driver lives under `tests/eval/`).
5. Re-run to confirm it's not flaky (the `repeat: 2` + thresholds should hold).

## Out of scope (this session)

The 20–40-scenario fan-out (per-tool contracts, multi-tool sequences, spoiler/refusal matrix,
restraint cases — a full menu was inventoried and can seed the next session); a parallel Opus+thinking
eval run; `web_search` behaviour; wiring anything into `.#check`. Once the skeleton is green, decision
#1 is settled and the rest is additive `tests:` entries + assertion files.

## Critical files

- **New**: `tests/eval/tier3_driver.lua`, `tests/eval/promptfooconfig.yaml`,
  `tests/eval/asserts/created_highlight_verona.js`.
- **Edit**: `flake.nix` (add the opt-in `.#eval` app; leave `check`/`test`/`test-real` untouched).
- **Reuse (read-only)**: `tests/integration/real/support.lua` (`open_book`), `bbconversation.lua`
  (`new`/`run`/`_loop`/`_transcriptText`), `bbsettings.lua` (`getConfig`), `bbtools.lua` (executors),
  `bbanthropic.lua` (request/creds), `bbstream.lua` (subprocess pacing).
