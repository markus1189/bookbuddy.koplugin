# subagent-delegation Specification

## Purpose

Let the main BookBuddy agent delegate a focused sub-task to a bounded, read-only subagent
whose intermediate work stays out of the parent conversation, while preserving the reader's
spoiler boundary and the parent's search/locator state.

## Requirements

### Requirement: The agent can delegate a sub-task to a subagent

The system SHALL expose a `delegate` tool to the main agent that accepts a focused
natural-language task, runs a child agent loop to completion, and returns a single condensed
text result as the tool's output. The main agent SHALL be able to use that result to compose
its answer like any other tool result.

#### Scenario: Delegated task returns a condensed result

- **WHEN** the main agent calls the `delegate` tool with a task
- **THEN** a child agent loop runs to completion and the tool result is a single condensed
  text string the main agent can use in its reply

#### Scenario: Delegation is gated by a setting

- **WHEN** the subagents feature is disabled in settings
- **THEN** the `delegate` tool is not advertised to the model and no delegation can occur

### Requirement: Subagents run a bounded read-only tool loop

A subagent SHALL be able to call the book-reading tools `grep`, `read`, `get_toc`,
`book_context`, and `get_highlights` across multiple rounds, up to a bounded maximum number of
turns. A subagent SHALL NOT be able to call any tool outside that read-only set.

#### Scenario: Subagent reads across multiple rounds

- **WHEN** a subagent needs more than one search or read to complete its task
- **THEN** it may issue successive read-tool calls until it has enough to answer or it reaches
  its turn limit

#### Scenario: Mutating and external tools are withheld

- **WHEN** a subagent's tool set is assembled
- **THEN** it excludes the view/annotation-mutating tools (`navigate`, `create_highlight`,
  `edit_highlight_note`) and the web-search tool, so a subagent can neither change the
  reader's view or annotations nor reach the open internet

#### Scenario: Turn limit terminates the loop

- **WHEN** a subagent reaches its maximum number of turns without finishing
- **THEN** the loop stops and returns the best condensed result produced so far

### Requirement: Subagents cannot spawn further subagents

The system SHALL prevent recursive delegation: a subagent SHALL NOT have access to the
`delegate` tool, and a depth bound SHALL stop any delegation beyond the first level even if
the tool were reachable.

#### Scenario: Subagent has no delegate tool

- **WHEN** a subagent's tool set is assembled
- **THEN** the `delegate` tool is absent from it

#### Scenario: Depth bound halts recursion

- **WHEN** a delegation is attempted beyond the allowed depth
- **THEN** it is refused and no further child loop is started

### Requirement: Subagent work stays out of the parent's resent history

The system SHALL keep a subagent's intermediate tool calls and tool results in the subagent's
own message history, separate from the main conversation. Only the subagent's condensed
result SHALL enter the main conversation's wire history.

#### Scenario: Intermediate churn does not enter the parent

- **WHEN** a subagent issues several read-tool rounds to answer its task
- **THEN** those intermediate calls and results do not appear in the main conversation's
  resent message history; only the condensed result does

### Requirement: The spoiler boundary is enforced across delegation

The system SHALL enforce the reader's current-position spoiler boundary on a subagent's reads
by default, deriving the boundary from the live reading position rather than from a copied
value. The `delegate` tool SHALL accept an explicit spoiler-crossing flag that defaults to
disallowing crossing; the main agent SHALL set it to allow crossing only when the reader has
explicitly asked to read ahead.

#### Scenario: Default delegation cannot read ahead

- **WHEN** a subagent runs without explicit spoiler permission
- **THEN** its read-tool inputs are constrained to the reader's current position, so it cannot
  surface content past where the reader is

#### Scenario: Explicit permission allows crossing

- **WHEN** the reader has explicitly asked to read ahead and the main agent delegates with the
  spoiler-crossing flag enabled
- **THEN** the subagent may read past the current position for that delegation

#### Scenario: Boundary tracks the live position

- **WHEN** the reading position is read during a delegated task
- **THEN** the boundary used is the live current position, not a value frozen at delegation
  start

### Requirement: Subagent execution is sequential and cancellable

Subagents SHALL run sequentially on the conversation's existing coroutine, with the main agent
paused at the delegating tool step until the subagent returns. A reader Stop SHALL abort an
in-progress subagent and unwind back to the main conversation.

#### Scenario: Parent waits for the subagent

- **WHEN** a delegation is in progress
- **THEN** the main agent does not advance past the delegating tool step until the subagent
  returns its result

#### Scenario: Stop aborts a running subagent

- **WHEN** the reader presses Stop while a subagent is running
- **THEN** the subagent is aborted and control returns to the main conversation without a
  partial subagent answer being treated as complete

#### Scenario: Subagent failure is recoverable

- **WHEN** a subagent errors or is stopped before producing a result
- **THEN** the delegating tool yields an error result the main agent can recover from, rather
  than crashing the conversation

### Requirement: Parent search and locator state survive a delegation

The system SHALL preserve the main conversation's last-search and locator state across a
delegation, so that a subagent's reads do not silently re-point a subsequent main-agent action
that depends on the most recent search result.

#### Scenario: Last-search is restored after delegation

- **WHEN** a subagent performs a search during its task and then returns
- **THEN** the main conversation's last-search state is the same as before the delegation, so a
  later main-agent action referencing the latest search result still refers to the parent's
  own search

### Requirement: Subagents run headless with an attributed status line

A subagent SHALL run without its own viewer and without token-by-token streaming into the
transcript. The system SHALL surface a single attributed status line for the delegated task
while it runs, replaced by a brief summary when it returns.

#### Scenario: Status line shown during delegation

- **WHEN** a subagent is running
- **THEN** a single status line naming the delegated task is shown, and no per-token subagent
  output is streamed into the transcript

#### Scenario: Status line resolves on return

- **WHEN** a subagent returns its result
- **THEN** the status line is replaced by a brief completion summary
</content>
</invoke>
