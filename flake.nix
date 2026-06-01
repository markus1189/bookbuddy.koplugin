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
          testReal = pkgs.writeShellApplication {
            name = "bookbuddy-test-real";
            runtimeInputs = [ pkgs.coreutils ];
            text = ''
              # Plugin dir + spec default to this flake's (store) copy; override
              # BB_PLUGIN_DIR / BB_SPEC to run against a worktree instead.
              PLUGIN_DIR="''${BB_PLUGIN_DIR:-${self}}"
              SPEC="''${BB_SPEC:-$PLUGIN_DIR/tests/integration/smoke_real.lua}"
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
                --loaders=lua --lazy -- "$SPEC"
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
