# Book Manager Library Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a runnable macOS 26 SwiftUI app that creates and reopens portable Book Manager libraries, stores metadata as immutable Automerge changes, rebuilds a local GRDB catalogue, and displays indexed books in a native table.

**Architecture:** XcodeGen creates a reproducible Xcode project with separate `BookManager` and `BookManagerCore` targets. Each book is an Automerge document whose encoded incremental changes are the portable source of truth; a local GRDB database materializes summaries and caches document snapshots. App-scoped security bookmarks retain access to selected library folders.

**Tech Stack:** macOS 26+, Swift 6 strict concurrency, SwiftUI, Observation, Automerge Swift 0.7.2, GRDB.swift 7.11.1, Swift Testing, XCTest UI testing, XcodeGen.

---

## Scope

This plan implements delivery slice 1 from the approved design. It deliberately does not implement file import, Calibre import, cover handling, metadata editing UI, folder renames, trash, network-drive recovery, or production multi-Mac monitoring. Stable `device.json` clock persistence, the `libraries.json` recent-library registry, and the durable outbox remain part of Slice 4; this foundation uses a unique process actor and persists the selected folder bookmark immediately. It proves the storage architecture those later slices depend on.

## File Map

```text
project.yml
Config/BookManager.entitlements
BookManager/
├── App/BookManagerApp.swift
├── Stores/LibrarySession.swift
└── Views/
    ├── ContentView.swift
    ├── LibraryWelcomeView.swift
    └── BookTableView.swift
BookManagerCore/
├── CRDT/
│   ├── HybridLogicalClock.swift
│   ├── BookDocumentSchema.swift
│   └── AutomergeBookDocument.swift
├── Library/
│   ├── LibraryManifest.swift
│   ├── LibraryLayout.swift
│   ├── CanonicalPathBuilder.swift
│   ├── ChangeStore.swift
│   └── LibraryRepository.swift
├── Persistence/
│   ├── IndexedBook.swift
│   └── LocalCatalog.swift
└── Security/
    └── LibraryBookmarkStore.swift
BookManagerCoreTests/
├── CRDT/
├── Library/
├── Persistence/
└── Security/
BookManagerUITests/BookManagerUITests.swift
script/build_and_run.sh
.codex/environments/environment.toml
.gitignore
```

`BookManagerCore` contains no SwiftUI. The app target owns presentation state and system panels. `LocalCatalog` is rebuildable; the portable library never depends on its SQLite file.

### Task 1: Reproducible macOS Project Scaffold

**Files:**

- Create: `project.yml`
- Create: `Config/BookManager.entitlements`
- Create: `BookManager/App/BookManagerApp.swift`
- Create: `BookManager/Views/ContentView.swift`
- Create: `BookManagerCore/BookManagerCore.swift`
- Create: `BookManagerCoreTests/ScaffoldTests.swift`
- Create: `BookManagerUITests/BookManagerUITests.swift`
- Create: `script/build_and_run.sh`
- Create: `.codex/environments/environment.toml`
- Create: `.gitignore`
- Generate: `BookManager.xcodeproj`

- [ ] **Step 1: Add the XcodeGen project specification**

Create `project.yml`:

```yaml
name: BookManager
options:
  bundleIdPrefix: com.mattkevan
  deploymentTarget:
    macOS: "26.0"
  createIntermediateGroups: true

configs:
  Debug: debug
  Release: release

packages:
  Automerge:
    url: https://github.com/automerge/automerge-swift.git
    exactVersion: 0.7.2
  GRDB:
    url: https://github.com/groue/GRDB.swift.git
    exactVersion: 7.11.1

settings:
  base:
    SWIFT_VERSION: "6.0"
    SWIFT_STRICT_CONCURRENCY: complete
    MACOSX_DEPLOYMENT_TARGET: "26.0"

targets:
  BookManagerCore:
    type: framework
    platform: macOS
    sources:
      - BookManagerCore
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.mattkevan.BookManagerCore
        GENERATE_INFOPLIST_FILE: YES
    dependencies:
      - package: Automerge
      - package: GRDB

  BookManager:
    type: application
    platform: macOS
    sources:
      - BookManager
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.mattkevan.BookManager
        PRODUCT_NAME: BookManager
        GENERATE_INFOPLIST_FILE: YES
        CODE_SIGN_ENTITLEMENTS: Config/BookManager.entitlements
        CODE_SIGN_STYLE: Automatic
        INFOPLIST_KEY_CFBundleDisplayName: Book Manager
        INFOPLIST_KEY_LSApplicationCategoryType: public.app-category.productivity
    dependencies:
      - target: BookManagerCore

  BookManagerCoreTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - BookManagerCoreTests
    settings:
      base:
        GENERATE_INFOPLIST_FILE: YES
    dependencies:
      - target: BookManagerCore

  BookManagerUITests:
    type: bundle.ui-testing
    platform: macOS
    sources:
      - BookManagerUITests
    settings:
      base:
        GENERATE_INFOPLIST_FILE: YES
    dependencies:
      - target: BookManager

schemes:
  BookManager:
    build:
      targets:
        BookManager: all
        BookManagerCore: all
        BookManagerCoreTests: [test]
        BookManagerUITests: [test]
    run:
      config: Debug
    test:
      config: Debug
      gatherCoverageData: true
      targets:
        - BookManagerCoreTests
        - BookManagerUITests
    profile:
      config: Release
    analyze:
      config: Debug
    archive:
      config: Release
```

- [ ] **Step 2: Add sandbox entitlements**

Create `Config/BookManager.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.files.user-selected.read-write</key>
    <true/>
    <key>com.apple.security.files.bookmarks.app-scope</key>
    <true/>
</dict>
</plist>
```

- [ ] **Step 3: Add the smallest compiling targets**

Create `BookManagerCore/BookManagerCore.swift`:

```swift
import Foundation

public enum BookManagerCoreVersion {
    public static let libraryFormat = 1
}
```

Create `BookManager/App/BookManagerApp.swift`:

```swift
import SwiftUI

@main
struct BookManagerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1_100, height: 720)
    }
}
```

Create `BookManager/Views/ContentView.swift`:

```swift
import SwiftUI

struct ContentView: View {
    var body: some View {
        Text("Book Manager")
            .frame(minWidth: 720, minHeight: 480)
    }
}
```

Create `BookManagerCoreTests/ScaffoldTests.swift`:

```swift
import Testing
@testable import BookManagerCore

@Test
func exposesLibraryFormatVersion() {
    #expect(BookManagerCoreVersion.libraryFormat == 1)
}
```

Create `BookManagerUITests/BookManagerUITests.swift`:

```swift
import XCTest

final class BookManagerUITests: XCTestCase {
    func testLaunchesMainWindow() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Book Manager"].waitForExistence(timeout: 5))
    }
}
```

- [ ] **Step 4: Add repository ignores**

Create `.gitignore`:

```gitignore
.DS_Store
.build/
DerivedData/
xcuserdata/
*.xcuserstate
```

- [ ] **Step 5: Generate the project and resolve packages**

Run:

```bash
xcodegen generate --spec project.yml
xcodebuild -resolvePackageDependencies -project BookManager.xcodeproj -scheme BookManager
```

