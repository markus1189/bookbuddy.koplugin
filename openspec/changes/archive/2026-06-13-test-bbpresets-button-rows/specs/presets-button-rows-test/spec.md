## ADDED Requirements

### Requirement: buttonRows chunks presets into rows

The `presets_spec` Tier-1 test SHALL verify that `Presets.buttonRows` groups a flat
preset list into rows of at most `per_row` buttons, defaulting to 2 per row when
`per_row` is omitted.

#### Scenario: Default row width groups two per row

- **WHEN** `buttonRows` is called with a 5-item list and no `per_row` argument
- **THEN** the result has 3 rows
- **AND** the rows contain 2, 2, and 1 buttons respectively

#### Scenario: Explicit per_row honored

- **WHEN** `buttonRows` is called with a 4-item list and `per_row = 3`
- **THEN** the result has 2 rows
- **AND** the rows contain 3 and 1 buttons respectively

### Requirement: buttonRows formats buttons as prefill controls

The test SHALL verify that every generated button carries the trailing-ellipsis label
and non-bold weight that distinguish prefill buttons from action buttons.

#### Scenario: Each button is labelled and weighted as a prefill control

- **WHEN** a row of buttons is generated from a preset whose label is `"Explain"`
- **THEN** the button `text` equals `"Explain…"`
- **AND** the button `font_bold` is `false`

### Requirement: buttonRows wires callbacks to the dialog input

The test SHALL verify that invoking a button's callback prefills the resolved dialog
with the preset's prompt text, and that a nil dialog is tolerated without error.

#### Scenario: Callback prefills the dialog input with the prompt

- **WHEN** a button's `callback` is invoked and `get_dialog()` returns a dialog double
- **THEN** the dialog's `setInputText` is called with the preset's prompt (column 2)

#### Scenario: Callback is a no-op when no dialog is available

- **WHEN** a button's `callback` is invoked and `get_dialog()` returns `nil`
- **THEN** no error is raised
