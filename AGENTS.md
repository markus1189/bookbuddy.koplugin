# Guidance for coding agents

BookBuddy is a KOReader plugin: a tool-using Claude agent embedded in the e-reader.
Highlight a passage, ask a question; the agent searches and reads the live book through
tools and answers — **spoiler-safe** (it never reveals anything past the reader's current
position unless explicitly asked). It supports multi-turn chat.

## Commands

- `nix run .#check` — **the gate**: `stylua --check` + `luacheck` + `busted`. Run before every commit.
- `nix run .#test [-- tests/foo_spec.lua]` — Tier-1 busted only (fast inner loop). `busted` also runs directly in the dev shell.
- `nix run .#format` (or `stylua .`) — auto-format. Config `stylua.toml` (Lua 5.1, 120 cols, 4-space indent).
- `luacheck .` — lint (config `.luacheckrc`, `std=luajit`). Syntax-only check: `luajit -bl <file>.lua /dev/null`.
- `nix run .#test-real` — Tier-2: real crengine over `juliet.epub`, hermetic (x86_64-linux only). Specs `tests/integration/real/*_real.lua`; override `BB_SPEC`/`BB_PLUGIN_DIR`.
- `nix run .#eval` — Tier-3: real model via promptfoo. Billed, opt-in, needs `BB_API_KEY`. See "Tier-3 eval" below.

`nix run .#check` covers **Tier-1 only**; test-real and eval are separate, opt-in runs.
Tier-1 specs are `tests/*_spec.lua`; shared scaffolding is `tests/support/{stubs,sse}.lua`.

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
- Persistence: `LuaSettings` (`bbsettings.lua`); per-book memory in `.sdr` sidecar (`bbmemory.lua`);
  per-book chat history in `.sdr/bookbuddy_chats/` (`bbchats.lua`: an `index.json` metadata cache
  plus one `<id>.json` payload per chat, capped by `max_saved_chats`, saved only at
  completed-turn boundaries from `Conversation:_render`).
- **Comments are load-bearing**: they encode gateway/API quirks (Vertex web_search pairing,
  OpenRouter null usage, empty-200 retries, role alternation, xpointer drift). Don't strip
  them when editing the logic they explain.

## Dev shell

`nix develop` (auto via direnv) → `luajit`, `busted`, `luacheck`, `stylua`,
`lua-language-server` (plus `luafilesystem` for the memory specs). No build/runtime deps —
the plugin's runtime libs come from KOReader.

## Tier-3 eval (billed)

Agent gateway: `BB_BASE_URL`/`BB_API_KEY`/`BB_EVAL_MODEL`. The `llm-rubric` prose grader is
independent: `BB_GRADER_BASE_URL`/`BB_GRADER_API_KEY`/`BB_GRADER_MODEL` (defaults reuse the
agent's key/OpenRouter; override all three for a separate grader). Full agent+grader run via
Requesty (see `.plans/tier3-promptfoo.md` for the scenario catalog):

```sh
BB_PLUGIN_DIR=$(pwd) \
BB_BASE_URL=https://router.eu.requesty.ai BB_API_KEY=$(pass api/requesty/playground) \
BB_EVAL_MODEL=vertex/claude-opus-4-8@eu \
BB_GRADER_BASE_URL=https://router.eu.requesty.ai/v1 \
BB_GRADER_MODEL=vertex/claude-sonnet-4-6@europe-west1 \
  nix run .#eval -- --filter-pattern C1   # drop the filter to run all scenarios
```

## Release

Bump `version` in `_meta.lua` (dotted numeric), push to `main`. `bbupdate.lua` self-updates
from `main`'s zip; **the repo must stay public** — the update check and download are
unauthenticated, so a private repo breaks self-update for every user.
