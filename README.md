# Book Manager

Book Manager is a native macOS ebook-library manager. It creates and opens portable libraries, persists metadata as immutable Automerge changes, rebuilds a local GRDB catalogue, imports EPUB/PDF/DJVU files with embedded metadata, imports a copy of an existing Calibre library read-only, browses with facets and a cover grid, opens books externally, and moves books to/from trash.

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
3. **Calibre migration** — implemented (this slice: import a copy of a Calibre library read-only, map full metadata, preserve custom columns and unsupported values, resumable import, report)
4. **Multi-Mac hardening** — not started
5. **Device support** — implemented (Kindle Paperwhite MTP over a native IOUSBHost backend — MTPKit vendored in `BookManagerCore/Vendored/MTPKit`; Finder-style sidebar device, ~1s browsing with a Calibre-compatible `metadata.calibre` device cache and DRM badges, import DRM-free books through the existing pipeline, send native formats with a `FormatConverter` seam for full conversion, serial activity queue with toolbar progress popover, system notifications for import/send completion)

Note: the app is intentionally **not sandboxed** — USB device access (MTP e-readers) failed under App Sandbox even with the `device.usb` entitlement, so it ships unsandboxed (like Calibre) and is therefore not Mac App Store–distributable; direct distribution with Developer ID notarization works.
