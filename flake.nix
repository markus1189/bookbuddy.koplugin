{
  description = "BookBuddy — KOReader plugin dev shell";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
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
