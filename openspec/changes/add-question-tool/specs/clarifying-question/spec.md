## ADDED Requirements

### Requirement: The agent can ask the reader a clarifying question mid-turn

The system SHALL expose an `ask_user` tool to the main agent that accepts a natural-language
`question` and an optional short list of `options`, pauses the conversation turn, presents the
question to the reader, and returns the reader's answer as the tool's result. The main agent
SHALL continue the same turn using that answer like any other tool result.

#### Scenario: Question returns the reader's answer

- **WHEN** the main agent calls `ask_user` with a question and the reader responds
- **THEN** the tool result is the reader's chosen option or typed text, and the agent continues
  the same turn with that answer available

#### Scenario: Options are offered as choices

- **WHEN** the agent supplies a list of options
- **THEN** the reader is offered those options to pick from, and may instead type their own answer

#### Scenario: Free-text question without options

- **WHEN** the agent supplies a question with no options
- **THEN** the reader is asked to type a free-text answer

#### Scenario: The tool is gated by a setting

- **WHEN** the clarifying-question feature is disabled in settings
- **THEN** the `ask_user` tool is not advertised to the model and no mid-turn question can occur

### Requirement: A clarifying question pauses the turn without ending it

The system SHALL pause the in-progress turn while the question is shown and resume the **same**
turn once the reader answers, rather than ending the turn and requiring the reader to start a new
one.

#### Scenario: Turn resumes after the answer

- **WHEN** the reader answers a clarifying question
- **THEN** the agent resumes the same turn and may issue further tool calls or produce its answer
  without the reader having to re-prompt

#### Scenario: Agent waits for the answer

- **WHEN** a clarifying question is awaiting a reply
- **THEN** the agent does not advance past the asking step until the reader answers or skips

### Requirement: A clarifying question can always be answered or skipped without hanging

The system SHALL ensure that every way of closing the question — choosing an option, typing an
answer, skipping, or dismissing the dialog — resumes the paused turn exactly once. The agent
SHALL never be left waiting indefinitely on a question.

#### Scenario: Skipping returns a recoverable result

- **WHEN** the reader skips the question instead of answering
- **THEN** the tool result is a note that the reader skipped, which the agent can recover from by
  proceeding or asking differently

#### Scenario: Dismissing the dialog resumes the turn

- **WHEN** the reader dismisses the question dialog without using a provided button
- **THEN** the turn still resumes with a skip result rather than hanging

#### Scenario: The asking step is always answered in history

- **WHEN** a clarifying question is shown and then closed by any means
- **THEN** the asking tool step is recorded with a corresponding result, leaving no unanswered
  tool call in the conversation history

### Requirement: Clarifying questions obey the spoiler boundary

The system SHALL treat the question and option text shown to the reader as reader-facing output
bound by the same current-position spoiler rule as the agent's answers. A clarifying question
SHALL NOT reveal content past the reader's current position unless the reader has explicitly asked
to read ahead.

#### Scenario: Question text is spoiler-bound

- **WHEN** the agent phrases a clarifying question or its options
- **THEN** that text is subject to the same spoiler rule as the agent's answer and does not surface
  content from beyond the reader's current position

### Requirement: Subagents cannot ask the reader questions

The system SHALL withhold the `ask_user` tool from subagents, which run headless with no reader at
the keyboard.

#### Scenario: Subagent has no ask_user tool

- **WHEN** a subagent's tool set is assembled
- **THEN** the `ask_user` tool is absent from it, regardless of the clarifying-question setting

### Requirement: A clarifying question is recorded in the transcript

The system SHALL show the asked question in the conversation transcript and fold the reader's
answer (or a skip indication) into that same entry once given.

#### Scenario: Question and answer shown inline

- **WHEN** a clarifying question is asked and answered
- **THEN** the transcript shows the question while it is pending and the reader's answer (or that it
  was skipped) once resolved, inline within the turn