Expected: `BookManager.xcodeproj` and `BookManager.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` exist; Automerge 0.7.2 and GRDB 7.11.1 resolve.

- [ ] **Step 6: Build and run the scaffold tests**

Run:

```bash
xcodebuild -project BookManager.xcodeproj -scheme BookManager -destination 'platform=macOS' test
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 7: Add the project-local build/run entrypoint**

Create `script/build_and_run.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="BookManager"
BUNDLE_ID="com.mattkevan.BookManager"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT_DIR/.build/DerivedData"
APP_BUNDLE="$DERIVED_DATA/Build/Products/Debug/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

xcodegen generate --spec "$ROOT_DIR/project.yml"
xcodebuild \
  -project "$ROOT_DIR/BookManager.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration Debug \
  -destination "platform=macOS" \
  -derivedDataPath "$DERIVED_DATA" \
  build

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
```

Run:

```bash
chmod +x script/build_and_run.sh
```

Create `.codex/environments/environment.toml`:

```toml
# THIS IS AUTOGENERATED. DO NOT EDIT MANUALLY
version = 1
name = "Book Manager"

[setup]
script = ""

[[actions]]
name = "Run"
icon = "run"
command = "./script/build_and_run.sh"
```

- [ ] **Step 8: Verify the build/run entrypoint**

Run:

```bash
./script/build_and_run.sh --verify
```

Expected: the build succeeds and `pgrep -x BookManager` returns success.

- [ ] **Step 9: Commit the scaffold**

```bash
git add .gitignore .codex Config BookManager BookManagerCore BookManagerCoreTests BookManagerUITests BookManager.xcodeproj project.yml script
git commit -m "build: scaffold Book Manager macOS app"
```

### Task 2: Hybrid Logical Clock

**Files:**

- Create: `BookManagerCore/CRDT/HybridLogicalClock.swift`
- Create: `BookManagerCoreTests/CRDT/HybridLogicalClockTests.swift`

- [ ] **Step 1: Write clock ordering and advancement tests**

Create `BookManagerCoreTests/CRDT/HybridLogicalClockTests.swift`:

```swift
import Foundation
import Testing
@testable import BookManagerCore

@Suite
struct HybridLogicalClockTests {
    private let nodeA = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let nodeB = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    @Test
    func tickAdvancesLogicalCounterWhenWallTimeDoesNotAdvance() {
        var state = HybridLogicalClock(physicalMilliseconds: 1_000, logical: 2, nodeID: nodeA)

        let next = state.tick(at: Date(timeIntervalSince1970: 1))

        #expect(next.physicalMilliseconds == 1_000)
        #expect(next.logical == 3)
        #expect(state == next)
    }

    @Test
    func tickUsesNewWallTimeAndResetsCounter() {
        var state = HybridLogicalClock(physicalMilliseconds: 1_000, logical: 4, nodeID: nodeA)

        let next = state.tick(at: Date(timeIntervalSince1970: 2))

        #expect(next.physicalMilliseconds == 2_000)
        #expect(next.logical == 0)
    }

    @Test
    func observingRemoteClockProducesValueAfterLocalAndRemote() {
        var local = HybridLogicalClock(physicalMilliseconds: 1_000, logical: 3, nodeID: nodeA)
        let remote = HybridLogicalClock(physicalMilliseconds: 2_000, logical: 7, nodeID: nodeB)

        let next = local.observe(remote, at: Date(timeIntervalSince1970: 1.5))

        #expect(next > remote)
        #expect(next.physicalMilliseconds == 2_000)
        #expect(next.logical == 8)
    }

