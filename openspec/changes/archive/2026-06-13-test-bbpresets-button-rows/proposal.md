## Why

`bbpresets.lua` is the only `bb*` module with non-trivial logic that has no dedicated
spec, yet its `buttonRows` helper encodes load-bearing UI conventions (row chunking, the
`…` prefill marker, non-bold weight, and callback-to-input wiring). A regression here
would silently break how every preset button behaves. The stub harness already
anticipates the module (`tests/support/stubs.lua:322`), so the only thing missing is the
test.

## What Changes

- Add `tests/presets_spec.lua` covering `Presets.buttonRows` behavior.
- No production code changes — this is a pure characterization/regression spec.

## Capabilities

### New Capabilities
- `presets-button-rows-test`: deterministic Tier-1 coverage for the preset button-row builder.

### Modified Capabilities
<!-- None: no runtime requirement changes. -->

## Impact

- `tests/presets_spec.lua` (new): row-chunking, button formatting, and callback-wiring assertions.
- No changes to `bbpresets.lua` or any runtime module.
