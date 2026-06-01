# Tier 1 — pure-luajit busted unit tests

> **STATUS: ✅ DONE.** busted suite wired into `.#test`/`.#check`; shared scaffolding in
> `tests/support/{stubs,sse}.lua`; specs for conversation/anthropic/request-validation/memory/
> update/settings (64 checks, green). `harness.lua` deleted; its document-coupled tool-executor
> tests moved to `tests/integration/tools.lua` (parked for Tier 2, 111 checks). `.busted` lives
> at the repo root (not `tests/`) because busted only auto-discovers config in the cwd. Test-only
> `Updater._test` export added to `bbupdate.lua`; `AGENTS.md` updated.

> One of three tiers in the BookBuddy testing concept. Tier 1 = pure-luajit unit tests in
> `.#check`; Tier 2 = real-crengine in-tree tool tests; Tier 3 = promptfoo agent evals.
> Tier 1 is **independent** and can proceed now (no koreader build needed). Tier 2/3 are gated
> on the spike (`spike-sdl3-pin.md`).

## Context
Tests today are one 2,282-line `tests/harness.lua` with hand-rolled pass/fail counters, not
wired into `nix run .#check`, and it *stubs out* the most testable modules (`bbmemory`,
`bbupdate`, `bbsettings` have zero coverage). Tier 1 replaces the document-free portion of the
harness with a real framework (**busted**, what KOReader itself uses), splits the monolith into
focused specs, closes those coverage gaps, and gates it all in `.#check`. Document-touching
tool tests are explicitly **out of scope** here — they require real crengine and live in Tier 2
(blocked on the spike). Outcome: fast, offline, single-spec-runnable tests that fail loudly and
keep `main` (the release channel) honest.

## Scope — in
Loop/request-shape logic, SSE parsing, and the currently-untested pure modules:
- Conversation loop scenarios (request shape, `pause_turn` resume, tool pairing,
  stop-during-tool, error recovery) — driven by scripted SSE, **not** real tools/documents.
- `bbanthropic` (`buildBody`, `newStreamParser`, `stripMarkdown`, system-prompt assembly,
  cache breakpoints, usage extraction); the request validator.
- `bbmemory` (real `Store`), `bbupdate` (semver helpers), `bbsettings` (config getters).

## Scope — out
Real tool execution against a document (grep/read/navigate/create_highlight against crengine)
→ Tier 2. Anything needing the koreader build/emulator.

## Framework wiring
- Add busted to the dev shell and a `nix run .#test` app in `flake.nix`; extend `.#check` to
  run busted after stylua + luacheck (exit non-zero on any failure). **Confirm the exact nixpkgs
  attr** (`luajitPackages.busted` vs `lua51Packages.busted`) — KOReader runtime is LuaJIT/5.1.
- `tests/.busted` config: `lua = "luajit"`, `lpath = "./?.lua;./tests/?.lua"`, default pattern
  `_spec`.
- **Isolation via busted's per-file `insulate` (default), not a global preload helper.** Each
  spec installs its own doubles in `setup()` and requires the module under test there, so a
  *stubbed* `bbmemory` in `conversation_spec` cannot leak into `memory_spec`'s *real* one.
  package.loaded is rolled back per insulated block.

## Shared scaffolding — extract from `harness.lua` into `tests/support/`
- `tests/support/stubs.lua` — exposes `install()` that registers the lightweight KOReader stubs
  into `package.loaded` (`logger`, `gettext`, `ffi/util`, `util`, `ui/uimanager` + `tick_queue`,
  `ui/trapper`, `ui/network/manager`, the widget stubs, `rapidjson`) plus the standalone JSON
  codec. Optional doubles `install_bbtools_stub()` / `install_bbmemory_stub()` for loop specs.
  Source: `harness.lua:14–348`.
- `tests/support/sse.lua` — `buildTurnSSE`, `webResults`, a **factory** `new_fake_stream(responses)`
  (per-test instance, not a module singleton), `validateMessages`, and a `capture_build_body()`
  helper returning the captured requests. Source: `harness.lua:352–594`.

## Specs (mirror current coverage, then add)
- `tests/conversation_spec.lua` — ports S1–S9. `setup()` installs stubs + `bbtools`/`bbmemory`
  doubles + a fresh fake stream, then `require("bbconversation")`; each `it` asserts via
  `validateMessages` + the existing `expect_*` checks (text, seed contains/absent, request
  count, final-valid). Per-test fake-stream and captured-requests reset in `before_each`.
- `tests/anthropic_spec.lua` — `buildBody` shapes, `newStreamParser` SSE reassembly (text,
  thinking, server_tool_use+web_search_tool_result, tool_use, usage), `stripMarkdown`,
  system-prompt assembly, rolling cache breakpoints, usage extraction.
- `tests/request_validation_spec.lua` — validator meta-tests (rejects role-non-alternation,
  dangling server/client tool calls, bad first role).
- `tests/memory_spec.lua` — **real** `Memory.new(mktemp_dir)`; exercises `_resolve` sandboxing
  (reject `../` / absolute escapes), view/create/str_replace/insert/delete/rename. Provide
  `libs/libkoreader-lfs` → **luafilesystem** (add as test dep) and stub
  `docsettings`/`util`/`ffi/util`/`gettext`. Construct `Store` directly to bypass
  `baseDirForBook(ui)` (the only KOReader-coupled entry). Refs: `bbmemory.lua:60` (`Memory.new`),
  `:66` (`_resolve`), `:371` (`execute`).
- `tests/update_spec.lua` — `parseVersion`/`isNewer`/`composeBranchZipUrl`. **Requires a small
  source change:** these are `local` (`bbupdate.lua:23,31,91`); add a test-only export table at
  the file bottom, e.g. `Updater._test = { parseVersion = parseVersion, isNewer = isNewer,
  composeBranchZipUrl = composeBranchZipUrl }`. Requiring `bbupdate` pulls in
  device/uimanager/widgets → covered by `stubs.install()`.
- `tests/settings_spec.lua` — `get`/`getConfig`/`isConfigured` against an in-memory `LuaSettings`
  stub + `DataStorage` stub; assert `DEFAULTS` fallback and `max_turns` clamp
  (`bbsettings.lua:50–56`). Stub `bbmemory`/`bbupdate` (pulled in at `bbsettings.lua:11–12`).

## Migration & cleanup
Build `support/` + specs while `luajit tests/harness.lua` still runs. When the busted suite
covers every ported scenario/unit check (parity), **delete the document-free portions of
`harness.lua`**; the tool-executor checks stay parked until Tier 2 absorbs them (keep that slice
of `harness.lua` or move it to `tests/integration/` stubs until then — note in the PR).

## Files
**New:** `tests/.busted`, `tests/support/{stubs,sse}.lua`, `tests/conversation_spec.lua`,
`tests/anthropic_spec.lua`, `tests/request_validation_spec.lua`, `tests/memory_spec.lua`,
`tests/update_spec.lua`, `tests/settings_spec.lua`.
**Modified:** `flake.nix` (devShell += busted, luafilesystem; `.#test` app; `.#check` += busted),
`bbupdate.lua` (test-only `_test` export), `AGENTS.md` (document `nix run .#test`).
**Reused:** `harness.lua:14–348` (stubs/JSON), `harness.lua:352–594` (SSE + validator).

## Verification
- `nix run .#test` → all specs green; `busted tests/memory_spec.lua` runs a single spec.
- `nix run .#check` → stylua + luacheck + busted, exits non-zero if any fail.
- `luacheck .` stays clean (the `_test` export must not trip unused-global rules).
- Parity: each old harness loop/logic check has a corresponding green spec before deleting it.
