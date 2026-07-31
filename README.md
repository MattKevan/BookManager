# Book Manager

Book Manager is a native macOS ebook-library manager. The current foundation can create and open portable libraries, persist metadata as immutable Automerge changes, rebuild a local GRDB catalogue, and display indexed books.

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
