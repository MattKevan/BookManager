# Book Manager

Book Manager is a native macOS ebook-library manager. It creates and opens portable libraries, persists metadata as immutable Automerge changes, rebuilds a local GRDB catalogue, imports EPUB/PDF/DJVU files with embedded metadata, browses with facets and a cover grid, opens books externally, and moves books to/from trash.

## Requirements

- macOS 26 or later
- Xcode 27 or later
- XcodeGen

## Build and run

```bash
./script/build_and_run.sh
```

Run all tests:

```bash
xcodebuild -project BookManager.xcodeproj -scheme BookManager -destination 'platform=macOS' test
```

## Storage rule

The portable library's `.bookmanager/changes` directory is authoritative. SQLite files under Application Support are disposable indexes and must never be placed in a synchronized library.

## Slices

1. **Library foundation** — implemented
2. **Management workflows** — implemented (this slice: import, metadata editing, search and facets, cover grid, external open, trash/restore, diagnostics)
3. **Calibre migration** — not started
4. **Multi-Mac hardening** — not started
