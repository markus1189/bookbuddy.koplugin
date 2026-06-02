# Guidance for coding agents

## What this is
Single KOReader plugin; repo root **is** the plugin folder. Runs only *inside* KOReader,
never standalone. Source: `bb*.lua` (required by short name, e.g. `require("bbmemory")`),
`main.lua`, `_meta.lua`.

## KOReader API
Required by in-tree path (`require("ui/uimanager")`, etc.). Read the source, don't guess:
- Upstream: https://github.com/koreader/koreader (`frontend/`)
- Local: `~/repos/clones/koreader`

## Conventions
- LuaJIT / Lua 5.1.
- JSON: `rapidjson`. HTTP: `socket.http` + `ltn12`, `curl` fallback. Streaming: forked subprocess (`bbstream.lua`).
- Strings via `_()` (gettext) + `T()` (`ffi/util.template`).
- Persistence: `LuaSettings` (`bbsettings.lua`); per-book memory in `.sdr` sidecar (`bbmemory.lua`).

## Dev shell
`nix develop` (auto via direnv) → `luajit`, `busted`, `luacheck`, `lua-language-server`.

## Tests
- `nix run .#test [-- tests/foo_spec.lua]` — pure busted, stubbed KOReader. Config `.busted`, specs `tests/*_spec.lua`. Scaffolding: `tests/support/{stubs,sse}.lua`.
- `nix run .#test-real` — Tier 2, real crengine over `juliet.epub`, hermetic. Specs `tests/integration/real/*_real.lua`; override `BB_SPEC`/`BB_PLUGIN_DIR`.
- `nix run .#eval` — Tier 3, real model via promptfoo. Billed, opt-in, needs `BB_API_KEY`. `tests/eval/`. See `.plans/tier3-promptfoo.md`.

## Lint / syntax
`luacheck .` — syntax-only: `luajit -bl <file>.lua /dev/null`

## Release
Bump `version` in `_meta.lua` (dotted numeric), push to `main`. `bbupdate.lua` self-updates from `main`'s zip; repo must stay **public**.
