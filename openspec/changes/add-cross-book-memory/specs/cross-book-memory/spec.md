## ADDED Requirements

### Requirement: Other books' memories are readable from the current book

The system SHALL expose the stored BookBuddy memories of the reader's other books to the memory
tool as a virtual subtree `/memories/library/<book>/`, readable with the same `view` command
(directory listings, file contents, line ranges) as the current book's memories.

#### Scenario: Series predecessor's memories are readable

- **WHEN** the reader opens book 2 of a series and book 1 has stored memories, and the agent
  views a file under `/memories/library/<book-1>/`
- **THEN** the tool returns that file's contents exactly as the book-1 store would render them

#### Scenario: Mounted books are discoverable from the root listing

- **WHEN** the agent views `/memories` and other books with stored memories exist in the reading
  history
- **THEN** the listing includes `library/` and its per-book entries alongside the current book's
  own files

#### Scenario: Books are identifiable, not just listed

- **WHEN** the agent views `/memories/library`
- **THEN** each mounted book is labeled with its title, authors, and series name/index when
  known, sufficient to distinguish a series predecessor from a sequel

#### Scenario: The current book is never mounted

- **WHEN** mounts are discovered from the reading history
- **THEN** the current book's own memory directory is excluded from `/memories/library`

### Requirement: The library subtree is read-only

The system SHALL refuse every mutating memory command (`create`, `str_replace`, `insert`,
`delete`, `rename` with either endpoint) targeting `/memories/library` or any path beneath it,
and SHALL never modify another book's sidecar through any memory code path.

#### Scenario: Writes into a mount are refused

- **WHEN** the agent issues any mutating command against a `/memories/library/...` path
- **THEN** the command fails with an error naming the subtree as read-only, and the mounted
  book's memory directory is unchanged

#### Scenario: The library name is reserved

- **WHEN** the agent tries to `create` or `rename` a file at or under `/memories/library` while
  no such mounted path exists
- **THEN** the command is refused rather than creating a real directory that would collide with
  the virtual subtree

#### Scenario: Path escapes are refused inside mounts

- **WHEN** a `/memories/library/...` path contains `..` or otherwise escapes the mounted
  directory
- **THEN** resolution fails with the same guarantees as the current book's root

#### Scenario: Clearing memory never touches other books

- **WHEN** the reader clears the current book's memory from the management UI
- **THEN** only the current book's memory directory is purged; mounted books' memories are
  untouched

### Requirement: Cross-book memory is gated and inert when off

The system SHALL expose the library subtree only when both the memory feature and a new
cross-book setting are enabled; otherwise the memory store, its listings, and the tool
description SHALL be identical to the per-book behavior.

#### Scenario: Setting off restores per-book isolation

- **WHEN** `enable_cross_book_memory` is disabled and the agent views `/memories`
- **THEN** no `library/` entries appear and the tool description does not mention the subtree

#### Scenario: No qualifying books behaves like today

- **WHEN** the setting is on but no other book in the reading history has stored memories
- **THEN** listings and commands behave as the per-book store does today, and viewing
  `/memories/library` reports an empty or absent path rather than an error state