    @Test
    func nodeIDBreaksOtherwiseEqualTies() {
        let first = HybridLogicalClock(physicalMilliseconds: 1_000, logical: 0, nodeID: nodeA)
        let second = HybridLogicalClock(physicalMilliseconds: 1_000, logical: 0, nodeID: nodeB)

        #expect(first < second)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:

```bash
xcodebuild -project BookManager.xcodeproj -scheme BookManager -destination 'platform=macOS' -only-testing:BookManagerCoreTests/HybridLogicalClockTests test
```

Expected: compilation fails because `HybridLogicalClock` is undefined.

- [ ] **Step 3: Implement the clock**

Create `BookManagerCore/CRDT/HybridLogicalClock.swift`:

```swift
import Foundation

public struct HybridLogicalClock: Codable, Hashable, Sendable, Comparable {
    public private(set) var physicalMilliseconds: Int64
    public private(set) var logical: UInt32
    public let nodeID: UUID

    public init(physicalMilliseconds: Int64 = 0, logical: UInt32 = 0, nodeID: UUID) {
        self.physicalMilliseconds = physicalMilliseconds
        self.logical = logical
        self.nodeID = nodeID
    }

    @discardableResult
    public mutating func tick(at date: Date = .now) -> Self {
        let now = Self.milliseconds(date)
        if now > physicalMilliseconds {
            physicalMilliseconds = now
            logical = 0
        } else {
            logical &+= 1
        }
        return self
    }

    @discardableResult
    public mutating func observe(_ remote: Self, at date: Date = .now) -> Self {
        let now = Self.milliseconds(date)
        let maximum = max(now, max(physicalMilliseconds, remote.physicalMilliseconds))

        switch (maximum == physicalMilliseconds, maximum == remote.physicalMilliseconds) {
        case (true, true):
            logical = max(logical, remote.logical) &+ 1
        case (true, false):
            logical &+= 1
        case (false, true):
            logical = remote.logical &+ 1
        case (false, false):
            logical = 0
        }

        physicalMilliseconds = maximum
        return self
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.physicalMilliseconds != rhs.physicalMilliseconds {
            return lhs.physicalMilliseconds < rhs.physicalMilliseconds
        }
        if lhs.logical != rhs.logical {
            return lhs.logical < rhs.logical
        }
        return lhs.nodeID.uuidString < rhs.nodeID.uuidString
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded(.down))
    }
}
```

- [ ] **Step 4: Run the clock tests**

Run the command from Step 2.

Expected: all four tests pass.

- [ ] **Step 5: Commit the clock**

```bash
git add BookManagerCore/CRDT BookManagerCoreTests/CRDT
git commit -m "feat: add hybrid logical clock"
```

### Task 3: Automerge Feasibility Spike and Book Document Adapter

**Files:**

- Create: `BookManagerCore/CRDT/BookDocumentSchema.swift`
- Create: `BookManagerCore/CRDT/AutomergeBookDocument.swift`
- Create: `BookManagerCoreTests/CRDT/AutomergeBookDocumentTests.swift`

- [ ] **Step 1: Write the Automerge acceptance tests**

Create `BookManagerCoreTests/CRDT/AutomergeBookDocumentTests.swift`:

```swift
import Automerge
import Foundation
import Testing
@testable import BookManagerCore

@Suite
struct AutomergeBookDocumentTests {
    private let bookID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    private let deviceA = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
    private let deviceB = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!

    @Test
    func creationChangeRoundTripsIntoEmptyReplica() throws {
        let source = try AutomergeBookDocument.new(bookID: bookID, deviceID: deviceA)
        let clock = HybridLogicalClock(physicalMilliseconds: 1_000, nodeID: deviceA)
        let change = try source.setTitle("Range", clock: clock)
        let replica = try AutomergeBookDocument.empty(deviceID: deviceB)

        try replica.apply(change)

        #expect(try replica.resolvedBook().id == bookID)
        #expect(try replica.resolvedBook().title == "Range")
        #expect(replica.heads() == source.heads())
    }

    @Test
    func concurrentDifferentFieldsSurvive() throws {
        let base = try AutomergeBookDocument.new(bookID: bookID, deviceID: deviceA)
        let creation = try base.setTitle("Range", clock: .init(physicalMilliseconds: 1_000, nodeID: deviceA))

        let first = try AutomergeBookDocument.empty(deviceID: deviceA)
        let second = try AutomergeBookDocument.empty(deviceID: deviceB)
        try first.apply(creation)
        try second.apply(creation)

        let titleChange = try first.setTitle(
            "Range: Revised",
            clock: .init(physicalMilliseconds: 2_000, nodeID: deviceA)
        )
        let authorChange = try second.setAuthors(
            ["David Epstein"],
            clock: .init(physicalMilliseconds: 2_100, nodeID: deviceB)
        )

        try first.apply(authorChange)
        try second.apply(titleChange)

        #expect(try first.resolvedBook() == second.resolvedBook())
        #expect(try first.resolvedBook().title == "Range: Revised")
        #expect(try first.resolvedBook().authors == ["David Epstein"])
    }

    @Test
    func newerHLCWinsSameFieldRegardlessOfDeliveryOrder() throws {
        let base = try AutomergeBookDocument.new(bookID: bookID, deviceID: deviceA)
        let creation = try base.setTitle("Original", clock: .init(physicalMilliseconds: 1_000, nodeID: deviceA))
        let first = try AutomergeBookDocument.empty(deviceID: deviceA)
        let second = try AutomergeBookDocument.empty(deviceID: deviceB)
        try first.apply(creation)
        try second.apply(creation)

        let older = try first.setTitle("Older", clock: .init(physicalMilliseconds: 2_000, nodeID: deviceA))
        let newer = try second.setTitle("Newer", clock: .init(physicalMilliseconds: 3_000, nodeID: deviceB))

        try first.apply(newer)
        try second.apply(older)

        #expect(try first.resolvedBook().title == "Newer")
        #expect(try second.resolvedBook().title == "Newer")
    }

    @Test
    func savedSnapshotCanContinueWithNewDeviceActor() throws {
        let source = try AutomergeBookDocument.new(bookID: bookID, deviceID: deviceA)
        _ = try source.setTitle("Range", clock: .init(physicalMilliseconds: 1_000, nodeID: deviceA))

        let reopened = try AutomergeBookDocument(snapshot: source.snapshot(), deviceID: deviceB)
        let change = try reopened.setAuthors(
            ["David Epstein"],
            clock: .init(physicalMilliseconds: 2_000, nodeID: deviceB)
        )

        #expect(!change.isEmpty)
        #expect(try reopened.resolvedBook().authors == ["David Epstein"])
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:

```bash
xcodebuild -project BookManager.xcodeproj -scheme BookManager -destination 'platform=macOS' -only-testing:BookManagerCoreTests/AutomergeBookDocumentTests test
```

Expected: compilation fails because the schema and adapter are undefined.

- [ ] **Step 3: Add the domain schema**

Create `BookManagerCore/CRDT/BookDocumentSchema.swift`:

```swift
import Foundation

public struct VersionedValue<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public let value: Value
    public let clock: HybridLogicalClock

    public init(value: Value, clock: HybridLogicalClock) {
        self.value = value
        self.clock = clock
    }
}

public struct BookDocumentSchema: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var bookID: UUID?
    public var titles: [String: VersionedValue<String>]
    public var authors: [String: VersionedValue<[String]>]
    public var deletions: [String: VersionedValue<Bool>]

    public init(
        schemaVersion: Int = 1,
        bookID: UUID? = nil,
        titles: [String: VersionedValue<String>] = [:],
        authors: [String: VersionedValue<[String]>] = [:],
        deletions: [String: VersionedValue<Bool>] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.bookID = bookID
        self.titles = titles
        self.authors = authors
        self.deletions = deletions
    }
}

public struct ResolvedBook: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let title: String
    public let authors: [String]
    public let isDeleted: Bool
    public let modifiedClock: HybridLogicalClock
}
```

- [ ] **Step 4: Implement the Automerge adapter**

Create `BookManagerCore/CRDT/AutomergeBookDocument.swift`:

```swift
import Automerge
import Foundation

public final class AutomergeBookDocument: @unchecked Sendable {
    private let document: Document
    private let deviceID: UUID

    private init(document: Document, deviceID: UUID) {
        self.document = document
        self.deviceID = deviceID
        self.document.actor = ActorId(uuid: deviceID)
    }

    public static func empty(deviceID: UUID) throws -> AutomergeBookDocument {
        AutomergeBookDocument(document: Document(), deviceID: deviceID)
    }

    public static func new(bookID: UUID, deviceID: UUID) throws -> AutomergeBookDocument {
        let result = AutomergeBookDocument(document: Document(), deviceID: deviceID)
        var schema = BookDocumentSchema(bookID: bookID)
        schema.deletions[deviceID.uuidString] = VersionedValue(
            value: false,
            clock: HybridLogicalClock(nodeID: deviceID)
        )
        try result.encode(schema)
        return result
    }

    public convenience init(snapshot: Data, deviceID: UUID) throws {
        try self.init(document: Document(snapshot), deviceID: deviceID)
    }

    public func setTitle(_ title: String, clock: HybridLogicalClock) throws -> Data {
        var schema = try decode()
        schema.titles[deviceID.uuidString] = VersionedValue(value: title, clock: clock)
        return try commit(schema, message: "set-title", timestamp: clock.date)
    }

    public func setAuthors(_ authors: [String], clock: HybridLogicalClock) throws -> Data {
        var schema = try decode()
        schema.authors[deviceID.uuidString] = VersionedValue(value: authors, clock: clock)
        return try commit(schema, message: "set-authors", timestamp: clock.date)
    }

    public func apply(_ encodedChanges: Data) throws {
        try document.applyEncodedChanges(encoded: encodedChanges)
        _ = document.encodeNewChanges()
    }

    public func snapshot() -> Data {
        document.save()
    }

    public func heads() -> Set<ChangeHash> {
        document.heads()
    }

    public func resolvedBook() throws -> ResolvedBook {
        let schema = try decode()
        guard let id = schema.bookID else {
            throw BookDocumentError.missingBookID
        }

        let title = newest(schema.titles)?.value ?? "Unknown"
        let authors = newest(schema.authors)?.value ?? ["Unknown"]
        let deletion = newest(schema.deletions)
        let clocks = [
            newest(schema.titles)?.clock,
            newest(schema.authors)?.clock,
            deletion?.clock
        ].compactMap { $0 }

        guard let modifiedClock = clocks.max() else {
            throw BookDocumentError.missingClock
        }

        return ResolvedBook(
            id: id,
            title: title,
            authors: authors,
            isDeleted: deletion?.value ?? false,
            modifiedClock: modifiedClock
        )
    }

