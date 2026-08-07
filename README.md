# Stacks

Stacks is a native macOS ebook-library manager with a headless server, all in
one Swift codebase. A library is a portable folder owned by a single writer
(the server); the macOS app opens one library per instance, imports and edits
books, and connects to libraries shared over the local network — including
the same app's Sharing pane and headless servers on Linux.

- Portable libraries: an append-only operation journal (`.bookmanager/…`)
  plus periodic atomic snapshots — no merge logic, crash-safe, idempotent by
  command id
- Local browsing: search and facets (author/series/tag/format), cover grid
  and table, metadata editor, trash/restore, external open, diagnostics
- Import: EPUB/PDF/DJVU with embedded metadata, plus a resumable Calibre
  migration wizard (copies a Calibre library read-only, full metadata)
- Metadata enrichment: auto-fetch missing authors/tags from online sources
- Device support: Kindle Paperwhite over native MTP (unsandboxed — USB device
  access fails under App Sandbox, so the app is Developer-ID signed, not
  Mac App Store–distributable)
- Sharing: in-app server (Settings → Sharing) advertising `_stacks._tcp`
  over Bonjour; optional username/password (Keychain)
- Remote browsing: the Shared sidebar discovers servers on the LAN (Bonjour,
  or Avahi on Linux) and also connects by typed host:port; offline edits
  queue durably and flush on reconnect
- Headless server: `stacks` CLI (`create`, `import-calibre`, `serve`,
  `status`) — sync protocol + OPDS 1.2 over HTTP, single writer per library

## Architecture

A library is a folder with a `.bookmanager` control directory: an
append-only JSON-lines operation journal, periodic snapshots, and staging for
incoming files. Clients never merge — the server appends commands in order
and clients pull records after a cursor, applying them through
`CommandReplay`. One server per library is the only writer; a recreated or
second writer is a hard break (format version 2, no migration from the old
format). SQLite catalogs are disposable indexes, never part of the portable
format.

- `StacksCore/Journal` — journal, snapshots, `CommandReplay` (single source
  of truth for command → state)
- `StacksCore/Server` — `LibraryServer` (Hummingbird), `RemoteLibrary`
  client, offline queue, Bonjour/Avahi advertisers, OPDS feeds
- `Stacks` — the macOS app (XcodeGen project from `project.yml`)
- `StacksServer` — the `stacks` CLI

## Requirements

- macOS 26+ with Xcode (Swift 6 toolchain) and
  [XcodeGen](https://github.com/yonaskolb/XcodeGen) for the app
- Swift 6.x from [swift.org](https://www.swift.org/install/linux/) for the
  Linux server (see [LINUX_SERVER.md](LINUX_SERVER.md))

## Build and run — macOS app

```bash
xcodegen generate          # regenerates Stacks.xcodeproj from project.yml
open Stacks.xcodeproj      # or build from the command line:
xcodebuild -project Stacks.xcodeproj -scheme Stacks -destination 'platform=macOS' build
```

> If a fresh checkout hits "Multiple commands produce …" conflicts, delete
> the root `Package.resolved` and `.build` before `xcodegen generate`
> (xcodegen materializes the resolved package graph into the project).

## Build and run — headless server

```bash
swift build -c release
.build/release/stacks create /srv/stacks/library
.build/release/stacks serve /srv/stacks/library
```

`import-calibre` creates a library from an existing Calibre library. Full
Linux setup (toolchain, Avahi, systemd, auth, firewall), usage, and
troubleshooting: **[LINUX_SERVER.md](LINUX_SERVER.md)**.

## Tests

```bash
swift test                  # headless server subset (real-socket protocol tests)
xcodebuild -project Stacks.xcodeproj -scheme Stacks -destination 'platform=macOS' \
  -only-testing:StacksTests -only-testing:StacksCoreTests test
```
