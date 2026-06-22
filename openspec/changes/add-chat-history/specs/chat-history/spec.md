## ADDED Requirements

### Requirement: Conversations persist to the per-book sidecar

The system SHALL store conversations under the open book's sidecar directory at
`<sidecar>/bookbuddy_chats/`, so that chats survive viewer-close, book-close, and KOReader
restart and travel with the book like per-book memory. When the book has no resolvable
sidecar directory, the system SHALL skip persistence entirely without raising an error.

#### Scenario: Sidecar available

- **WHEN** a conversation reaches a clean save boundary and the open book has a resolvable
  sidecar directory
- **THEN** the system writes the chat under `<sidecar>/bookbuddy_chats/`

#### Scenario: No sidecar

- **WHEN** a conversation reaches a save boundary but the book has no resolvable sidecar
  directory
- **THEN** the system skips persistence and the conversation continues normally without error

### Requirement: Chats save only at completed-turn boundaries

The system SHALL persist a conversation only when a turn fully completes (the terminal
render), so that a stored chat always ends on a finished assistant answer and never on a
dangling, mid-tool-round state. The system SHALL NOT persist a conversation that never
reaches a completed turn.

#### Scenario: Completed turn is saved

- **WHEN** a conversation finishes a turn and renders a final answer
- **THEN** the system saves the chat with history ending on that assistant answer

#### Scenario: Turn-one failure is not saved

- **WHEN** a conversation fails on its first turn before any answer is rendered
- **THEN** no chat payload is written for it and it does not appear in the history list

### Requirement: Stored chats round-trip losslessly for resend

The system SHALL serialize and deserialize a conversation's wire history such that the
restored `messages` are valid to resend to the gateway. In particular, the system SHALL
preserve thinking-block `signature` fields intact and SHALL serialize an empty content list
as a JSON array (`[]`), not a JSON object (`{}`).

#### Scenario: Thinking signature survives round-trip

- **WHEN** a chat containing an assistant thinking block is saved and then loaded
- **THEN** the loaded thinking block retains its original `signature` value unchanged

#### Scenario: Empty content list stays an array

- **WHEN** a chat containing a message whose content is an empty list is saved and loaded
- **THEN** the loaded message's content deserializes as an empty array, not an object, and is
  valid to resend

### Requirement: Both wire history and display transcript are persisted

The system SHALL persist both the wire `messages` and the human-readable `transcript` for
each chat, because client-tool display lines and their outcome summaries exist only on the
transcript and cannot be reconstructed from `messages`. The system SHALL exclude derived
display caches (e.g. the markdown-strip memo) from the stored payload.

#### Scenario: Tool summary survives reopen

- **WHEN** a chat whose transcript includes a client-tool line with an outcome summary is
  saved and reopened
- **THEN** the reopened transcript shows that tool line with its summary intact

#### Scenario: Derived caches are not stored

- **WHEN** a chat is saved
- **THEN** transient per-entry display caches are absent from the stored payload

### Requirement: A stored chat can be reopened and continued

The system SHALL reconstruct a `Conversation` from a stored chat's payload, render it in
reply mode, and allow the reader to send a follow-up that resends the restored wire history.
A follow-up after reopening SHALL follow the same turn path as an in-session reply.

#### Scenario: Reopen shows the finished chat

- **WHEN** the reader opens a stored chat from the history list
- **THEN** the conversation's transcript is shown in reply mode with its prior turns

#### Scenario: Follow-up continues the restored chat

- **WHEN** the reader sends a follow-up in a reopened chat
- **THEN** the system resends the restored wire history plus the new question and renders the
  reply, and saves the updated chat under the same id

### Requirement: Past chats are browsable per book

The system SHALL present a "Chat history" entry under the BookBuddy main menu listing the
open book's stored chats. Each row SHALL show a human title derived from the chat's first
question and a relative timestamp. The list SHALL read only lightweight chat metadata, not
full payloads. The system SHALL let the reader reopen a chat by selecting it, delete a single
chat (with confirmation), and clear all chats for the book (with confirmation).

#### Scenario: List shows stored chats

- **WHEN** the reader opens "Chat history" for a book that has stored chats
- **THEN** each stored chat appears as a row with its derived title and relative time

#### Scenario: Empty history

- **WHEN** the reader opens "Chat history" for a book with no stored chats
- **THEN** the list indicates there are no saved chats

#### Scenario: Delete one chat

- **WHEN** the reader long-presses a chat row and confirms deletion
- **THEN** that chat's payload and its list entry are removed and remaining chats are unaffected

#### Scenario: Clear all chats

- **WHEN** the reader selects "Clear all chats" and confirms
- **THEN** all stored chats for the book are removed

### Requirement: Stored chats are bounded per book

The system SHALL cap the number of stored chats per book at a configurable limit (default
20). When saving a chat would exceed the limit, the system SHALL delete the oldest chats
(by last-updated time) until the count is within the limit, and SHALL never evict the chat
just saved.

#### Scenario: Oldest chat dropped past the cap

- **WHEN** saving a new chat would push the stored count above the configured limit
- **THEN** the oldest chats are deleted until the count is at the limit

#### Scenario: Limit is configurable

- **WHEN** the reader changes the maximum-saved-chats setting
- **THEN** subsequent saves enforce the new limit

#### Scenario: Just-saved chat is never evicted

- **WHEN** pruning runs immediately after a save
- **THEN** the chat that was just saved remains stored