    private func commit(
        _ schema: BookDocumentSchema,
        message: String,
        timestamp: Date
    ) throws -> Data {
        try encode(schema)
        document.commitWith(message: message, timestamp: timestamp)
        return document.encodeNewChanges()
    }

    private func encode(_ schema: BookDocumentSchema) throws {
        try AutomergeEncoder(doc: document).encode(schema)
    }

    private func decode() throws -> BookDocumentSchema {
        try AutomergeDecoder(doc: document).decode(BookDocumentSchema.self)
    }

    private func newest<Value>(
        _ values: [String: VersionedValue<Value>]
    ) -> VersionedValue<Value>? {
        values.values.max { $0.clock < $1.clock }
    }
}

public enum BookDocumentError: Error, Equatable {
    case missingBookID
    case missingClock
}

private extension HybridLogicalClock {
    var date: Date {
        Date(timeIntervalSince1970: TimeInterval(physicalMilliseconds) / 1_000)
    }
}
```

- [ ] **Step 5: Run the Automerge acceptance tests**

Run the command from Step 2.

Expected: tests pass, proving Automerge 0.7.2 supports the selected incremental-change and snapshot APIs.

- [ ] **Step 6: Run the full unit suite**

Run:

```bash
xcodebuild -project BookManager.xcodeproj -scheme BookManager -destination 'platform=macOS' -only-testing:BookManagerCoreTests test
```

Expected: all unit tests pass.

- [ ] **Step 7: Commit the Automerge spike**

```bash
git add BookManagerCore/CRDT BookManagerCoreTests/CRDT
git commit -m "feat: add Automerge book document adapter"
```

### Task 4: Library Manifest, Layout, and Immutable Change Store

**Files:**

- Create: `BookManagerCore/Library/LibraryManifest.swift`
- Create: `BookManagerCore/Library/LibraryLayout.swift`
- Create: `BookManagerCore/Library/CanonicalPathBuilder.swift`
- Create: `BookManagerCore/Library/ChangeStore.swift`
- Create: `BookManagerCoreTests/Library/LibraryStorageTests.swift`

- [ ] **Step 1: Write the portable-layout tests**

Create `BookManagerCoreTests/Library/LibraryStorageTests.swift`:

```swift
import Foundation
import Testing
@testable import BookManagerCore

@Suite
struct LibraryStorageTests {
    @Test
    func createsPortableControlDirectoriesAndManifest() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let layout = LibraryLayout(root: root)
        let manifest = LibraryManifest(id: UUID(), createdAt: Date(timeIntervalSince1970: 1))

        try layout.create(manifest: manifest)

        #expect(FileManager.default.fileExists(atPath: layout.manifestURL.path))
        #expect(try layout.readManifest() == manifest)
        #expect(FileManager.default.fileExists(atPath: layout.bookChangesRoot.path))
        #expect(FileManager.default.fileExists(atPath: layout.libraryChangesRoot.path))
    }

    @Test
    func canonicalPathIncludesHumanNamesAndStableShortID() {
        let id = UUID(uuidString: "12345678-0000-0000-0000-000000000000")!
        let relative = CanonicalPathBuilder.relativeDirectory(
            bookID: id,
            title: "Range: Why Generalists Triumph?",
            authors: ["David Epstein"]
        )

        #expect(relative == "David Epstein/Range_ Why Generalists Triumph_ (12345678)")
    }

    @Test
    func changeStoreWritesOnceAndEnumeratesByBook() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let layout = LibraryLayout(root: root)
        try layout.create(manifest: LibraryManifest(id: UUID()))
        let store = ChangeStore(layout: layout)
        let bookID = UUID()
        let deviceID = UUID()
        let clock = HybridLogicalClock(physicalMilliseconds: 1_000, nodeID: deviceID)
        let data = Data("encoded-change".utf8)

        let firstURL = try await store.writeBookChange(
            data,
            bookID: bookID,
            deviceID: deviceID,
            clock: clock
        )
        let secondURL = try await store.writeBookChange(
            data,
            bookID: bookID,
            deviceID: deviceID,
            clock: clock
        )

        #expect(firstURL == secondURL)
        #expect(try await store.bookChanges(bookID: bookID) == [data])
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:

```bash
xcodebuild -project BookManager.xcodeproj -scheme BookManager -destination 'platform=macOS' -only-testing:BookManagerCoreTests/LibraryStorageTests test
```

Expected: compilation fails because the library storage types are undefined.

- [ ] **Step 3: Implement manifest and layout**

Create `BookManagerCore/Library/LibraryManifest.swift`:

```swift
import Foundation

public struct LibraryManifest: Codable, Equatable, Sendable {
    public let id: UUID
    public let formatVersion: Int
    public let createdAt: Date

    public init(id: UUID, formatVersion: Int = 1, createdAt: Date = .now) {
        self.id = id
        self.formatVersion = formatVersion
        self.createdAt = createdAt
    }
}
```

Create `BookManagerCore/Library/LibraryLayout.swift`:

```swift
import Foundation

public struct LibraryLayout: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    public var controlRoot: URL { root.appending(path: ".bookmanager", directoryHint: .isDirectory) }
    public var manifestURL: URL { controlRoot.appending(path: "library.json") }
    public var changesRoot: URL { controlRoot.appending(path: "changes", directoryHint: .isDirectory) }
    public var bookChangesRoot: URL { changesRoot.appending(path: "books", directoryHint: .isDirectory) }
    public var libraryChangesRoot: URL { changesRoot.appending(path: "library", directoryHint: .isDirectory) }
    public var transactionsRoot: URL { controlRoot.appending(path: "transactions", directoryHint: .isDirectory) }
    public var trashRoot: URL { controlRoot.appending(path: "trash", directoryHint: .isDirectory) }
    public var recoveryRoot: URL { controlRoot.appending(path: "recovery", directoryHint: .isDirectory) }
    public var quarantineRoot: URL { controlRoot.appending(path: "quarantine", directoryHint: .isDirectory) }

    public func create(manifest: LibraryManifest) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        for directory in [
            bookChangesRoot,
            libraryChangesRoot,
            transactionsRoot,
            trashRoot,
            recoveryRoot,
            quarantineRoot
        ] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let data = try JSONEncoder.bookManager.encode(manifest)
        try data.write(to: manifestURL, options: .atomic)
    }

    public func readManifest() throws -> LibraryManifest {
        try JSONDecoder.bookManager.decode(
            LibraryManifest.self,
            from: Data(contentsOf: manifestURL)
        )
    }
}

extension JSONEncoder {
    static var bookManager: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var bookManager: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
```

- [ ] **Step 4: Implement deterministic Calibre-style paths**

Create `BookManagerCore/Library/CanonicalPathBuilder.swift`:

