{
  description = "BookBuddy — KOReader plugin dev shell";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = f:
        nixpkgs.lib.genAttrs systems (system: f (import nixpkgs { inherit system; }));
    in {
      # `nix run .#check` — formatting (stylua) + lint (luacheck). Runs both
      # and reports all failures, exiting non-zero if either complains.
      apps = forAllSystems (pkgs:
        let
          check = pkgs.writeShellApplication {
            name = "bookbuddy-check";
            runtimeInputs = [ pkgs.stylua pkgs.luaPackages.luacheck ];
            text = ''
              status=0
              echo "==> stylua --check ."
              stylua --check . || status=1
              echo "==> luacheck ."
              luacheck . || status=1
              exit "$status"
            '';
          };
        in {
          check = {
            type = "app";
            program = "${check}/bin/bookbuddy-check";
          };
        });

      devShells = forAllSystems (pkgs: {
        # luajit runs the headless test harness and syntax checks; luacheck
        # lints; stylua formats (config in stylua.toml); lua-language-server
        # is for editor LSP. No build/runtime deps: the plugin's runtime libs
        # come from KOReader, not from here.
        default = pkgs.mkShell {
          packages = [
            pkgs.luajit
            pkgs.luaPackages.luacheck
            pkgs.stylua
            pkgs.lua-language-server
          ];
        };
      });
    };
}
