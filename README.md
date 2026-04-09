# bookwyrm.koplugin

A read-only [BookWyrm](https://joinbookwyrm.com/) plugin for [KOReader](https://koreader.rocks/). View your BookWyrm shelves on your e-reader, match your to-read list against books on your device, and open matched books directly.

Uses BookWyrm's ActivityPub endpoints — no API key or authentication required (public shelves only).

**Primary repo**: [Codeberg](https://codeberg.org/BenDoubleU/bookwyrm.koplugin)
| **Mirror**: [GitHub](https://github.com/benwoody/bookwyrm.koplugin)

Issues, feature requests, and discussion belong on [Codeberg](https://codeberg.org/BenDoubleU/bookwyrm.koplugin/issues). Pull requests are welcome on either platform.

## Install

### From a release (recommended)

1. Download `bookwyrm.koplugin.zip` from the [latest release](https://codeberg.org/BenDoubleU/bookwyrm.koplugin/releases) (not the source archive).
2. Extract the zip. You should have a `bookwyrm.koplugin/` folder.
3. Copy it to your KOReader plugins directory:
   - **Kindle**: `/mnt/us/koreader/plugins/`
   - **Kobo**: `/mnt/onboard/.adds/koreader/plugins/`
   - **PocketBook**: `/applications/koreader/plugins/`
   - **Android**: Depends on your install — typically `koreader/plugins/` on internal storage
4. Restart KOReader.

### From source

```sh
git clone https://codeberg.org/BenDoubleU/bookwyrm.koplugin.git
cp -r bookwyrm.koplugin /path/to/koreader/plugins/
```

Only the `.lua` files are needed on the device — `spec/`, `Makefile`, etc. can be left behind.

## Setup

Open the top menu → **Tools** → **BookWyrm** → **Settings**. Enter your BookWyrm instance URL (e.g. `https://bookwyrm.social`) and your username.

## Features

### View shelves

Fetches your Currently Reading, To Read, Read, and Stopped Reading shelves via ActivityPub. Shows book titles with author names (resolved from BookWyrm's author endpoints). Drill into any shelf to see all books.

Books found on your local device are marked with a **▸** prefix — tap to see info and open the book directly.

### Reading queue

The main feature. Merges your BookWyrm currently-reading and to-read shelves with what's actually on your device:

- **On this Kindle** — Books matched by ISBN or title, with reading progress and time spent. Tap to open the book directly.
- **Not on this Kindle** — The rest of your queue. Tap for book details.

### Book matching

Books are matched in priority order:

1. **ISBN** — from the epub's metadata (DocSettings sidecar)
2. **Exact title** — normalized (lowercased, non-alphanumeric stripped)
3. **Substring title** — handles series prefixes like `Walt Longmire Mysteries - 02 - Death Without Company`

Local books are discovered from CoverBrowser's cache and ReadHistory, with reading stats pulled from the statistics database.

### Author caching

Author names require individual HTTP requests to BookWyrm. They're cached to disk (`koreader/settings/bookwyrm_authors.json`) so first load is slow but subsequent loads are near-instant. Safe to delete the cache file to force a refresh.

## File structure

```
bookwyrm.koplugin/
├── _meta.lua            # Plugin name and description
├── main.lua             # Menu, UI, and navigation
├── bookwyrmclient.lua   # HTTP client for BookWyrm ActivityPub endpoints
├── localbooks.lua       # Local book scanning, ISBN extraction, title matching
├── spec/                # Tests (busted)
│   ├── stub.lua         # KOReader module stubs for standalone testing
│   ├── localbooks_spec.lua
│   └── bookwyrmclient_spec.lua
└── Makefile             # test and release targets
```

## Development

### Running tests

```sh
luarocks install busted
make test
```

### Building a release zip

```sh
make release
```

This creates `bookwyrm.koplugin.zip` containing only the runtime `.lua` files.

## Known limitations

- **Read-only** — no way to update reading status on BookWyrm. BookWyrm lacks an authenticated API; see [bookwyrm-social/bookwyrm#785](https://github.com/bookwyrm-social/bookwyrm/issues/785).
- ISBN matching depends on your epub files having ISBNs in their metadata. Calibre often uses UUIDs instead, so the plugin falls back to title matching.
- Author resolution adds one HTTP request per unique author — can be slow on large shelves over weak Wi-Fi.
- Only public shelf data is accessible via ActivityPub.

## Requirements

- KOReader (tested on 2026.03)
- Wi-Fi connectivity for fetching BookWyrm data
- Public BookWyrm shelves

## Supported devices

Tested on:
- Kindle Paperwhite 7th gen (jailbroken, KOReader via KUAL)
- KOReader macOS emulator

Should work on any KOReader-supported device (Kobo, PocketBook, Android, etc.) — the plugin uses only standard KOReader APIs.

## License

MIT