```swift
import Foundation

public enum CanonicalPathBuilder {
    public static func relativeDirectory(
        bookID: UUID,
        title: String,
        authors: [String]
    ) -> String {
        let author = sanitized(authors.first ?? "Unknown")
        let safeTitle = sanitized(title.isEmpty ? "Unknown" : title)
        let shortID = String(bookID.uuidString.prefix(8)).lowercased()
        return "\(author)/\(safeTitle) (\(shortID))"
    }

    private static func sanitized(_ value: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let scalars = value.unicodeScalars.map { forbidden.contains($0) ? "_" : Character($0) }
        let result = String(scalars)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return String((result.isEmpty ? "Unknown" : result).prefix(120))
    }
}
```

- [ ] **Step 5: Implement content-addressed immutable change writes**

Create `BookManagerCore/Library/ChangeStore.swift`:

```swift
import CryptoKit
import Foundation

public actor ChangeStore {
    private let layout: LibraryLayout

    public init(layout: LibraryLayout) {
        self.layout = layout
    }

    public func writeBookChange(
        _ data: Data,
        bookID: UUID,
        deviceID: UUID,
        clock: HybridLogicalClock
    ) throws -> URL {
        let directory = layout.bookChangesRoot
            .appending(path: bookID.uuidString, directoryHint: .isDirectory)
            .appending(path: deviceID.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let clockPart = "\(clock.physicalMilliseconds)-\(clock.logical)"
        let destination = directory.appending(path: "\(clockPart)-\(digest).amchange")

        if FileManager.default.fileExists(atPath: destination.path) {
            return destination
        }

        try data.write(to: destination, options: [.atomic, .withoutOverwriting])
        return destination
    }

    public func bookChanges(bookID: UUID) throws -> [Data] {
        let bookRoot = layout.bookChangesRoot
            .appending(path: bookID.uuidString, directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: bookRoot.path) else {
            return []
        }
        let keys: [URLResourceKey] = [.isRegularFileKey]
        let files = FileManager.default.enumerator(
            at: bookRoot,
            includingPropertiesForKeys: keys
        )?.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "amchange" }
            .sorted { $0.path < $1.path } ?? []
        return try files.map(Data.init(contentsOf:))
    }

    public func bookIDs() throws -> [UUID] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: layout.bookChangesRoot,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        return urls.compactMap { UUID(uuidString: $0.lastPathComponent) }
            .sorted { $0.uuidString < $1.uuidString }
    }
}
```

- [ ] **Step 6: Run the library storage tests**

Run the command from Step 2.

Expected: all three tests pass.

- [ ] **Step 7: Commit portable storage**

```bash
git add BookManagerCore/Library BookManagerCoreTests/Library
git commit -m "feat: add portable library layout and change store"
```

### Task 5: Rebuildable GRDB Catalogue

**Files:**

- Create: `BookManagerCore/Persistence/IndexedBook.swift`
- Create: `BookManagerCore/Persistence/LocalCatalog.swift`
- Create: `BookManagerCoreTests/Persistence/LocalCatalogTests.swift`

- [ ] **Step 1: Write catalogue persistence and search tests**

Create `BookManagerCoreTests/Persistence/LocalCatalogTests.swift`:

```swift
import Foundation
import Testing
@testable import BookManagerCore

@Suite
struct LocalCatalogTests {
    @Test
    func upsertsListsAndSearchesBooks() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).sqlite")
        let catalog = try LocalCatalog(databaseURL: databaseURL)
        let book = IndexedBook(
            id: UUID(),
            title: "Range",
            authors: ["David Epstein"],
            modifiedMilliseconds: 1_000,
            isDeleted: false,
            snapshot: Data([1, 2, 3])
        )

        try await catalog.upsert(book)

        #expect(try await catalog.allBooks().map(\.title) == ["Range"])
        #expect(try await catalog.search("Epstein").map(\.id) == [book.id])
        #expect(try await catalog.snapshot(bookID: book.id) == Data([1, 2, 3]))
    }

    @Test
    func deletedBooksAreExcludedFromNormalQueries() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).sqlite")
        let catalog = try LocalCatalog(databaseURL: databaseURL)
        let book = IndexedBook(
            id: UUID(),
            title: "Deleted",
            authors: ["Author"],
            modifiedMilliseconds: 1_000,
            isDeleted: true,
            snapshot: Data()
        )

        try await catalog.upsert(book)

        #expect(try await catalog.allBooks().isEmpty)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:

```bash
xcodebuild -project BookManager.xcodeproj -scheme BookManager -destination 'platform=macOS' -only-testing:BookManagerCoreTests/LocalCatalogTests test
```

Expected: compilation fails because `IndexedBook` and `LocalCatalog` are undefined.

- [ ] **Step 3: Add the indexed record**

Create `BookManagerCore/Persistence/IndexedBook.swift`:

```swift
import Foundation
import GRDB

public struct IndexedBook: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let title: String
    public let authors: [String]
    public let modifiedMilliseconds: Int64
    public let isDeleted: Bool
    public let snapshot: Data

    public init(
        id: UUID,
        title: String,
        authors: [String],
        modifiedMilliseconds: Int64,
        isDeleted: Bool,
        snapshot: Data
    ) {
        self.id = id
        self.title = title
        self.authors = authors
        self.modifiedMilliseconds = modifiedMilliseconds
        self.isDeleted = isDeleted
        self.snapshot = snapshot
    }
}

extension IndexedBook: FetchableRecord, PersistableRecord, TableRecord {
    public static let databaseTableName = "book"

    enum Columns {
        static let id = Column("id")
        static let title = Column("title")
        static let authors = Column("authors")
        static let modifiedMilliseconds = Column("modifiedMilliseconds")
        static let isDeleted = Column("isDeleted")
        static let snapshot = Column("snapshot")
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.authors == rhs.authors
            && lhs.modifiedMilliseconds == rhs.modifiedMilliseconds
            && lhs.isDeleted == rhs.isDeleted
    }
}
```

- [ ] **Step 4: Implement migrations, writes, listing, and FTS5 search**

Create `BookManagerCore/Persistence/LocalCatalog.swift`:

```swift
import Foundation
import GRDB

