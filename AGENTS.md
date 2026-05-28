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

## Tests
Headless harness — no device or network needed. From the plugin root:
```
luajit tests/harness.lua
# or: nix run nixpkgs#luajit -- tests/harness.lua
```
It stubs KOReader, drives the real multi-turn tool loop in `bbconversation.lua` /
`bbanthropic.lua`, validates the Vertex request rules (role alternation, `server_tool_use`
↔ `web_search_tool_result` pairing, client `tool_use`/`tool_result` pairing), and
unit-checks the memory/navigate tools. It exits non-zero on failure. Add scenarios there
when you change the conversation loop or tools.

## Lint
`.luacheckrc` is copied from KOReader (same globals/ignores):
```
luacheck .
# or: nix run nixpkgs#luaPackages.luacheck -- .
```

## Quick syntax check
`luajit -bl <file>.lua /dev/null` parses a file without running its `require`s.

## Releasing / self-update
`bbupdate.lua` self-updates by reading the `version` in `_meta.lua` on the repo's `main`
branch and unpacking that branch's zip over the installed plugin. To ship an update: bump
`version` in `_meta.lua` (dotted numeric, e.g. `1.0.1`) and push to `main`. The repo must
stay **public** for the unauthenticated check/download to work.
