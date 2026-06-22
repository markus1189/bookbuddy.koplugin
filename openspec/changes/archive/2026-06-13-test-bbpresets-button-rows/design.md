## Context

`bbpresets.lua` loads three KOReader modules (`gettext`, `ffi/util`, `ui/font`), all of
which are already doubled in `tests/support/stubs.lua`. The `gettext` stub returns its
argument verbatim and the `ffi/util.template` stub expands `%1`-style placeholders, so
`T(_("%1…"), "Explain")` resolves to `"Explain…"` headlessly — labels are assertable
without a real device.

## Goals / Non-Goals

**Goals:**
- Deterministic Tier-1 coverage of `Presets.buttonRows`: chunking, label/weight, callbacks.
- Match the house spec style: top comment explaining scope, `stubs.install()` in `setup()`
  before requiring the module, plain `assert.*` checks.

**Non-Goals:**
- Testing `Presets.inputLines` pixel math (DPI-dependent, low value) or the static preset
  tables (`book`/`passage`/`followup`) — those are data, not logic.
- Any change to `bbpresets.lua` or runtime modules.

## Decisions

### Decision 1: Require the module after install(), under insulate

The spec calls `stubs.install()` in `setup()` so `bbpresets`'s load-time `require`s resolve
to the doubles, then `require("bbpresets")`. busted's per-block `insulate` rolls
`package.loaded` back afterwards, so the stubbed module cannot leak into other specs —
the same pattern the existing specs use.

### Decision 2: Drive callbacks through a captured-dialog double

To assert callback wiring, the spec builds rows with a `get_dialog` that returns a small
table recording the `setInputText` arguments, then invokes `row[i].callback()` directly
and asserts the recorded prompt. The nil-dialog case passes a `get_dialog` returning
`nil` and asserts the callback runs without error.