public actor LocalCatalog {
    private let database: DatabaseQueue

    public init(databaseURL: URL) throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        database = try DatabaseQueue(path: databaseURL.path)
        try Self.migrator.migrate(database)
    }

    public func upsert(_ book: IndexedBook) throws {
        try database.write { db in
            try book.save(db)
            try db.execute(sql: "DELETE FROM bookSearch WHERE bookID = ?", arguments: [book.id.uuidString])
            try db.execute(
                sql: "INSERT INTO bookSearch(bookID, title, authors) VALUES (?, ?, ?)",
                arguments: [book.id.uuidString, book.title, book.authors.joined(separator: " ")]
            )
        }
    }

    public func allBooks() throws -> [IndexedBook] {
        try database.read { db in
            try IndexedBook
                .filter(IndexedBook.Columns.isDeleted == false)
                .order(IndexedBook.Columns.title.collating(.localizedCaseInsensitiveCompare))
                .fetchAll(db)
        }
    }

    public func search(_ query: String) throws -> [IndexedBook] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return try allBooks()
        }
        return try database.read { db in
            try IndexedBook.fetchAll(
                db,
                sql: """
                    SELECT book.*
                    FROM book
                    JOIN bookSearch ON bookSearch.bookID = book.id
                    WHERE bookSearch MATCH ? AND book.isDeleted = 0
                    ORDER BY book.title COLLATE NOCASE
                    """,
                arguments: [query]
            )
        }
    }

    public func snapshot(bookID: UUID) throws -> Data? {
        try database.read { db in
            try Data.fetchOne(
                db,
                sql: "SELECT snapshot FROM book WHERE id = ?",
                arguments: [bookID]
            )
        }
    }

    public func clear() throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM book")
            try db.execute(sql: "DELETE FROM bookSearch")
        }
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("createBookIndex") { db in
            try db.create(table: "book") { table in
                table.column("id", .text).primaryKey()
                table.column("title", .text).notNull()
                table.column("authors", .text).notNull()
                table.column("modifiedMilliseconds", .integer).notNull()
                table.column("isDeleted", .boolean).notNull()
                table.column("snapshot", .blob).notNull()
            }
            try db.create(virtualTable: "bookSearch", using: FTS5()) { table in
                table.column("bookID").notIndexed()
                table.column("title")
                table.column("authors")
                table.tokenizer = .unicode61()
            }
        }
        return migrator
    }
}
```

- [ ] **Step 5: Run the catalogue tests**

Run the command from Step 2.

Expected: both tests pass.

- [ ] **Step 6: Commit the catalogue**

```bash
git add BookManagerCore/Persistence BookManagerCoreTests/Persistence
git commit -m "feat: add rebuildable GRDB catalogue"
```

### Task 6: Library Repository and Deterministic Rebuild

**Files:**

- Create: `BookManagerCore/Library/LibraryRepository.swift`
- Create: `BookManagerCoreTests/Library/LibraryRepositoryTests.swift`

- [ ] **Step 1: Write repository creation and rebuild tests**

Create `BookManagerCoreTests/Library/LibraryRepositoryTests.swift`:

```swift
import Foundation
import Testing
@testable import BookManagerCore

@Suite
struct LibraryRepositoryTests {
    @Test
    func createsBookChangeAndRebuildsFreshCatalog() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let firstIndexes = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let secondIndexes = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let deviceID = UUID()

        let repository = try await LibraryRepository.create(
            at: root,
            indexesDirectory: firstIndexes,
            deviceID: deviceID
        )
        let created = try await repository.createBook(
            title: "Range",
            authors: ["David Epstein"],
            at: Date(timeIntervalSince1970: 1)
        )

        let rebuilt = try await LibraryRepository.open(
            at: root,
            indexesDirectory: secondIndexes,
            deviceID: UUID()
        )

        #expect(try await rebuilt.books() == [created])
    }

    @Test
    func rejectsUnsupportedLibraryFormat() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let layout = LibraryLayout(root: root)
        try layout.create(manifest: LibraryManifest(id: UUID(), formatVersion: 99))

        await #expect(throws: LibraryRepositoryError.unsupportedFormat(99)) {
            try await LibraryRepository.open(
                at: root,
                indexesDirectory: FileManager.default.temporaryDirectory
                    .appending(path: UUID().uuidString, directoryHint: .isDirectory),
                deviceID: UUID()
            )
        }
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:

```bash
xcodebuild -project BookManager.xcodeproj -scheme BookManager -destination 'platform=macOS' -only-testing:BookManagerCoreTests/LibraryRepositoryTests test
```

Expected: compilation fails because `LibraryRepository` is undefined.

- [ ] **Step 3: Implement create, open, create-book, and rebuild**

Create `BookManagerCore/Library/LibraryRepository.swift`:

```swift
import Foundation

public actor LibraryRepository {
    public let manifest: LibraryManifest
    public let root: URL

    private let layout: LibraryLayout
    private let changeStore: ChangeStore
    private let catalog: LocalCatalog
    private let deviceID: UUID
    private var clock: HybridLogicalClock

    private init(
        manifest: LibraryManifest,
        layout: LibraryLayout,
        catalog: LocalCatalog,
        deviceID: UUID
    ) {
        self.manifest = manifest
        root = layout.root
        self.layout = layout
        changeStore = ChangeStore(layout: layout)
        self.catalog = catalog
        self.deviceID = deviceID
        clock = HybridLogicalClock(nodeID: deviceID)
    }

    public static func create(
        at root: URL,
        indexesDirectory: URL,
        deviceID: UUID
    ) async throws -> LibraryRepository {
        let layout = LibraryLayout(root: root)
        let manifest = LibraryManifest(id: UUID())
        try layout.create(manifest: manifest)
        let repository = try LibraryRepository(
            manifest: manifest,
            layout: layout,
            catalog: LocalCatalog(
                databaseURL: indexesDirectory.appending(path: "\(manifest.id.uuidString).sqlite")
            ),
            deviceID: deviceID
        )
        return repository
    }

    public static func open(
        at root: URL,
        indexesDirectory: URL,
        deviceID: UUID
    ) async throws -> LibraryRepository {
        let layout = LibraryLayout(root: root)
        let manifest = try layout.readManifest()
        guard manifest.formatVersion == 1 else {
            throw LibraryRepositoryError.unsupportedFormat(manifest.formatVersion)
        }
        let repository = try LibraryRepository(
            manifest: manifest,
            layout: layout,
            catalog: LocalCatalog(
                databaseURL: indexesDirectory.appending(path: "\(manifest.id.uuidString).sqlite")
            ),
            deviceID: deviceID
        )
        try await repository.rebuildCatalog()
        return repository
    }

    @discardableResult
    public func createBook(
        title: String,
        authors: [String],
        at date: Date = .now
    ) async throws -> IndexedBook {
        let bookID = UUID()
        let document = try AutomergeBookDocument.new(bookID: bookID, deviceID: deviceID)

        let titleClock = clock.tick(at: date)
        let titleChange = try document.setTitle(title, clock: titleClock)
        _ = try await changeStore.writeBookChange(
            titleChange,
            bookID: bookID,
            deviceID: deviceID,
            clock: titleClock
        )

        let authorClock = clock.tick(at: date)
        let authorChange = try document.setAuthors(authors, clock: authorClock)
        _ = try await changeStore.writeBookChange(
            authorChange,
            bookID: bookID,
            deviceID: deviceID,
            clock: authorClock
        )

        let indexed = try makeIndexedBook(document)
        try await catalog.upsert(indexed)
        return indexed
    }

    public func books() async throws -> [IndexedBook] {
        try await catalog.allBooks()
    }

    public func search(_ query: String) async throws -> [IndexedBook] {
        try await catalog.search(query)
    }

    public func rebuildCatalog() async throws {
        try await catalog.clear()
        for bookID in try await changeStore.bookIDs() {
            let pending = try await changeStore.bookChanges(bookID: bookID)
            let document = try AutomergeBookDocument.empty(deviceID: deviceID)
            var remaining = pending
            var madeProgress = true

            while !remaining.isEmpty && madeProgress {
                madeProgress = false
                var next: [Data] = []
                for change in remaining {
                    do {
                        try document.apply(change)
                        madeProgress = true
                    } catch {
                        next.append(change)
                    }
                }
                remaining = next
            }

            guard remaining.isEmpty else {
                throw LibraryRepositoryError.missingDependencies(bookID)
            }
            try await catalog.upsert(makeIndexedBook(document))
        }
    }

    private func makeIndexedBook(_ document: AutomergeBookDocument) throws -> IndexedBook {
        let book = try document.resolvedBook()
        return IndexedBook(
            id: book.id,
            title: book.title,
            authors: book.authors,
            modifiedMilliseconds: book.modifiedClock.physicalMilliseconds,
            isDeleted: book.isDeleted,
            snapshot: document.snapshot()
        )
    }
}

public enum LibraryRepositoryError: Error, Equatable {
    case unsupportedFormat(Int)
    case missingDependencies(UUID)
}
```

