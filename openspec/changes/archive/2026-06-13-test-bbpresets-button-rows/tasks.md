# Tasks

## 1. Author the spec

- [x] 1.1 Create `tests/presets_spec.lua` with a scope comment and a `describe("Presets.buttonRows")` block that installs stubs in `setup()` and requires `bbpresets`.
- [x] 1.2 Add chunking tests: 5 items / default `per_row` → rows of 2,2,1; 4 items / `per_row=3` → rows of 3,1.
- [x] 1.3 Add formatting tests: button `text` is `"<label>…"` and `font_bold == false`.
- [x] 1.4 Add callback tests: callback calls `setInputText` with the prompt; nil dialog is a no-op.

## 2. Verify

- [x] 2.1 Run `nix run .#test -- tests/presets_spec.lua` — all green.
- [x] 2.2 Run `nix run .#check` — stylua, luacheck, and full busted suite pass.
