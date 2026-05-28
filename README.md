# BookBuddy

A [KOReader](https://github.com/koreader/koreader) plugin that lets you chat with
Claude about whatever you're reading. Highlight a passage, ask a question, and the
model answers using tools that read the actual book rather than guessing.

> ## Warning: this project was entirely vibecoded by Claude Opus
>
> Every line in this repository — the plugin, the self-updater, even this very
> sentence disclaiming itself — was written by Claude Opus, prompt by prompt, with
> minimal human review. It was not designed up front, audited line by line, or
> tested across the devices KOReader actually runs on. Treat it accordingly:
>
> - It **handles your API key** and sends your highlighted text (and book context)
>   to a third-party gateway. Read `bbanthropic.lua` and `bbsettings.lua` before you
>   trust it with a key you care about.
> - The self-update feature **downloads code from the internet and overwrites its
>   own files**, then restarts KOReader. That is exactly as load-bearing as it sounds.
> - There is **no warranty**, expressed, implied, or hallucinated. If it bricks your
>   reading session, you got to watch an AI confidently write the bug.
>
> If that doesn't bother you, read on. If it does, also read on, but more slowly.

## What it does

- Adds an **"Ask BookBuddy"** button to KOReader's text-highlight menu (and an
  "Ask BookBuddy about selection" action you can bind to a gesture or shortcut).
- Streams Claude's reply into a chat view while it works.
- Gives the model tools so its answers are grounded in the real text:
  - `search_book` — full-text search within the book
  - `read_page_range` / `read_chapter` — read specific pages or a chapter
  - `get_toc` — inspect the table of contents
  - `book_context` — book metadata and the reader's current position
  - `get_highlights` — the reader's own highlights and notes
  - `navigate` — move the reader to a page, percent, or chapter (your spot is saved
    first, so Back returns you)
  - `web_search` — for outside facts only; it's told not to spoil what lies ahead
- Optional **per-book memory**, stored in the book's `.sdr` sidecar so notes travel
  with the book.
- Optional **extended (adaptive) thinking**, with a summarized view shown above the reply.

## Requirements

- KOReader (recent enough to have `Device:unpackArchive` and the modern `NetworkMgr`).
- Access to a Claude model through an Anthropic-compatible gateway. The defaults
  target a [Portkey](https://portkey.ai) gateway (`https://api.portkey.ai`, endpoint
  `/v1/messages`) with the model slug `@vertex-eu-global/anthropic.claude-opus-4-7`,
  authenticated with a Portkey API key sent as the `x-portkey-api-key` header. Point
  the base URL / model elsewhere if your setup differs.

## Installation

The repository root **is** the plugin, so clone it directly into KOReader's
`plugins/` directory under the name `bookbuddy.koplugin`:

```bash
git clone https://github.com/markus1189/bookbuddy.koplugin \
  /path/to/koreader/plugins/bookbuddy.koplugin
```

Then restart KOReader. (Or download the repo zip and extract it as
`plugins/bookbuddy.koplugin`.)

## Configuration

Open any book, then go to the top menu → **BookBuddy**:

- **Portkey API key** — required; sent as `x-portkey-api-key`.
- **Base URL** — gateway root; the Messages endpoint is `<base URL>/v1/messages`.
- **Model** — gateway model slug.
- **Max tokens** — cap on each reply.
- **Max tool rounds** — how many tool-using exchanges before a final answer.
- **System prompt** — editable; resettable to the shipped default.
- **Per-book memory** / **Extended thinking** — toggles.

Settings persist via KOReader's `LuaSettings` (in `bookbuddy.lua` under your settings
directory).

## Usage

1. Long-press to select a passage.
2. Tap **Ask BookBuddy** in the highlight menu.
3. Type a question (or leave it blank for a general explanation) and tap **Ask**.

The reply streams in; you can Stop it or ask a follow-up. You can also bind
"Ask BookBuddy about selection" to a gesture/shortcut for the current selection.

## Self-update

Menu → BookBuddy → **Check for updates**. It reads the `version` in `_meta.lua` on
this repo's `main` branch, and if it's newer than the installed version, downloads
that branch's zip, unpacks it over the plugin folder, and offers to restart KOReader.

This only works while the repo is **public** (the check and download are unauthenticated).
There is no rollback — if an update breaks something, reinstall an older commit by hand.