- [ ] **Step 4: Run the repository tests**

Run the command from Step 2.

Expected: both tests pass and the second repository rebuilds solely from `.amchange` files.

- [ ] **Step 5: Run all core tests twice**

Run:

```bash
xcodebuild -project BookManager.xcodeproj -scheme BookManager -destination 'platform=macOS' -only-testing:BookManagerCoreTests test
xcodebuild -project BookManager.xcodeproj -scheme BookManager -destination 'platform=macOS' -only-testing:BookManagerCoreTests test
```

Expected: both runs pass, proving rebuild and test fixtures are deterministic.

- [ ] **Step 6: Commit the repository**

```bash
git add BookManagerCore/Library/LibraryRepository.swift BookManagerCoreTests/Library/LibraryRepositoryTests.swift
git commit -m "feat: create and rebuild portable libraries"
```

### Task 7: Security-Scoped Bookmark Persistence

**Files:**

- Create: `BookManagerCore/Security/LibraryBookmarkStore.swift`
- Create: `BookManagerCoreTests/Security/LibraryBookmarkStoreTests.swift`

- [ ] **Step 1: Write bookmark round-trip tests**

Create `BookManagerCoreTests/Security/LibraryBookmarkStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import BookManagerCore

@Suite
struct LibraryBookmarkStoreTests {
    @Test
    func storesAndResolvesBookmarkByLibraryID() throws {
        let suite = "BookManagerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = LibraryBookmarkStore(defaults: defaults)
        let libraryID = UUID()
        let folder = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        try store.save(folder, for: libraryID)
        let resolved = try store.resolve(libraryID)

        #expect(resolved.url.standardizedFileURL == folder.standardizedFileURL)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
xcodebuild -project BookManager.xcodeproj -scheme BookManager -destination 'platform=macOS' -only-testing:BookManagerCoreTests/LibraryBookmarkStoreTests test
```

Expected: compilation fails because `LibraryBookmarkStore` is undefined.

- [ ] **Step 3: Implement bookmark persistence**

Create `BookManagerCore/Security/LibraryBookmarkStore.swift`:

```swift
import Foundation

public struct ResolvedLibraryBookmark: Sendable {
    public let url: URL
    public let isStale: Bool
}

public struct LibraryBookmarkStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "librarySecurityBookmarks"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func save(_ url: URL, for libraryID: UUID) throws {
        let data = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        var bookmarks = defaults.dictionary(forKey: key) as? [String: Data] ?? [:]
        bookmarks[libraryID.uuidString] = data
        defaults.set(bookmarks, forKey: key)
    }

    public func resolve(_ libraryID: UUID) throws -> ResolvedLibraryBookmark {
        guard
            let bookmarks = defaults.dictionary(forKey: key) as? [String: Data],
            let data = bookmarks[libraryID.uuidString]
        else {
            throw LibraryBookmarkError.notFound(libraryID)
        }
        var stale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        return ResolvedLibraryBookmark(url: url, isStale: stale)
    }
}

public enum LibraryBookmarkError: Error, Equatable {
    case notFound(UUID)
}
```

- [ ] **Step 4: Run the bookmark test**

Run the command from Step 2.

Expected: the test passes.

- [ ] **Step 5: Commit bookmark support**

```bash
git add BookManagerCore/Security BookManagerCoreTests/Security
git commit -m "feat: persist library security bookmarks"
```

### Task 8: Observable Library Session and Native SwiftUI Browser

**Files:**

- Create: `BookManager/Stores/LibrarySession.swift`
- Replace: `BookManager/Views/ContentView.swift`
- Create: `BookManager/Views/LibraryWelcomeView.swift`
- Create: `BookManager/Views/BookTableView.swift`
- Modify: `BookManager/App/BookManagerApp.swift`
- Modify: `BookManagerUITests/BookManagerUITests.swift`

- [ ] **Step 1: Update the UI smoke test**

Replace `BookManagerUITests/BookManagerUITests.swift`:

```swift
import XCTest

final class BookManagerUITests: XCTestCase {
    func testWelcomeScreenExposesLibraryActions() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()

        XCTAssertTrue(app.buttons["Create Library"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Open Library"].exists)
        XCTAssertTrue(app.staticTexts["Your books, in a library you control."].exists)
    }
}
```

- [ ] **Step 2: Run the UI test to verify it fails**

Run:

```bash
xcodebuild -project BookManager.xcodeproj -scheme BookManager -destination 'platform=macOS' -only-testing:BookManagerUITests/BookManagerUITests/testWelcomeScreenExposesLibraryActions test
```

Expected: failure because the welcome controls do not exist.

- [ ] **Step 3: Implement the observable session**

Create `BookManager/Stores/LibrarySession.swift`:

```swift
import BookManagerCore
import Foundation
import Observation

@MainActor
@Observable
final class LibrarySession {
    enum State {
        case welcome
        case loading
        case loaded(name: String, books: [IndexedBook])
        case failed(message: String)
    }

    private(set) var state: State = .welcome
    private(set) var repository: LibraryRepository?
    var searchText = "" {
        didSet { Task { await refresh() } }
    }

    private let deviceID: UUID
    private let bookmarks: LibraryBookmarkStore
    private var activeSecurityURL: URL?

    init(
        deviceID: UUID = UUID(),
        bookmarks: LibraryBookmarkStore = LibraryBookmarkStore()
    ) {
        self.deviceID = deviceID
        self.bookmarks = bookmarks
    }

    func createLibrary(at url: URL) async {
        await activate(url: url, create: true)
    }

    func openLibrary(at url: URL) async {
        await activate(url: url, create: false)
    }

    func closeLibrary() {
        activeSecurityURL?.stopAccessingSecurityScopedResource()
        activeSecurityURL = nil
        repository = nil
        state = .welcome
    }

    func refresh() async {
        guard let repository else { return }
        do {
            let books = searchText.isEmpty
                ? try await repository.books()
                : try await repository.search(searchText)
            state = .loaded(name: repository.root.lastPathComponent, books: books)
        } catch {
            state = .failed(message: error.localizedDescription)
        }
    }

    private func activate(url: URL, create: Bool) async {
        state = .loading
        let accessed = url.startAccessingSecurityScopedResource()

        do {
            let indexes = try Self.indexDirectory()
            let repository: LibraryRepository
            if create {
                repository = try await .create(
                    at: url,
                    indexesDirectory: indexes,
                    deviceID: deviceID
                )
            } else {
                repository = try await .open(
                    at: url,
                    indexesDirectory: indexes,
                    deviceID: deviceID
                )
            }
            try bookmarks.save(url, for: repository.manifest.id)
            activeSecurityURL?.stopAccessingSecurityScopedResource()
            activeSecurityURL = accessed ? url : nil
            self.repository = repository
            await refresh()
        } catch {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
            state = .failed(message: error.localizedDescription)
        }
    }

    private static func indexDirectory() throws -> URL {
        let root = URL.applicationSupportDirectory
            .appending(path: "Book Manager", directoryHint: .isDirectory)
            .appending(path: "Indexes", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
```

