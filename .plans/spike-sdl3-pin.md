# Spike — pin the in-tree real-crengine test environment (SDL3 / glibc)

> Prerequisite gate for Tier 2 (real-crengine tool tests) and Tier 3 (promptfoo agent evals
> over a real book). Time-boxed de-risk, not production test code. Tier 1 (`tier1-busted.md`)
> does **not** depend on this and can proceed in parallel.

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
