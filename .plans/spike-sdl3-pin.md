# Spike — pin the in-tree real-crengine test environment (SDL3 / glibc)

> Prerequisite gate for Tier 2 (real-crengine tool tests) and Tier 3 (promptfoo agent evals
> over a real book). Time-boxed de-risk, not production test code. Tier 1 (`tier1-busted.md`)
> does **not** depend on this and can proceed in parallel.

> **STATUS: ✅ SPIKE DONE — all three DODs green.** The glibc ABI clash was caused by feeding the
> emulator an *arbitrary-nixpkgs* SDL3 (3.4.8, needs glibc 2.42) when koreader-base links
> **glibc-2.40-66**. The fix needs no rebuild: koreader's own `tools/shell.nix` pins
> **nixos-25.05**, which ships **sdl3-3.2.20** (glibc-2.40 match) *and already* exports
> `LD_LIBRARY_PATH=${pkgs.sdl3}/lib`. Running inside `nix-shell tools/shell.nix`:
> - **DOD #1** — upstream `spec/front/unit/readersearch_spec.lua` (real `juliet.epub`): **16/0/0**, exit 0.
> - **DOD #2** — BookBuddy smoke spec (`tests/integration/_smoke_spec.lua`): **2/0/0**. Real `ReaderUI`
>   over `juliet.epub`; `book_context` returned a real crengine page count, `grep "Verona"` returned a
>   real `[page N] (loc:K)` hit.
> - **DOD #3** — both runs were cold (fresh `KO_HOME`, no hand-tweaking); the runner
>   `tests/integration/run_smoke.sh` reproduces green from a clean shell.
>
> ### Env strategy DECISION — (a): SDL3 from koreader's `tools/shell.nix`
> Reject (b)/(c): no `nix-ld`/FHS shim and no base rebuild are needed; the glibc-coherent SDL3 is the
> one the build shell already provides. Recipe (all in `tests/integration/run_smoke.sh`):
> - **cwd:** the emulator install dir `…/koreader-emulator-x86_64-unknown-linux-gnu-debug/koreader`.
> - **SDL3:** enter `nix-shell "$KOREADER_DIR/tools/shell.nix"` → `LD_LIBRARY_PATH` points at
>   `…-sdl3-3.2.20-lib/lib` (glibc-2.40). Do **not** add stray SDL3 paths.
> - **env:** `KO_HOME=$(mktemp -d)`, `TESSDATA_PREFIX=$PWD/data`, `SDL_VIDEODRIVER=dummy`.
> - `LUA_CPATH='?.so;common/?.so;spec/rocks/lib/lua/5.1/?.so'`
> - `LUA_PATH='?.lua;common/?.lua;frontend/?.lua;spec/front/unit/?.lua;spec/rocks/share/lua/5.1/?.lua;spec/rocks/share/lua/5.1/?/init.lua;$PLUGIN_DIR/?.lua'`
>   — the trailing `$PLUGIN_DIR/?.lua` makes `require("bbtools")` resolve by short name; bbtools pulls in
>   only KOReader modules (Event/logger/util/gettext/ffi-util/rapidjson), no `bb*` siblings, so no plugin
>   symlink into `plugins/` is required for a direct-`require` smoke spec.
> - **runner:** `./luajit -e 'require "busted.runner" {standalone=false}' /dev/null --helper=spec/helper.lua
>   --loaders=lua --lazy -- <abs path to spec>` (busted takes an absolute spec path; the spec itself loads
>   `commonrequire`/`disable_plugins`).
>
> ### Spec for the Tier-2 `.#test-real` flake app — SUPERSEDED, now fully hermetic
> The original plan located a prebuilt checkout via `$KOREADER_DIR` + `nix-shell tools/shell.nix`.
> **That dependency is gone.** `nix run .#test-real` now needs **no local koreader checkout**:
> - Built emulator = **`nixpkgs#koreader`** (the amd64 .deb, `v2025.10`, from the binary cache) →
>   `${koreader}/lib/koreader` provides libs/luajit/frontend/ffi/fonts/data.
> - Overlaid test-only bits: `commonrequire` from the `koreader` **source** input (pinned to the same
>   `v2025.10`); `juliet.epub` from the `koreader-test-data` input (via `BB_SAMPLE_EPUB`); busted from
>   `luajit.withPackages [busted luafilesystem]`; a vendored `tests/integration/busted_helper.lua`
>   (3 lines — replaces koreader-base's test-runner helper, so **no submodules** are fetched).
> - **The .deb links SDL2, not SDL3** (and is patchelf'd to glibc-2.42), so the whole glibc-2.40 / 25.05
>   SDL3 pin is dropped: `LD_LIBRARY_PATH = nixpkgs SDL2 + libstdc++`. cwd = the koreader store root so
>   crengine's `libs/?` FFI search resolves.
> Result: `2/0/0` green from a clean machine with only the binary cache. Tradeoff: test stack tracks
> `nixpkgs#koreader`'s release cadence — bump it and the `koreader` source input in lockstep.
> Still-open (unchanged): whether a future spec using `load_plugin` needs the plugin symlinked into
> `plugins/` vs. the current direct `require("bbtools")` via `$PLUGIN_DIR/?.lua`.

---
*Original spike plan below — kept for context.*

## Context
Tier 2/3 depend on running BookBuddy's tools inside KOReader's **real** test harness — real
Device (dummy framebuffer), real crengine, real `juliet.epub` via
`DocumentRegistry:openDocument` — exactly as `spec/unit/readersearch_spec.lua` does.
Empirically (this machine, `/home/markus/repos/clones/koreader`): koreader-base is **built**, the
emulator install dir is assembled (`koreader-emulator-x86_64-unknown-linux-gnu-debug/koreader`,
with `frontend`, `spec/front`, `spec/front/unit/data → test/` symlinks; `juliet.epub` present),
and a direct busted run got crengine loading and FFI-binding `utf8proc`/`blitbuffer` — blocking
**only** at the emulator's SDL3 + a glibc ABI clash (`GLIBC_ABI_DT_X86_64_PLT`) when SDL3 came
from an arbitrary nixpkgs. This spike establishes a coherent, reproducible env so a real-crengine
spec runs green, then decides the env strategy the `.#test-real` app will encode.

## Goal / definition of done
1. `spec/front/unit/readersearch_spec.lua` (real `juliet.epub`) runs **green** headlessly.
2. A **trivial BookBuddy smoke spec** runs green: plugin symlinked into `plugins/`,
   `require("commonrequire")`, open `juliet.epub`, build a real `ReaderUI`, call
   `bbtools.execute("book_context", …)` and `bbtools.execute("grep", {query=...})`, assert a
   real page-tagged hit comes back.
3. A **documented, repeatable recipe** (env vars + dependency source + symlink layout) and a
   **decision** on the env strategy, captured for the Tier-2 `.#test-real` flake app and AGENTS.md.

## Starting point (already established — don't re-derive)
From the koreader emulator install dir
(`koreader-emulator-x86_64-unknown-linux-gnu-debug/koreader`), this got to the SDL3 step:
- `KO_HOME=$(mktemp -d)`, `TESSDATA_PREFIX=$PWD/data`, `SDL_VIDEODRIVER=dummy`.
- `LUA_CPATH='?.so;common/?.so;spec/rocks/lib/lua/5.1/?.so'`
- `LUA_PATH='?.lua;common/?.lua;frontend/?.lua;spec/front/unit/?.lua;spec/rocks/share/lua/5.1/?.lua;spec/rocks/share/lua/5.1/?/init.lua'`
  (the `spec/front/unit/?.lua` entry is what makes `commonrequire` resolvable.)
- `./luajit -e 'require "busted.runner" {standalone=false}' /dev/null --helper=spec/helper.lua --loaders=lua --lazy -- spec/front/unit/readersearch_spec.lua`
- Failure: SDL3 found but `GLIBC_ABI_DT_X86_64_PLT not found` — stock-nixpkgs SDL3 (needs glibc
  2.42) vs koreader-base's glibc (2.40). SDL3 store paths already on disk:
  `/nix/store/57xmjlh9…-sdl3-3.4.8-lib`, `…-sdl3-3.2.20-lib`, `…-sdl3-3.4.2-lib`.

## Steps
1. **Identify koreader-base's toolchain.** `ldd` / inspect RPATH of
   `base/build/x86_64-unknown-linux-gnu-debug/luajit` and `libs/libkoreader-cre.so` to find the
   exact glibc store path; check the koreader checkout for any nix file / `.envrc` / direnv /
   build notes. **Ask the user how they built koreader-base on May 28** (which nix shell /
   nixpkgs rev) — fastest path to a matching SDL3.
2. **Get a glibc-compatible SDL3**, cheapest first:
   (a) source SDL3 from the **same nixpkgs rev/stdenv** that built base (matching glibc);
   (b) `nix-ld` / an FHS-ish `LD_LIBRARY_PATH` that supplies the build's glibc alongside SDL3;
   (c) rebuild koreader-base inside a **plugin-provided emulator devshell** that pins nixpkgs +
   SDL3 + toolchain (most robust, most work). Pick the first that yields DOD #1.
3. **Green the upstream spec** (`readersearch_spec.lua`) using the chosen SDL3 — proves the env.
4. **Green a BookBuddy smoke spec** (DOD #2): symlink `bookbuddy.koplugin` into `plugins/` (or
   put its modules on `LUA_PATH`), `load_plugin("bookbuddy.koplugin")` or directly
   `require("bbtools")`, exercise `book_context` + `grep` against the real document.
5. **Capture the recipe & decide.** Record exact env (LUA_PATH/LUA_CPATH/LD_LIBRARY_PATH/KO_HOME/
   TESSDATA_PREFIX/SDL_*), the SDL3 source, and the symlink layout. Decide strategy (a/b/c) and
   whether `.#test-real` locates the checkout via `$KOREADER_DIR` or vendors a thin runner. This
   output is the spec for the Tier-2 `.#test-real` app — not built in this spike.

## Risks / notes
- glibc coherence is the crux; if base was built outside Nix or with an unknown rev, strategy
  (c) (rebuild in a pinned devshell) is the reliable fallback — heavier but reproducible.
- Keep the spike's smoke spec throwaway; real Tier-2 specs come after the env is decided.
- Out of scope: writing all Tier-2 tool specs, the promptfoo eval runner, any `.#check` changes.

## Files (spike)
Throwaway/manual only — a smoke spec under `tests/integration/_smoke_spec.lua` and shell notes;
**no `flake.nix` changes** until the strategy is decided. The durable deliverable is the
documented recipe + decision (folded into this file, then later AGENTS.md).

## Verification
- DOD #1: upstream `readersearch_spec.lua` exits 0 (real crengine, real epub).
- DOD #2: the BookBuddy smoke spec returns a real page-tagged grep hit from `juliet.epub`.
- DOD #3: re-running the recorded command from a clean shell reproduces green (no hand-tweaking).
