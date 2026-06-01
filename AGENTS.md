# Guidance for coding agents

## What this is
BookBuddy is a single [KOReader](https://github.com/koreader/koreader) plugin, and this
repo's root **is** the plugin folder (`bookbuddy.koplugin`). It runs *inside* KOReader —
you cannot execute the plugin standalone. Source files are `bb*.lua` (required by short
name, e.g. `require("bbmemory")`) plus `main.lua` and `_meta.lua`.

## Reference the KOReader source
KOReader modules are required by their in-tree paths — `require("ui/uimanager")`,
`require("ui/widget/confirmbox")`, `require("ui/network/manager")`, `require("device")`,
`require("datastorage")`, and so on. To learn an API, **read the KOReader source instead
of guessing**:
- Upstream: https://github.com/koreader/koreader (look under `frontend/`)
- Local checkout on this machine: `/home/markus/repos/clones/koreader`. This plugin is
  also developed there as a second tree at `plugins/bookbuddy.koplugin`.

## Conventions
- LuaJIT / Lua 5.1 (KOReader's runtime). No external Lua deps beyond what KOReader bundles.
- JSON via `rapidjson` (bundled). HTTP via `socket.http` + `ltn12`, with a `curl` fallback
  (`bbanthropic.lua`, `bbupdate.lua`). Streaming runs in a forked subprocess
  (`bbstream.lua`) so the UI stays responsive.
- User-facing strings go through `_()` (gettext) and `T()` (`require("ffi/util").template`).
- Replies render as **plain text, no markdown** — a product constraint baked into the
  system prompt. Don't assume a markdown renderer.
- Settings persist via `LuaSettings` (`bbsettings.lua`); per-book memory lives in the
  book's `.sdr` sidecar (`bbmemory.lua`).

## Dev environment
`flake.nix` provides a dev shell with `luajit`, `busted`, `luafilesystem`, `luacheck`, and
`lua-language-server`. With [direnv](https://direnv.net) it loads automatically on `cd`
(`.envrc` is `use flake`); otherwise run `nix develop`. The commands below assume that shell.
Without Nix, substitute `nix run nixpkgs#luajit -- …` and `nix run nixpkgs#luaPackages.luacheck -- …`.

## Tests
Headless [busted](https://lunarmodules.github.io/busted/) suite — no device or network needed.
From the plugin root:
```
nix run .#test                      # whole suite
nix run .#test -- tests/memory_spec.lua   # a single spec
```
(Or `busted` directly inside the dev shell.) Config is `.busted` at the repo root (runs under
LuaJIT, specs are `tests/*_spec.lua`). The suite stubs KOReader and exercises the real code:
- `conversation_spec` — the multi-turn tool loop (`bbconversation`): request shape, `pause_turn`
  resume, tool pairing, stop-during-tool, error recovery; plus tool-action phrasing and markdown
  stripping. Scenarios are driven by scripted SSE, validated against the Vertex request rules
  (role alternation, `server_tool_use` ↔ `web_search_tool_result` pairing, client
  `tool_use`/`tool_result` pairing).
- `anthropic_spec` — `buildBody` (system-prompt assembly, rolling cache breakpoints) and
  `newStreamParser` SSE reassembly/usage extraction.
- `request_validation_spec` — meta-tests proving the request validator rejects bad arrays.
- `memory_spec` / `update_spec` / `settings_spec` — the pure modules against real/in-memory
  backends.
- `tools_spec` — the `bbtools` executors' **engine-agnostic** logic against trivial fake `ui`s:
  input validation, the dispatch contract (which `Event` a tool emits and with what args),
  occurrence/ambiguity math, and the error guards. Behaviour that needs a real document lives in
  the Tier 2 real-crengine suite (below), not here.

Shared scaffolding lives in `tests/support/{stubs,sse}.lua` (KOReader doubles + the JSON codec;
SSE builders, a fake stream, the validator). Add scenarios/specs there and in the matching
`_spec` when you change the loop, the parser, or a pure module.

The document-coupled tool-executor coverage is split by what each check actually needs (the old
hand-rolled-fakes file `tests/integration/tools.lua` has been retired): the engine-agnostic half
lives in `tools_spec` (above, pure-luajit `.#test`); everything that touches a real document is the
Tier 2 suite below.

**Tier 2 (real crengine) — `nix run .#test-real`.** Runs BookBuddy's tools against a real
document (`juliet.epub`) with real crengine — **fully hermetic, no local koreader checkout**.
Specs live in `tests/integration/real/*_real.lua` (the `_real` suffix, **not** `_spec`, keeps them
out of the pure-luajit `.#test` whose `.busted` discovers `_spec`); `BB_SPEC` defaults to that whole
directory and busted discovers them via `--pattern=_real`. They open a live `ReaderUI` over
`juliet.epub` (shared scaffolding: `tests/integration/real/support.lua`) and assert real behaviour:
`context_real` (title/author/page-count, TOC with resolvable `loc` tokens), `grep_real` (real
page-tagged hits, the regex flag, sentence context, the spoiler page-cap vs the reader's real page),
`read_real` (word-by-word forward stepping, continuation locators, the spoiler refuse/clamp gates,
real end-of-book), `navigate_real` (page/percent/chapter `GotoXPointer`/back truly moving the page),
`highlight_real` (the create→list→note→append round-trip through the real annotation store —
highlights persist to the `.sdr` sidecar under the shared `KO_HOME`, so count-sensitive specs reset
`annotation.annotations` in `setup()`), and `smoke_real` (the original minimal sanity check).
The built emulator (libkoreader-cre.so, luajit, frontend, ffi, fonts, data) is nixpkgs' prebuilt
`koreader` package (the amd64 .deb, `v2025.10`, pulled from the binary cache). The flake overlays
the test-only bits that package omits: `commonrequire` from the `koreader` source input (pinned to
the same `v2025.10`), `juliet.epub` from the `koreader-test-data` input, busted from a nixpkgs
luaEnv, a vendored `tests/integration/busted_helper.lua`, and SDL2 + libstdc++ from nixpkgs. To bump
the koreader version, move `nixpkgs#koreader` and the `koreader` input in lockstep. Spec/plugin dir
default to the flake source; override with `BB_SPEC` / `BB_PLUGIN_DIR` to run a worktree copy.
x86_64-linux only (nixpkgs#koreader repackages the amd64 .deb). Background: `.plans/spike-sdl3-pin.md`.

**Tier 3 (real model — promptfoo agent evals) — `nix run .#eval`.** Drives the genuine
`bbconversation` loop against a **real model** over the Tier-2 harness, graded by
[promptfoo](https://promptfoo.dev). Non-hermetic, credentialed, billed — an opt-in, **NOT** in
`.#check`; needs `BB_PORTKEY_API_KEY` in the env. Files under `tests/eval/`; x86_64-linux only.
Full design and knobs: `.plans/tier3-promptfoo.md`.

## Lint
`.luacheckrc` is copied from KOReader (same globals/ignores):
```
luacheck .
```

## Quick syntax check
`luajit -bl <file>.lua /dev/null` parses a file without running its `require`s.

## Releasing / self-update
`bbupdate.lua` self-updates by reading the `version` in `_meta.lua` on the repo's `main`
branch and unpacking that branch's zip over the installed plugin. To ship an update: bump
`version` in `_meta.lua` (dotted numeric, e.g. `1.0.1`) and push to `main`. The repo must
stay **public** for the unauthenticated check/download to work.
