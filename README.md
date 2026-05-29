<p align="center">
  <img src="assets/bookbuddy-logo.png" alt="BookBuddy" width="480">
</p>

A [KOReader](https://github.com/koreader/koreader) plugin that puts a tool-using
Claude agent inside your e-reader. Highlight a passage, ask a question, and the
model doesn't answer from the snippet alone — it searches the full text, reads the
pages around your highlight, checks the table of contents, and pulls up your own
notes before it replies. The answer is grounded in what the book actually says.

It's a conversation, not a one-shot lookup: reply and it keeps the whole
thread in context. It can flip you to a relevant page (and back), keep per-book
notes that persist between sessions, and check the web for outside facts without
spoiling what lies ahead.

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

## What a conversation looks like

You watch the agent work. Each tool call shows up as its own line, with a short
summary of what came back, before the answer streams in:

```
You: Who is Septimus and why does he matter here?

  → Checked the book details — page 142 of 318
  → Searched book for "Septimus" — 11 match(es)
  → Read pages 88–95 — ~2400 words

BookBuddy: Septimus is the shell-shocked veteran whose day runs in parallel to
Clarissa's. He matters here because the novel keeps cutting between them to set
his unraveling against her party-planning… (plain prose, nothing past page 142)

[tokens — input 9120, output 274, cached 7680]
```

## What it does

Every question starts a multi-turn loop: Claude requests a tool, BookBuddy runs it
against the live document, hands back the result, and Claude decides what to do
next — search, read more, navigate, or answer. Nothing is hidden; you see each step.

- Adds a **"Chat with BookBuddy"** button to KOReader's text-highlight menu (and a
  "Chat with BookBuddy about selection" action you can bind to a gesture or shortcut).
- **Streams the reply live** into a chat view, coalesced so it stays readable on
  e-ink, with each tool call shown as a line you can follow.
- **Quick-action presets** in the chat prompts: one tap fills the input box with a
  starter like *Overview* / *Characters* / *Themes* for a book, *Explain* / *Why it
  matters* / *Simpler* for a highlighted passage, or *Yes* / *Go on* / *Example* when
  replying. They prefill rather than send, so you can tweak the wording before tapping
  **Send** — handy for sidestepping the on-screen keyboard.
- **Grounds answers in the real text** with tools that read the book instead of
  guessing:
  - `search_book` — full-text search within the book
  - `read_page_range` / `read_chapter` — read specific pages or a chapter
  - `get_toc` — inspect the table of contents
  - `book_context` — book metadata and the reader's current position
  - `get_highlights` — the reader's own highlights and notes
  - `edit_highlight_note` — add a note to one of your highlights; it appends to any
    existing note and never overwrites or deletes what you wrote
  - `create_highlight` — mark a passage in the book (reflowable/EPUB only), by a
    recent `search_book` match or a verbatim snippet, optionally with a note and color
  - `navigate` — move the reader to a page, percent, or chapter (your spot is saved
    first, so Back returns you)
  - `web_search` — for outside facts only; it's told not to spoil what lies ahead
- **Per-book memory** (optional): notes Claude saves live in the book's `.sdr`
  sidecar, so they travel with the book, stay isolated to it, and are still there
  next session — ask it to remember who a character is and it won't forget.
- **Extended (adaptive) thinking** (optional): a `Thinking...` indicator shows
  while the model reasons before it replies.
- **Spoiler-aware throughout** — it avoids revealing anything past your current
  position unless you explicitly ask.
- A **token-usage footer** tracks what each conversation cost.

## Requirements

- KOReader (recent enough to have `Device:unpackArchive` and the modern `NetworkMgr`).
- Access to a Claude model through an Anthropic-compatible gateway. The defaults
  target a [Portkey](https://portkey.ai) gateway (`https://api.portkey.ai`, endpoint
  `/v1/messages`) with the model slug `@vertex-eu-global/anthropic.claude-opus-4-8`,
  authenticated with a Portkey API key sent as the `x-portkey-api-key` header. Point
  the base URL / model elsewhere if your setup differs.

## Installation (first time)

BookBuddy is a KOReader plugin: a folder named exactly **`bookbuddy.koplugin`** placed
inside KOReader's `plugins/` directory. You only do this once — afterwards the built-in
"Check for updates" handles upgrades.

### The easy way (no git required)

1. **Download the zip.** Open the
   [repository](https://github.com/markus1189/bookbuddy.koplugin), click the green
   **Code** button, then **Download ZIP**. You'll get `bookbuddy.koplugin-main.zip`.

2. **Extract it.** This gives you a folder named `bookbuddy.koplugin-main`.

3. **Rename that folder to exactly `bookbuddy.koplugin`** — drop the `-main`. This step is
   not optional: KOReader only loads folders whose name ends in `.koplugin`, so
   `bookbuddy.koplugin-main` would be silently ignored.

4. **Copy the `bookbuddy.koplugin` folder into KOReader's `plugins/` directory.** Typical
   locations:
   - Kobo: `.adds/koreader/plugins/`
   - Kindle: `koreader/plugins/` (under `/mnt/us/`)
   - Android: `koreader/plugins/` in the app's storage (use a file manager)
   - Desktop / emulator: `<koreader install>/plugins/`

5. **Restart KOReader.**

6. Open a book → top menu → **BookBuddy** → set your Portkey API key (see
   [Configuration](#configuration)). You're ready to highlight a passage and ask.

### Or, if you use git

```bash
git clone https://github.com/markus1189/bookbuddy.koplugin bookbuddy.koplugin
```

The target folder already ends in `.koplugin`, so there's no rename to do. Copy it into
`plugins/` (step 4 above) and restart.

## Configuration

Open any book, then go to the top menu → **BookBuddy**:

- **Portkey API key** — required; sent as `x-portkey-api-key`.
- **Base URL** — gateway root; the Messages endpoint is `<base URL>/v1/messages`.
- **Model** — gateway model slug.
- **Max tokens** — cap on each reply.
- **Max tool rounds** — how many tool-using exchanges before a final answer.
- **Additional system prompt** — optional text appended to BookBuddy's built-in
  system prompt; add your own preferences (tone, language, focus) without restating
  the built-in instructions. Leave empty for the default behavior.
- **Per-book memory** / **Extended thinking** — toggles.

Settings persist via KOReader's `LuaSettings` (in `bookbuddy.lua` under your settings
directory).

## Usage

1. Long-press to select a passage.
2. Tap **Chat with BookBuddy** in the highlight menu.
3. Type a question or instruction — or tap a **quick-action preset** to fill one in,
   then edit if you like — and tap **Send**. (Leaving it blank sends a general explanation.)

The reply streams in; you can Stop it or reply to continue the conversation — a short
*Yes* or *Go on* is a perfectly good reply when the agent ends its turn with a question.
You can also start a chat about the whole book (no selection needed) from the menu's
**Chat about this book** entry, or bind "Chat with BookBuddy about selection" to a
gesture/shortcut for the current selection.

## Self-update

Menu → BookBuddy → **Check for updates**. It reads the `version` in `_meta.lua` on
this repo's `main` branch, and if it's newer than the installed version, downloads
that branch's zip, unpacks it over the plugin folder, and offers to restart KOReader.

This only works while the repo is **public** (the check and download are unauthenticated).
There is no rollback — if an update breaks something, reinstall an older commit by hand.
