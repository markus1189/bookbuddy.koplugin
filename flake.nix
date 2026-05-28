{
  description = "BookBuddy — KOReader plugin dev shell";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = f:
        nixpkgs.lib.genAttrs systems (system: f (import nixpkgs { inherit system; }));
    in {
      devShells = forAllSystems (pkgs: {
        # luajit runs the headless test harness and syntax checks; luacheck
        # lints; lua-language-server is for editor LSP. No build/runtime deps:
        # the plugin's runtime libs come from KOReader, not from here.
        default = pkgs.mkShell {
          packages = [
            pkgs.luajit
            pkgs.luaPackages.luacheck
            pkgs.lua-language-server
          ];
        };
      });
    };
}
