{
  description = "BookBuddy — KOReader plugin dev shell";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  # Source-only inputs for the hermetic real-crengine harness (`.#test-real`).
  # The *built* emulator comes from nixpkgs' prebuilt `koreader` package (the amd64
  # .deb, version v2025.10); these supply the test-only bits that package omits.
  # Pin `koreader` to the SAME version as nixpkgs#koreader so the overlaid spec
  # matches the prebuilt libs/frontend. No submodules needed — only spec/unit. See
  # .plans/spike-sdl3-pin.md.
  inputs.koreader = {
    url = "github:koreader/koreader/v2025.10";
    flake = false;
  };
  inputs.koreader-test-data = {
    url = "github:koreader/test-data";
    flake = false;
  };

  outputs = { self, nixpkgs, koreader, koreader-test-data }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = f:
        nixpkgs.lib.genAttrs systems (system: f (import nixpkgs { inherit system; }));
    in {
      # `nix run .#check` — formatting (stylua) + lint (luacheck) + tests (busted).
      # Runs all three and reports every failure, exiting non-zero if any complains.
      # `nix run .#test` runs just the busted suite (pass-through args, e.g. a single
      # spec: `nix run .#test -- tests/memory_spec.lua`).
      apps = forAllSystems (pkgs:
        let
          check = pkgs.writeShellApplication {
            name = "bookbuddy-check";
            runtimeInputs =
              [ pkgs.stylua pkgs.luaPackages.luacheck pkgs.luajitPackages.busted pkgs.luajit ];
            text = ''
              status=0
              echo "==> stylua --check ."
              stylua --check . || status=1
              echo "==> luacheck ."
              luacheck . || status=1
              echo "==> busted"
              busted || status=1
              exit "$status"
            '';
          };
          format = pkgs.writeShellApplication {
            name = "bookbuddy-format";
            runtimeInputs = [ pkgs.stylua ];
            text = ''
              echo "==> stylua ."
              stylua .
            '';
          };
          test = pkgs.writeShellApplication {
            name = "bookbuddy-test";
            runtimeInputs = [ pkgs.luajitPackages.busted pkgs.luajit ];
            text = ''
              echo "==> busted"
              exec busted "$@"
            '';
          };
          # `nix run .#test-real` — Tier 2: run BookBuddy's tools against a real
          # crengine document, fully hermetic — NO local koreader checkout. The
          # built emulator (libkoreader-cre.so, luajit, frontend, ffi, fonts, data)
          # is nixpkgs' prebuilt `koreader` package (amd64 .deb, v2025.10), grabbed
          # from the binary cache. We overlay the test-only bits it omits: the spec
          # scaffolding (`commonrequire`) from the koreader *source* (same version),
          # juliet.epub from the test-data repo, busted from a nixpkgs luaEnv, and a
          # vendored 3-line busted helper. SDL2 + libstdc++ come from nixpkgs (ABI-
          # coherent with the .deb's glibc). See .plans/spike-sdl3-pin.md.
          ko = "${pkgs.koreader}/lib/koreader";
          luaEnv = pkgs.luajit.withPackages (ps: [ ps.busted ps.luafilesystem ]);
          testRealLibs =
            pkgs.lib.makeLibraryPath [ pkgs.SDL2 pkgs.stdenv.cc.cc.lib ];
          # Pinned Project Gutenberg EPUBs for the Tier-3 eval book matrix
          # (.plans/tier3-promptfoo.md), each chosen for a distinct agentic-eval
          # surface: A Tale of Two Cities (spoiler gate — Carton's sacrifice +
          # the "best of times" opener), Pride and Prejudice (character graph —
          # Wickham/Darcy), Frankenstein (misconception/restraint — creator vs
          # creature, Walton frame), Jekyll and Hyde (compact single-twist gate —
          # they are one man; short, so cheap regression coverage). fetchurl pins each by sha256, so a
          # Gutenberg-side regeneration fails the build LOUDLY instead of
          # silently drifting the page anchors the deterministic asserts key on.
          gutenbergEpub = { name, id, hash }: pkgs.fetchurl {
            inherit name hash;
            url = "https://www.gutenberg.org/cache/epub/${id}/pg${id}.epub";
          };
          # One dir holding every eval book by stable bare name, so the driver's
          # resolveEpub (BB_EPUB_DIR + "/" + a per-test `epub` var) finds each.
          # juliet.epub (from the test-data input) stays the default/sample; the
          # four novels join it here. BB_EPUB_DIR points HERE (not at the raw
          # test-data store) in both Tier-3 runners below.
          evalEpubs = pkgs.runCommand "bb-eval-epubs" { } ''
            mkdir -p "$out"
            ln -s ${koreader-test-data}/juliet.epub "$out/juliet.epub"
            ln -s ${gutenbergEpub {
              name = "pride-and-prejudice.epub";
              id = "1342";
              hash = "sha256-zWnlty7r4Kz88i+ejySZvw1B/n1/e8Bh7cRtohFDnNw=";
            }} "$out/pride-and-prejudice.epub"
            ln -s ${gutenbergEpub {
              name = "frankenstein.epub";
              id = "84";
              hash = "sha256-/Hk2zZBxhqSh701fhYKYlH/6uzPu6NoYCp0KDmY4npo=";
            }} "$out/frankenstein.epub"
            ln -s ${gutenbergEpub {
              name = "a-tale-of-two-cities.epub";
              id = "98";
              hash = "sha256-/xrNqoOrcgm/VAspnt4srpFJsTirJSLnUYG4VJtxrS8=";
            }} "$out/a-tale-of-two-cities.epub"
            ln -s ${gutenbergEpub {
              name = "jekyll-and-hyde.epub";
              id = "43";
              hash = "sha256-woUESS8i7kY4FCw1FqVWuQaImrsskj1DJiU2AA3z10Y=";
            }} "$out/jekyll-and-hyde.epub"
            # jan-vedders-wife (#32144, Amelia E. Barr, 1885) — the OBSCURE-BOOK
            ln -s ${gutenbergEpub {
              name = "jan-vedders-wife.epub";
              id = "32144";
              hash = "sha256-dnzVvh8f0l1oqQRph/N4BiTggos7Ezj+PI5RpxamVqw=";
            }} "$out/jan-vedders-wife.epub"
          '';
          # `nix run .#eval-driver -- "<task>"` — Tier 3 sanity-isolation harness
          # (.plans/tier3-promptfoo.md, Verification #3): run the headless eval
          # driver alone in the koreader runtime and print its ProviderResponse
          # JSON. Reuses test-real's exact env block, then adds the credentialed,
          # billed real-model call — so it is deliberately NOT wired into `.#check`.
          # Pass BB_PLUGIN_DIR=$(pwd) to run a worktree copy (the driver lives under
          # tests/eval/, which flakes don't see until tracked).
          evalDriver = pkgs.writeShellApplication {
            name = "bookbuddy-eval-driver";
            runtimeInputs = [ pkgs.coreutils ];
            text = ''
              if [ -z "''${BB_API_KEY:-}" ]; then
                echo "BB_API_KEY must be set (e.g. from: pass api/openrouter, or pass api/requesty/playground)" >&2
                exit 2
              fi
              PLUGIN_DIR="''${BB_PLUGIN_DIR:-${self}}"
              KO_HOME="$(mktemp -d -t bb-ko.XXXXXX)"; export KO_HOME
              export TESSDATA_PREFIX="${ko}/data"
              export SDL_VIDEODRIVER=dummy
              # Unlike test-real, the driver makes a real HTTPS call, so the forked
              # subprocess loads common/ssl.so, whose NEEDED libssl.so.60/libcrypto.so.57
              # are koreader's vendored OpenSSL in ${ko}/libs. Append that dir (after the
              # nixpkgs libs, so ABI-critical SDL2/libstdc++ still resolve to nixpkgs).
              export LD_LIBRARY_PATH="${testRealLibs}:${ko}/libs''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
              # BB_EPUB_DIR: base for resolving a per-test `epub` var by bare name
              # (tier3_driver.lua resolveEpub); absolute epub paths bypass it.
              # BB_SAMPLE_EPUB stays the global default but is host-overridable, so
              # `BB_SAMPLE_EPUB=/path nix run .#eval-driver` swaps the book sans edits.
              export BB_EPUB_DIR="${evalEpubs}"
              export BB_SAMPLE_EPUB="''${BB_SAMPLE_EPUB:-${evalEpubs}/juliet.epub}"
              # BB_FIXTURE_DIR: base for resolving a per-test `seed_sdr` var by bare
              # name (tier3_driver.lua resolveSeedSdr); absolute paths bypass it.
              export BB_FIXTURE_DIR="$PLUGIN_DIR/tests/eval/fixtures"
              export LUA_PATH="?.lua;frontend/?.lua;common/?.lua;${koreader}/spec/unit/?.lua;$PLUGIN_DIR/?.lua;${luaEnv}/share/lua/5.1/?.lua;${luaEnv}/share/lua/5.1/?/init.lua"
              export LUA_CPATH="?.so;libs/?.so;common/?.so;${luaEnv}/lib/lua/5.1/?.so"
              cd "${ko}" || exit 1
              echo "==> tier3 eval driver (real crengine + real model)" >&2
              exec ./luajit "$PLUGIN_DIR/tests/eval/tier3_driver.lua" "$@"
            '';
          };
          # `nix run .#eval-seed` — regenerate a Tier-3 fixture .sdr by snapshotting
          # the REAL annotation/memory stack (tests/eval/seed_fixture.lua). No API
          # key / no model call; needs the koreader runtime, a writable temp dir, and
          # cp. BB_FIXTURE_OUT = destination .sdr (e.g. tests/eval/fixtures/juliet.sdr);
          # arg[1] / BB_SAMPLE_EPUB = source book; BB_SEED_RECIPE picks the recipe.
          # Regenerate whenever the pinned epub or koreader bumps (xpointers drift).
          evalSeed = pkgs.writeShellApplication {
            name = "bookbuddy-eval-seed";
            runtimeInputs = [ pkgs.coreutils ];
            text = ''
              if [ -z "''${BB_FIXTURE_OUT:-}" ]; then
                echo "BB_FIXTURE_OUT (destination .sdr dir) must be set" >&2
                exit 2
              fi
              PLUGIN_DIR="''${BB_PLUGIN_DIR:-${self}}"
              KO_HOME="$(mktemp -d -t bb-ko.XXXXXX)"; export KO_HOME
              export TESSDATA_PREFIX="${ko}/data"
              export SDL_VIDEODRIVER=dummy
              export LD_LIBRARY_PATH="${testRealLibs}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
              export BB_EPUB_DIR="${evalEpubs}"
              export BB_SAMPLE_EPUB="''${BB_SAMPLE_EPUB:-${evalEpubs}/juliet.epub}"
              export LUA_PATH="?.lua;frontend/?.lua;common/?.lua;${koreader}/spec/unit/?.lua;$PLUGIN_DIR/?.lua;${luaEnv}/share/lua/5.1/?.lua;${luaEnv}/share/lua/5.1/?/init.lua"
              export LUA_CPATH="?.so;libs/?.so;common/?.so;${luaEnv}/lib/lua/5.1/?.so"
              cd "${ko}" || exit 1
              echo "==> tier3 fixture generator (real crengine, no model)" >&2
              exec ./luajit "$PLUGIN_DIR/tests/eval/seed_fixture.lua" "$@"
            '';
          };
          # `bb-tier3-exec` — the promptfoo `exec:` provider entrypoint (Tier 3,
          # .plans/tier3-promptfoo.md Step 2/3). promptfoo invokes it via execFile
          # (NO shell, PATH-resolved) with argv (prompt, optionsJSON, contextJSON);
          # we use only $1 = the task. This wrapper OWNS the full koreader runtime
          # env (mirrors test-real) PLUS the TLS libs for the driver's HTTPS
          # subprocess — kept HERE, not in the `.#eval` app, so the Node/promptfoo
          # process runs with a clean env (no koreader libstdc++/openssl shadowing
          # Node's). It emits ONLY the driver's JSON envelope on stdout (clean for
          # promptfoo); the driver's own stdout/stderr are redirected to our stderr.
          # A fresh per-call KO_HOME gives each run (incl. `repeat`) an empty .sdr.
          evalExec = pkgs.writeShellApplication {
            name = "bb-tier3-exec";
            runtimeInputs = [ pkgs.coreutils ];
            text = ''
              # promptfoo passes argv (prompt, optionsJSON, contextJSON); forward
              # ALL of them so the driver can read arg[1]=task AND arg[3]=context
              # (→ vars.start_page). Forwarding only $1 silently drops per-test vars.
              PLUGIN_DIR="''${BB_PLUGIN_DIR:-${self}}"
              KO_HOME="$(mktemp -d -t bb-ko.XXXXXX)"; export KO_HOME
              export TESSDATA_PREFIX="${ko}/data"
              export SDL_VIDEODRIVER=dummy
              # nixpkgs libs first (ABI-coherent SDL2/libstdc++), then koreader's
              # vendored OpenSSL in ${ko}/libs for common/ssl.so (libssl.so.60).
              export LD_LIBRARY_PATH="${testRealLibs}:${ko}/libs"
              # BB_EPUB_DIR: base for resolving a per-test `epub` var by bare name
              # (tier3_driver.lua resolveEpub); absolute epub paths bypass it.
              # BB_SAMPLE_EPUB stays the global default but is host-overridable, so
              # `BB_SAMPLE_EPUB=/path nix run .#eval-driver` swaps the book sans edits.
              export BB_EPUB_DIR="${evalEpubs}"
              export BB_SAMPLE_EPUB="''${BB_SAMPLE_EPUB:-${evalEpubs}/juliet.epub}"
              # BB_FIXTURE_DIR: base for resolving a per-test `seed_sdr` var by bare
              # name (tier3_driver.lua resolveSeedSdr); absolute paths bypass it.
              export BB_FIXTURE_DIR="$PLUGIN_DIR/tests/eval/fixtures"
              export LUA_PATH="?.lua;frontend/?.lua;common/?.lua;${koreader}/spec/unit/?.lua;$PLUGIN_DIR/?.lua;${luaEnv}/share/lua/5.1/?.lua;${luaEnv}/share/lua/5.1/?/init.lua"
              export LUA_CPATH="?.so;libs/?.so;common/?.so;${luaEnv}/lib/lua/5.1/?.so"
              out="$(mktemp -t bb-eval.XXXXXX.json)"
              trap 'rm -f "$out"' EXIT
              cd "${ko}" || exit 1
              # BB_EVAL_OUT captures clean JSON; the driver's stdout (koreader
              # ffi-load noise + the same JSON) goes to stderr so it can't pollute.
              BB_EVAL_OUT="$out" ./luajit "$PLUGIN_DIR/tests/eval/tier3_driver.lua" "$@" 1>&2 || true
              cat "$out"
            '';
          };
          # `nix run .#eval` — Tier 3 promptfoo runner (the credentialed, billed
          # opt-in; NOT in `.#check`). Runs promptfoo (Node) with a CLEAN env from a
          # writable scratch cwd; the `exec:` wrapper (above) supplies the koreader
          # runtime per provider call. `file://asserts/*` resolve relative to the
          # config dir, not cwd. Requires BB_API_KEY in the host env (never
          # embedded in the store); BB_EVAL_MODEL / BB_MAX_TURNS pass through.
          evalRun = pkgs.writeShellApplication {
            name = "bookbuddy-eval";
            runtimeInputs = [ pkgs.promptfoo evalExec pkgs.coreutils ];
            text = ''
              if [ -z "''${BB_API_KEY:-}" ]; then
                echo "BB_API_KEY must be set (e.g. from: pass api/openrouter, or pass api/requesty/playground)" >&2
                exit 2
              fi
              BB_PLUGIN_DIR="''${BB_PLUGIN_DIR:-${self}}"; export BB_PLUGIN_DIR
              export BB_EVAL_MODEL="''${BB_EVAL_MODEL:-anthropic/claude-opus-4.8}"
              # Grader (llm-rubric) gateway — independent of the agent's gateway, so
              # prose-quality asserts can run on a cheaper/different model. Defaults are
              # coherent for a zero-config OpenRouter run (reuse BB_API_KEY); override
              # all three to grade via Requesty, e.g. BB_GRADER_MODEL=
              # vertex/claude-sonnet-4-6@europe-west1 + a Requesty base/key (the
              # OpenRouter key will NOT authenticate Requesty).
              BB_GRADER_BASE_URL="''${BB_GRADER_BASE_URL:-https://openrouter.ai/api/v1}"
              BB_GRADER_API_KEY="''${BB_GRADER_API_KEY:-$BB_API_KEY}"
              BB_GRADER_MODEL="''${BB_GRADER_MODEL:-anthropic/claude-sonnet-4.6}"
              # promptfoo does NOT interpolate {{env.*}} inside provider config, so we
              # feed the grader the way its OpenAI-compatible provider reads natively:
              # model via `--grader`, gateway+key via OPENAI_BASE_URL / OPENAI_API_KEY
              # (runtime env only — never written to the store). The driver/agent uses
              # bbanthropic with BB_API_KEY/BB_BASE_URL, so these OPENAI_* vars touch
              # only the grader, not the agent.
              export OPENAI_BASE_URL="$BB_GRADER_BASE_URL"
              export OPENAI_API_KEY="$BB_GRADER_API_KEY"
              export PROMPTFOO_DISABLE_TELEMETRY=1
              export PROMPTFOO_DISABLE_UPDATE=1
              CONFIG="$BB_PLUGIN_DIR/tests/eval/promptfooconfig.yaml"
              WORK="$(mktemp -d -t bb-eval-run.XXXXXX)"; cd "$WORK" || exit 1
              echo "==> promptfoo eval (real crengine + real model) $CONFIG" >&2
              exec promptfoo eval --no-cache -j 1 \
                --grader "openai:chat:$BB_GRADER_MODEL" \
                -c "$CONFIG" "$@"
            '';
          };
          testReal = pkgs.writeShellApplication {
            name = "bookbuddy-test-real";
            runtimeInputs = [ pkgs.coreutils ];
            text = ''
              # Plugin dir + spec default to this flake's (store) copy; override
              # BB_PLUGIN_DIR / BB_SPEC to run against a worktree instead. SPEC
              # defaults to the whole real-crengine suite directory; busted
              # discovers *_real.lua within it (the _real pattern, NOT _spec, keeps
              # these out of the pure-luajit `.#test` whose .busted scans for _spec).
              PLUGIN_DIR="''${BB_PLUGIN_DIR:-${self}}"
              SPEC="''${BB_SPEC:-$PLUGIN_DIR/tests/integration/real}"
              KO_HOME="$(mktemp -d -t bb-ko.XXXXXX)"; export KO_HOME
              export TESSDATA_PREFIX="${ko}/data"
              export SDL_VIDEODRIVER=dummy
              export LD_LIBRARY_PATH="${testRealLibs}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
              export BB_SAMPLE_EPUB="${koreader-test-data}/juliet.epub"
              # cwd must be the koreader root so crengine's `libs/?` FFI search and the
              # relative frontend/ffi Lua paths resolve. spec/unit/ supplies
              # commonrequire; the luaEnv tail supplies busted + its deps.
              export LUA_PATH="?.lua;frontend/?.lua;common/?.lua;${koreader}/spec/unit/?.lua;$PLUGIN_DIR/?.lua;${luaEnv}/share/lua/5.1/?.lua;${luaEnv}/share/lua/5.1/?/init.lua"
              export LUA_CPATH="?.so;libs/?.so;common/?.so;${luaEnv}/lib/lua/5.1/?.so"
              cd "${ko}" || exit 1
              echo "==> busted (real crengine, hermetic) $SPEC"
              exec ./luajit -e 'require "busted.runner" {standalone=false}' /dev/null \
                --helper="$PLUGIN_DIR/tests/integration/busted_helper.lua" \
                --loaders=lua --lazy --pattern=_real -- "$SPEC"
            '';
          };
        in {
          check = {
            type = "app";
            program = "${check}/bin/bookbuddy-check";
          };
          format = {
            type = "app";
            program = "${format}/bin/bookbuddy-format";
          };
          test = {
            type = "app";
            program = "${test}/bin/bookbuddy-test";
          };
        } // nixpkgs.lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "x86_64-linux") {
          # x86_64-linux only: nixpkgs#koreader repackages the amd64 .deb.
          test-real = {
            type = "app";
            program = "${testReal}/bin/bookbuddy-test-real";
          };
          eval-driver = {
            type = "app";
            program = "${evalDriver}/bin/bookbuddy-eval-driver";
          };
          eval-seed = {
            type = "app";
            program = "${evalSeed}/bin/bookbuddy-eval-seed";
          };
          eval = {
            type = "app";
            program = "${evalRun}/bin/bookbuddy-eval";
          };
        });

      devShells = forAllSystems (pkgs: {
        # luajit runs syntax checks and the busted suite; busted is the test
        # runner (KOReader's own), with luafilesystem for the memory specs'
        # real lfs; luacheck lints; stylua formats (config in stylua.toml);
        # lua-language-server is for editor LSP. No build/runtime deps: the
        # plugin's runtime libs come from KOReader, not from here.
        default = pkgs.mkShell {
          packages = [
            pkgs.luajit
            pkgs.luajitPackages.busted
            pkgs.luajitPackages.luafilesystem
            pkgs.luaPackages.luacheck
            pkgs.stylua
            pkgs.lua-language-server
          ];
        };
      });
    };
}