- [ ] **Step 4: Implement the welcome view**

Create `BookManager/Views/LibraryWelcomeView.swift`:

```swift
import SwiftUI
import UniformTypeIdentifiers

struct LibraryWelcomeView: View {
    let createLibrary: () -> Void
    let openLibrary: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Book Manager", systemImage: "books.vertical")
        } description: {
            Text("Your books, in a library you control.")
        } actions: {
            HStack {
                Button("Create Library", action: createLibrary)
                    .buttonStyle(.borderedProminent)
                Button("Open Library", action: openLibrary)
            }
        }
    }
}
```

- [ ] **Step 5: Implement the native table**

Create `BookManager/Views/BookTableView.swift`:

```swift
import BookManagerCore
import SwiftUI

struct BookTableView: View {
    let books: [IndexedBook]
    @State private var selection = Set<IndexedBook.ID>()

    var body: some View {
        Table(books, selection: $selection) {
            TableColumn("Title", value: \.title)
            TableColumn("Authors") { book in
                Text(book.authors.joined(separator: ", "))
                    .foregroundStyle(.secondary)
            }
        }
        .overlay {
            if books.isEmpty {
                ContentUnavailableView(
                    "No Books",
                    systemImage: "books.vertical",
                    description: Text("Book import arrives in the next delivery slice.")
                )
            }
        }
    }
}
```

- [ ] **Step 6: Compose the main window and folder pickers**

Replace `BookManager/Views/ContentView.swift`:

```swift
import BookManagerCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var session: LibrarySession
    @State private var pickerPurpose: PickerPurpose?

    private enum PickerPurpose: Identifiable {
        case create
        case open

        var id: Self { self }
    }

    var body: some View {
        Group {
            switch session.state {
            case .welcome:
                LibraryWelcomeView(
                    createLibrary: { pickerPurpose = .create },
                    openLibrary: { pickerPurpose = .open }
                )
            case .loading:
                ProgressView("Opening Library…")
                    .controlSize(.large)
            case let .loaded(name, books):
                NavigationSplitView {
                    List {
                        Label("All Books", systemImage: "books.vertical")
                    }
                    .listStyle(.sidebar)
                    .navigationTitle(name)
                } detail: {
                    BookTableView(books: books)
                        .searchable(text: $session.searchText, prompt: "Search books")
                }
                .toolbar {
                    ToolbarItem {
                        Button("Close Library", systemImage: "xmark.circle") {
                            session.closeLibrary()
                        }
                    }
                }
            case let .failed(message):
                ContentUnavailableView {
                    Label("Couldn’t Open Library", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Choose Another Library") {
                        session.closeLibrary()
                    }
                }
            }
        }
        .frame(minWidth: 760, minHeight: 500)
        .fileImporter(
            isPresented: Binding(
                get: { pickerPurpose != nil },
                set: { if !$0 { pickerPurpose = nil } }
            ),
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            let purpose = pickerPurpose
            pickerPurpose = nil
            guard case let .success(urls) = result, let url = urls.first else { return }
            Task {
                switch purpose {
                case .create:
                    await session.createLibrary(at: url)
                case .open:
                    await session.openLibrary(at: url)
                case nil:
                    break
                }
            }
        }
    }
}
```

Modify `BookManager/App/BookManagerApp.swift`:

```swift
import SwiftUI

@main
struct BookManagerApp: App {
    @State private var session = LibrarySession()

    var body: some Scene {
        WindowGroup {
            ContentView(session: session)
        }
        .defaultSize(width: 1_100, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Close Library") {
                    session.closeLibrary()
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
            }
        }
    }
}
```

- [ ] **Step 7: Run UI and unit tests**

Run:

```bash
xcodebuild -project BookManager.xcodeproj -scheme BookManager -destination 'platform=macOS' test
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 8: Run the app and manually verify a library**

Run:

```bash
./script/build_and_run.sh
```

Verify:

1. The welcome screen appears.
2. Create Library accepts an empty folder.
3. The app displays that folder's name and an empty All Books table.
4. Closing the library returns to the welcome screen.
5. Open Library reopens the same folder without modifying `library.json`.

- [ ] **Step 9: Commit the app shell**

```bash
git add BookManager BookManagerUITests
git commit -m "feat: browse selected Book Manager libraries"
```

### Task 9: Slice Verification and Documentation

**Files:**

- Create: `README.md`
- Modify: `docs/superpowers/specs/2026-07-29-book-manager-design.md`

- [ ] **Step 1: Add build and architecture documentation**

Create `README.md`:

````markdown
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
````

- [ ] **Step 2: Run formatting and static checks**

Run:

```bash
xcodegen generate --spec project.yml
git diff --check
xcodebuild -project BookManager.xcodeproj -scheme BookManager -destination 'platform=macOS' analyze
```

Expected: no whitespace errors and `** ANALYZE SUCCEEDED **`.

- [ ] **Step 3: Run the complete test suite from a clean build**

Run:

```bash
xcodebuild -project BookManager.xcodeproj -scheme BookManager clean
xcodebuild -project BookManager.xcodeproj -scheme BookManager -destination 'platform=macOS' test
```

Expected: `** CLEAN SUCCEEDED **` followed by `** TEST SUCCEEDED **`.

- [ ] **Step 4: Verify the run entrypoint**

Run:

```bash
./script/build_and_run.sh --verify
```

Expected: the app builds, launches, and `pgrep -x BookManager` succeeds.

- [ ] **Step 5: Mark Slice 1 implementation status in the design**

After Steps 2–4 pass, append this subsection after the existing delivery-slice list in `docs/superpowers/specs/2026-07-29-book-manager-design.md`:

```markdown
### Implementation Status

- Slice 1 — Library foundation: implemented and verified
- Slice 2 — Management workflows: not started
- Slice 3 — Calibre migration: not started
- Slice 4 — Multi-Mac hardening: not started
```

- [ ] **Step 6: Inspect the final change set**

Run:

```bash
git status --short
git diff --stat HEAD
git log --oneline --decorate -10
```

Expected: only the README and design-status update remain uncommitted; implementation tasks appear as focused commits.

- [ ] **Step 7: Commit Slice 1 documentation**

```bash
git add README.md docs/superpowers/specs/2026-07-29-book-manager-design.md
git commit -m "docs: document library foundation"
```

- [ ] **Step 8: Confirm the repository is clean**

Run:

```bash
git status --short --branch
```

Expected: branch header only, with no modified or untracked files.
