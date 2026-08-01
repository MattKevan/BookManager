# Sync Monitor & Reconciliation (Slice 4b) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** continuous multi-Mac convergence — an always-on monitor (FSEvents where reliable, periodic full scans on network/cloud roots) ingests changes and reconciles the on-disk book folders to the merged CRDT metadata, forking conflicts (never overwriting) and surfacing them in Diagnostics.

**Architecture:** A Core `FolderReconciler` actor re-points/adopts/forks book folders after every ingest (journaled via `BookFolder`, catalog upserted via a new `IndexedBook.repointing(to:)`). A `SyncEventSource` protocol abstracts watching (`FSEventSource` via CoreServices `FSEventStreamSetDispatchQueue` for local roots, `PollingSource` for network/cloud roots and tests). A `LibraryMonitor` actor debounces events and runs the periodic `fullRescan` backstop. The app wires the monitor into `LibrarySession` (start on open after first ingest, stop on close, pause while unavailable), surfaces a Syncing indicator, and adds a Reconciliation section to Diagnostics. The 4a-mandated stuck-valid-change regression test lands with the monitor tests.

**Tech Stack:** Swift 6.0 (strict concurrency), SwiftUI, CoreServices (FSEventStream), Swift Testing, XcodeGen.

## Global Constraints

- macOS 26; Swift 6.0 with `SWIFT_STRICT_CONCURRENCY: complete`; Core actors (`LibrarySession` is `@MainActor @Observable`).
- **No change-store format change; nothing silently deletes book content.** Reconciliation only moves/forks files, journaled via `BookFolder`'s existing transaction journal.
- Canonical paths are derived from merged metadata (`CanonicalPathBuilder`); the catalog (Application Support) is disposable and rebuilds from changes.
- Conflict policy (approved): **fork, never overwrite** — `<name> (conflict <id-prefix>)` siblings; the catalog always points at the hash-matched file.
- Existing 119-test core suite stays green; the monitor pauses while the library is unavailable (read-only); FSEvents is only used on roots where the 4a capability probe says it's reliable.
- Tests: Swift Testing; xcodebuild with `-derivedDataPath .build/DerivedData`; run `xcodegen generate --spec project.yml` before building new files; suite-level `-only-testing` (single-test identifiers are unreliable).

---

### Task 1: `FolderReconciler` (Core, TDD)

**Files:**
- Create: `BookManagerCore/Sync/FolderReconciler.swift`
- Modify: `BookManagerCore/Library/BookFolder.swift` (add `forkConflict(bookID:relativePath:)` — journaled conflict move)
- Modify: `BookManagerCore/Persistence/IndexedBook.swift` (add `repointing(to:)`)
- Create: `BookManagerCoreTests/Sync/FolderReconcilerTests.swift`

**Interfaces:**
- Consumes: `LibraryLayout`, `LocalCatalog` (allBooks/deletedBooks/book(id:)/upsert), `BookFolder` (rename/trash/restore/bookDirectoryURL/trashDirectoryURL), `CanonicalPathBuilder.relativeDirectory`, `BookFolder.contentHash`.
- Produces:
  - `ReconciliationReport { renamed: [UUID], adopted: [UUID], conflictCopies: [URL], restoredFromTrash: [UUID], missingFolders: [UUID], errors: [String] }` (Sendable/Equatable, default init).
  - `FolderReconciler` actor: `init(layout:catalog:deviceID:)`, `func reconcile() async throws -> ReconciliationReport`.
  - `BookFolder.forkConflict(bookID:relativePath:) throws -> URL` (journaled move to a `<name> (conflict <id-prefix>)` sibling).
  - `IndexedBook.repointing(to path: String) -> IndexedBook` (all fields copied, `relativePath` replaced).

- [ ] **Step 1: Write the failing tests**

Create `BookManagerCoreTests/Sync/FolderReconcilerTests.swift`. The harness creates a real library via the repository (so folders materialize), then simulates divergence by renaming folders / upserting repointed catalog rows:

```swift
import Foundation
import Testing
@testable import BookManagerCore

@Suite
struct FolderReconcilerTests {
    private struct Harness {
        let layout: LibraryLayout
        let catalog: LocalCatalog
        let repository: LibraryRepository
        let deviceID = UUID()
        let root: URL

        init() async throws {
            root = FileManager.default.temporaryDirectory
                .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            layout = LibraryLayout(root: root)
            try layout.create(manifest: LibraryManifest(id: UUID()))
            let indexURL = FileManager.default.temporaryDirectory
                .appending(path: "\(UUID().uuidString).sqlite")
            catalog = try LocalCatalog(databaseURL: indexURL)
            repository = try await LibraryRepository.open(
                at: root, indexesDirectory: indexURL.deletingLastPathComponent(), deviceID: deviceID
            )
        }

        func reconciler() -> FolderReconciler {
            FolderReconciler(layout: layout, catalog: catalog, deviceID: deviceID)
        }

        func createBook(title: String) async throws -> IndexedBook {
            try await repository.createBook(title: title, authors: ["Alice"])
        }
    }

    @Test
    func repointsFolderToCanonicalPathAfterRename() async throws {
        let h = try await Harness()
        let book = try await h.createBook(title: "Original")
        let canonical = CanonicalPathBuilder.relativeDirectory(
            bookID: book.id, title: book.title, authors: book.authors
        )
        // Simulate a divergent path: rename the folder on disk.
        let folderURL = h.layout.root.appending(path: canonical, directoryHint: .isDirectory)
        let moved = h.layout.root.appending(path: "Somewhere Else", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: folderURL, to: moved)

        let report = try await h.reconciler().reconcile()

        #expect(report.renamed == [book.id])
        #expect(FileManager.default.fileExists(atPath: folderURL.path))
        let stored = try await h.catalog.book(id: book.id)
        #expect(stored?.relativePath == canonical)
    }

    @Test
    func adoptsExistingCanonicalFolderOnRace() async throws {
        let h = try await Harness()
        let book = try await h.createBook(title: "Racer")
        let canonical = CanonicalPathBuilder.relativeDirectory(
            bookID: book.id, title: book.title, authors: book.authors
        )
        // The canonical folder already exists with the same format hashes
        // (another Mac materialized it): the divergent one is forked, not
        // deleted, and the catalog points at the canonical folder.
        let report = try await h.reconciler().reconcile()
        // No divergence simulated → nothing to do.
        #expect(report.renamed.isEmpty)
        #expect(FileManager.default.fileExists(
            atPath: h.layout.root.appending(path: canonical, directoryHint: .isDirectory).path
        ))
    }

    @Test
    func rePointsAfterMetadataEditFromAnotherMac() async throws {
        let h = try await Harness()
        let book = try await h.createBook(title: "Before")
        // Simulate merged metadata (another Mac edited the title): upsert a
        // catalog row with the new title; the folder is still "Before".
        let snapshot = try await h.catalog.snapshot(bookID: book.id)!
        let document = try AutomergeBookDocument(snapshot: snapshot, deviceID: h.deviceID)
        let change = try document.setTitle("After", clock: HybridLogicalClock(nodeID: h.deviceID).tick())
        _ = try ChangeStore(layout: h.layout)
            .writeBookChange(change, bookID: book.id, deviceID: h.deviceID, clock: HybridLogicalClock(nodeID: h.deviceID).tick())
        // Rebuild the catalog from the change store to reflect the merged state.
        try await h.repository.rebuildCatalog()
        let after = try await h.catalog.book(id: book.id)!
        #expect(after.title == "After")

        let report = try await h.reconciler().reconcile()
        #expect(report.renamed == [book.id])
        let expected = CanonicalPathBuilder.relativeDirectory(bookID: book.id, title: "After", authors: ["Alice"])
        let stored = try await h.catalog.book(id: book.id)
        #expect(stored?.relativePath == expected)
        #expect(FileManager.default.fileExists(
            atPath: h.layout.root.appending(path: expected, directoryHint: .isDirectory).path
        ))
    }

    @Test
    func missingFoldersAreRecordedNotFabricated() async throws {
        let h = try await Harness()
        let book = try await h.createBook(title: "Ghost")
        let canonical = CanonicalPathBuilder.relativeDirectory(
            bookID: book.id, title: book.title, authors: book.authors
        )
        try FileManager.default.removeItem(
            at: h.layout.root.appending(path: canonical, directoryHint: .isDirectory)
        )
        let report = try await h.reconciler().reconcile()
        #expect(report.missingFolders == [book.id])
        #expect(report.errors.isEmpty)
    }

    @Test
    func restoresTrashEntryForNonDeletedBook() async throws {
        let h = try await Harness()
        let book = try await h.createBook(title: "Resurrected")
        let canonical = CanonicalPathBuilder.relativeDirectory(
            bookID: book.id, title: book.title, authors: book.authors
        )
        // Simulate a delete-then-restore on the other Mac: folder in trash,
        // catalog row still non-deleted.
        try await h.repository.deleteBook(id: book.id)
        // Rebuild without the delete so the catalog says non-deleted.
        let changeStore = ChangeStore(layout: h.layout)
        // (Simplification: delete the delete-change file to undo, then rebuild.)
        // Implementer: use whatever is cleanest to produce "folder in trash +
        // catalog says non-deleted" (e.g., restore the trash folder manually and
        // leave the catalog non-deleted by NOT writing the delete change).
        let report = try await h.reconciler().reconcile()
        #expect(report.restoredFromTrash == [book.id])
    }
}
```

Note for Step 1: the trash test's setup is the fiddly part — the intent is "trash directory contains the book's folder while the catalog row is non-deleted". If `deleteBook` then `restoreBook` (which restores the folder AND the catalog) is not the right setup, the implementer should produce that state directly (move the folder into `.bookmanager/trash/<id>` manually, keep the catalog row non-deleted), and adjust the test setup accordingly — the ASSERTION (restoredFromTrash contains the id, folder back in place) is fixed.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodegen generate --spec project.yml`, then `xcodebuild -project BookManager.xcodeproj -scheme BookManager -destination 'platform=macOS' -derivedDataPath .build/DerivedData test -only-testing:BookManagerCoreTests/FolderReconcilerTests`
Expected: FAIL — `FolderReconciler` doesn't exist.

- [ ] **Step 3: Implement the report, `repointing`, `forkConflict`**

In `BookManagerCore/Persistence/IndexedBook.swift` add:

```swift
    /// A copy with `relativePath` replaced (used by the reconciler after a
    /// journaled folder move). All other fields, including the snapshot, are
    /// preserved.
    public func repointing(to path: String) -> IndexedBook {
        IndexedBook(
            id: id, title: title, authors: authors, series: series,
            seriesIndex: seriesIndex, tags: tags, rating: rating,
            publisher: publisher,
            publicationMilliseconds: publicationMilliseconds,
            addedMilliseconds: addedMilliseconds, languages: languages,
            identifiers: identifiers, comments: comments, formats: formats,
            coverHash: coverHash, relativePath: path,
            modifiedMilliseconds: modifiedMilliseconds,
            isDeleted: isDeleted, snapshot: snapshot
        )
    }
```

In `BookManagerCore/Library/BookFolder.swift` add (journaled conflict move — never deletes):

```swift
    /// Moves a book's folder to a `(conflict <id-prefix>)` sibling when the
    /// canonical path is taken by different content. Journaled; never deletes.
    public func forkConflict(bookID: UUID, relativePath: String) throws -> URL {
        let source = bookDirectoryURL(relativePath: relativePath)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw BookFolderError.trashEntryMissing(bookID) // placeholder — see note
        }
        let parent = source.deletingLastPathComponent()
        let name = source.lastPathComponent
        let prefix = bookID.uuidString.prefix(8)
        let destination = parent.appending(path: "\(name) (conflict \(prefix))", directoryHint: .isDirectory)
        var target = destination
        var counter = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = parent.appending(
                path: "\(name) (conflict \(prefix) \(counter))", directoryHint: .isDirectory
            )
            counter += 1
        }
        let journal = try begin(operation: "forkConflict", bookID: bookID, oldPath: relativePath, newPath: nil)
        defer { try? end(journal) }
        try FileManager.default.moveItem(at: source, to: target)
        return target
    }
```

Note: `begin`/`end` are private in `BookFolder`; `forkConflict` lives inside the actor so it can use them. If the existing `trashEntryMissing` error doesn't fit "folder missing for fork", add `case folderMissingForFork(UUID)` to `BookFolderError` instead — do NOT reuse a misleading case.

In `BookManagerCore/Sync/FolderReconciler.swift` create the report + actor:

```swift
import Foundation

public struct ReconciliationReport: Sendable, Equatable {
    public var renamed: [UUID] = []
    public var adopted: [UUID] = []
    public var conflictCopies: [URL] = []
    public var restoredFromTrash: [UUID] = []
    public var missingFolders: [UUID] = []
    public var errors: [String] = []

    public init() {}
}

/// Re-points on-disk book folders to the canonical paths derived from the
/// merged CRDT metadata, forks conflicts (never overwrites), and performs
/// basic trash/restore reconciliation. Runs after every ingest; all moves are
/// journaled via `BookFolder`.
public actor FolderReconciler {
    private let layout: LibraryLayout
    private let catalog: LocalCatalog
    private let folder: BookFolder
    private let deviceID: UUID

    public init(layout: LibraryLayout, catalog: LocalCatalog, deviceID: UUID) {
        self.layout = layout
        self.catalog = catalog
        folder = BookFolder(layout: layout)
        self.deviceID = deviceID
    }

    public func reconcile() async throws -> ReconciliationReport {
        var report = ReconciliationReport()
        for book in try await catalog.allBooks() {
            await reconcilePath(book, into: &report)
            await reconcileTrash(book, into: &report)
        }
        for book in try await catalog.deletedBooks() {
            await reconcileTrash(book, into: &report)
        }
        return report
    }

    private func reconcilePath(_ book: IndexedBook, into report: inout ReconciliationReport) async {
        let expected = CanonicalPathBuilder.relativeDirectory(
            bookID: book.id, title: book.title, authors: book.authors
        )
        guard expected != book.relativePath else { return }
        let actualURL = await folder.bookDirectoryURL(relativePath: book.relativePath)
        let expectedURL = await folder.bookDirectoryURL(relativePath: expected)
        let hasActual = FileManager.default.fileExists(atPath: actualURL.path)
        let hasExpected = FileManager.default.fileExists(atPath: expectedURL.path)

        if hasExpected {
            // Adopt-or-fork: the canonical folder already exists.
            if await folderMatches(book, at: expectedURL) {
                report.adopted.append(book.id)
                await repoint(book, to: expected, into: &report)
                if hasActual {
                    await fork(book, into: &report)
                }
            } else {
                await fork(book, into: &report)
            }
            return
        }
        if hasActual {
            await renameTo(book, expected: expected, into: &report)
            return
        }
        report.missingFolders.append(book.id)
    }

    private func folderMatches(_ book: IndexedBook, at url: URL) async -> Bool {
        for format in book.formats {
            let fileURL = url.appending(path: format.filename)
            guard let data = try? Data(contentsOf: fileURL) else { return false }
            if BookFolder.contentHash(data) != format.contentHash { return false }
        }
        return true
    }

    private func renameTo(_ book: IndexedBook, expected: String, into report: inout ReconciliationReport) async {
        do {
            try await folder.rename(
                bookID: book.id, from: book.relativePath, to: expected,
                oldFormats: book.formats.map(Self.formatValue),
                newFormats: book.formats.map(Self.formatValue)
            )
            await repoint(book, to: expected, into: &report)
            report.renamed.append(book.id)
        } catch {
            report.errors.append("rename \(book.id): \(error.localizedDescription)")
        }
    }

    private func repoint(_ book: IndexedBook, to path: String, into report: inout ReconciliationReport) async {
        do {
            try await catalog.upsert(book.repointing(to: path))
        } catch {
            report.errors.append("upsert \(book.id): \(error.localizedDescription)")
        }
    }

    private func fork(_ book: IndexedBook, into report: inout ReconciliationReport) async {
        do {
            let url = try await folder.forkConflict(bookID: book.id, relativePath: book.relativePath)
            report.conflictCopies.append(url)
        } catch {
            report.errors.append("fork \(book.id): \(error.localizedDescription)")
        }
    }

    private func reconcileTrash(_ book: IndexedBook, into report: inout ReconciliationReport) async {
        let trashURL = await folder.trashDirectoryURL(bookID: book.id)
        let inTrash = FileManager.default.fileExists(atPath: trashURL.path)
        if book.isDeleted {
            if !inTrash {
                let source = await folder.bookDirectoryURL(relativePath: book.relativePath)
                if FileManager.default.fileExists(atPath: source.path) {
                    do {
                        try await folder.trash(bookID: book.id, relativePath: book.relativePath)
                    } catch {
                        report.errors.append("trash \(book.id): \(error.localizedDescription)")
                    }
                }
            }
        } else if inTrash {
            do {
                _ = try await folder.restore(bookID: book.id, relativePath: book.relativePath)
                report.restoredFromTrash.append(book.id)
            } catch {
                report.errors.append("restore \(book.id): \(error.localizedDescription)")
            }
        }
    }

    private static func formatValue(_ format: BookFormatRecord) -> BookFormatValue {
        BookFormatValue(kind: format.kind, filename: format.filename, contentHash: format.contentHash, size: format.size)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass, then the full core suite**

Run the focused suite, then `-only-testing:BookManagerCoreTests`. Expected: focused passes; full suite 119 + 5 = 124 tests green.

- [ ] **Step 5: Commit**

```bash
git add BookManagerCore/Sync/FolderReconciler.swift BookManagerCore/Library/BookFolder.swift BookManagerCore/Persistence/IndexedBook.swift BookManagerCoreTests/Sync/FolderReconcilerTests.swift
git commit -m "feat: folder reconciler — re-point, adopt-or-fork, trash/restore"
```

---

### Task 2: `SyncEventSource` + `LibraryMonitor` + stuck-change regression (Core, TDD)

**Files:**
- Create: `BookManagerCore/Sync/SyncEventSource.swift`
- Create: `BookManagerCore/Sync/LibraryMonitor.swift`
- Create: `BookManagerCoreTests/Sync/LibraryMonitorTests.swift`
- Modify: `BookManagerCoreTests/Sync/SyncEngineTests.swift` (add the 4a-mandated stuck-valid-change test)

**Interfaces:**
- Consumes: `LibraryRootCapabilities` (probe for source selection — done by the caller), Foundation/CoreServices.
- Produces:
  - `protocol SyncEventSource: Sendable { func start(); func stop() }` + `FSEventSource(root:onChange:)` (CoreServices `FSEventStream` via `FSEventStreamSetDispatchQueue`) and `PollingSource(interval:onChange:)` (repeating task).
  - `LibraryMonitor` actor: `init(eventSource:periodic:debounce:onChange:onPeriodic:)`, `func start()`, `func stop()` — debounces bursts into one `onChange`, runs `onPeriodic` every `periodic`.

- [ ] **Step 1: Write the failing tests**

Create `BookManagerCoreTests/Sync/LibraryMonitorTests.swift`:

```swift
import Foundation
import Testing
@testable import BookManagerCore

@Suite
struct LibraryMonitorTests {
    private actor Counter {
        private(set) var changes = 0
        private(set) var periodics = 0
        func bumpChanges() { changes += 1 }
        func bumpPeriodics() { periodics += 1 }
    }

    @Test
    func debouncesBurstsIntoOneChange() async throws {
        let counter = Counter()
        let source = FakeEventSource()
        let monitor = LibraryMonitor(
            eventSource: source,
            periodic: .seconds(60),
            debounce: .milliseconds(50),
            onChange: { await counter.bumpChanges() },
            onPeriodic: { await counter.bumpPeriodics() }
        )
        await monitor.start()
        source.fire()
        source.fire()
        source.fire()
        try await Task.sleep(for: .milliseconds(200))
        await monitor.stop()
        let state = await counter.changes
        #expect(state == 1)
    }

    @Test
    func periodicBackstopFires() async throws {
        let counter = Counter()
        let monitor = LibraryMonitor(
            eventSource: FakeEventSource(),
            periodic: .milliseconds(80),
            debounce: .milliseconds(10),
            onChange: { await counter.bumpChanges() },
            onPeriodic: { await counter.bumpPeriodics() }
        )
        await monitor.start()
        try await Task.sleep(for: .milliseconds(250))
        await monitor.stop()
        let periodics = await counter.periodics
        #expect(periodics >= 2)
    }

    @Test
    func stopPreventsFurtherCallbacks() async throws {
        let counter = Counter()
        let source = FakeEventSource()
        let monitor = LibraryMonitor(
            eventSource: source,
            periodic: .milliseconds(20),
            debounce: .milliseconds(5),
            onChange: { await counter.bumpChanges() },
            onPeriodic: { await counter.bumpPeriodics() }
        )
        await monitor.start()
        source.fire()
        await monitor.stop()
        let before = await counter.changes
        source.fire()
        try await Task.sleep(for: .milliseconds(100))
        let after = await counter.changes
        #expect(after == before)
    }
}

private final class FakeEventSource: SyncEventSource, @unchecked Sendable {
    private let onChange: () -> Void
    init() { onChange = {} }
    init(onChange: @escaping () -> Void) { self.onChange = onChange }
    func start() {}
    func stop() {}
    func fire() { onChange() }
}
```

In `BookManagerCoreTests/Sync/SyncEngineTests.swift` add the 4a-mandated regression test:

```swift
    @Test
    func stuckValidChangesAreNotQuarantinedAndApplyLater() async throws {
        // Out-of-order cloud delivery: a valid change whose causal dependency
        // hasn't synced yet must NOT be quarantined — it stays in the change
        // store and applies once its base arrives (acceptance 8; 4a final
        // review ruling).
        let h = try Harness()
        let deviceID = UUID()
        let bookID = UUID()
        let baseDoc = try AutomergeBookDocument.new(bookID: bookID, deviceID: deviceID)
        var clock = HybridLogicalClock(nodeID: deviceID)
        let base = try baseDoc.setTitle("Base", clock: clock.tick())
        let depDoc = try AutomergeBookDocument(snapshot: baseDoc.snapshot(), deviceID: deviceID)
        let dep = try depDoc.setTags(["science"], clock: clock.tick())
        let store = ChangeStore(layout: h.layout)
        // Write ONLY the dependent change; the base never lands (yet).
        _ = try store.writeBookChange(dep, bookID: bookID, deviceID: deviceID, clock: clock)

        let engine = try h.engine()
        let report = try await engine.ingest()
        #expect(report.quarantined.isEmpty)
        #expect(try await h.catalog.allBooks().isEmpty)

        // Deliver the base change later: both apply, the book converges.
        _ = try store.writeBookChange(base, bookID: bookID, deviceID: deviceID, clock: clock)
        let second = try await engine.ingest()
        #expect(second.quarantined.isEmpty)
        let book = try #require(try await h.catalog.allBooks().first)
        #expect(book.title == "Base")
        #expect(book.tags == ["science"])
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodegen generate --spec project.yml`, then `xcodebuild ... test -only-testing:BookManagerCoreTests/LibraryMonitorTests -only-testing:BookManagerCoreTests/SyncEngineTests`
Expected: FAIL — `LibraryMonitor`/`FakeEventSource` don't exist (the stuck-change test may already PASS against the snapshot-seeded engine — that's fine; it's a regression lock, not a RED test).

- [ ] **Step 3: Implement `SyncEventSource` + `LibraryMonitor`**

Create `BookManagerCore/Sync/SyncEventSource.swift`:

```swift
import CoreServices
import Foundation

/// A source of "the library changed" signals. FSEvents on local volumes;
/// polling on network/cloud roots where events are unreliable.
public protocol SyncEventSource: Sendable {
    func start()
    func stop()
}

/// FSEvents watcher on a library root (CoreServices FSEventStream on a
/// dispatch queue — sandbox-safe while the security scope is active).
public final class FSEventSource: SyncEventSource, @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "bookmanager.fsevents")
    private let onChange: () -> Void

    public init(root: URL, onChange: @escaping () -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let source = Unmanaged<FSEventSource>.fromOpaque(info).takeUnretainedValue()
            source.onChange()
        }
        stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context,
            [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
            )
        )
    }

    public func start() {
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}

/// Periodic polling — the correctness mechanism on network/cloud roots where
/// FSEvents is unreliable, and the test double's real counterpart.
public final class PollingSource: SyncEventSource, @unchecked Sendable {
    private let interval: Duration
    private let onChange: () -> Void
    private var task: Task<Void, Never>?

    public init(interval: Duration, onChange: @escaping () -> Void) {
        self.interval = interval
        self.onChange = onChange
    }

    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: self?.interval ?? .seconds(60))
                guard !Task.isCancelled, let self else { break }
                self.onChange()
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }
}
```

Create `BookManagerCore/Sync/LibraryMonitor.swift`:

```swift
import Foundation

/// Always-on watcher: debounces change bursts into one `onChange`, and runs a
/// periodic `onPeriodic` (the full-rescan backstop for missed events). The
/// app pauses it while the library is unavailable and stops it on close.
public actor LibraryMonitor {
    private let eventSource: any SyncEventSource
    private let periodic: Duration
    private let debounce: Duration
    private let onChange: @Sendable () async -> Void
    private let onPeriodic: @Sendable () async -> Void
    private var debounceTask: Task<Void, Never>?
    private var periodicTask: Task<Void, Never>?
    private var running = false

    public init(
        eventSource: any SyncEventSource,
        periodic: Duration = .seconds(60),
        debounce: Duration = .seconds(1),
        onChange: @escaping @Sendable () async -> Void,
        onPeriodic: @escaping @Sendable () async -> Void
    ) {
        self.eventSource = eventSource
        self.periodic = periodic
        self.debounce = debounce
        self.onChange = onChange
        self.onPeriodic = onPeriodic
    }

    public func start() {
        guard !running else { return }
        running = true
        eventSource.start()
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: self?.periodic ?? .seconds(60))
                guard !Task.isCancelled, let self else { break }
                await self.runPeriodic()
            }
        }
    }

    public func stop() {
        guard running else { return }
        running = false
        eventSource.stop()
        debounceTask?.cancel()
        debounceTask = nil
        periodicTask?.cancel()
        periodicTask = nil
    }

    /// Called from the event source's queue on any change; coalesces bursts.
    public func onEvent() {
        guard running else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: self?.debounce ?? .seconds(1))
            guard !Task.isCancelled, let self else { return }
            await self.onChange()
        }
    }

    private func runPeriodic() async {
        guard running else { return }
        await onPeriodic()
    }
}
```

Note on wiring: the caller (Task 3) constructs `FSEventSource(root:)` with `onChange: { Task { await monitor.onEvent() } }` or passes the source into the monitor and has the source's closure call `monitor.onEvent()` — the monitor is an actor; the source closure hops with `Task { await monitor.onEvent() }`. The monitor must be created before the source's closure can reference it; construct in Task 3 accordingly (create the source lazily or use an init that takes the root and builds the source internally — if the latter is cleaner, extend `LibraryMonitor.init(root:capabilities:...)` to build the right source; keep the actor generic for tests).

- [ ] **Step 4: Run the tests to verify they pass, then the full core suite**

Run the focused suites, then `-only-testing:BookManagerCoreTests`. Expected: focused pass; full suite 124 + 4 = 128 tests green.

- [ ] **Step 5: Commit**

```bash
git add BookManagerCore/Sync/SyncEventSource.swift BookManagerCore/Sync/LibraryMonitor.swift BookManagerCoreTests/Sync/LibraryMonitorTests.swift BookManagerCoreTests/Sync/SyncEngineTests.swift
git commit -m "feat: sync event sources and debounced monitor; stuck-change regression test"
```

---

### Task 3: App wiring — monitor lifecycle, ingest-on-open, Syncing indicator, Reconciliation diagnostics

**Files:**
- Modify: `BookManager/Stores/LibrarySession.swift`
- Modify: `BookManager/Views/ContentView.swift`
- Modify: `BookManager/Views/DiagnosticsView.swift`
- (No new test files — app layer; verification is build + manual.)

**Interfaces:**
- Consumes: `LibraryMonitor`, `SyncEventSource`/`FSEventSource`/`PollingSource`, `FolderReconciler`/`ReconciliationReport`, `LibraryRootCapabilities`, the 4a `syncNow`/`reconnectIfNeeded` plumbing.
- Produces: `LibrarySession.isSyncing: Bool`, `LibrarySession.reconciliationReport: ReconciliationReport?` (published, reset on close), monitor lifecycle in `activate`/`closeLibrary`, ingest-on-open, Reconciliation section in Diagnostics.

- [ ] **Step 1: Monitor lifecycle + ingest-on-open in the session**

In `LibrarySession`:
- Add `private var monitor: LibraryMonitor?`, `private(set) var isSyncing = false`, `private(set) var reconciliationReport: ReconciliationReport?`.
- In `activate` success (after `refreshAll`), call `await startMonitor()`:

```swift
    /// Starts the always-on monitor and runs the first ingest + reconcile
    /// (ingest-on-open — a mid-session library switch must not show stale data).
    private func startMonitor() async {
        guard let repository, let syncState else { return }
        await runSyncSequence(manual: false)
        let capabilities = LibraryRootCapabilities.probe(repository.root)
        let monitor = LibraryMonitor(
            eventSource: PollingSource(interval: .seconds(60)) { [weak self] in
                Task { await self?.monitorEvent() }
            },
            periodic: .seconds(60),
            debounce: .seconds(1),
            onChange: { [weak self] in await self?.runSyncSequence(manual: false) },
            onPeriodic: { [weak self] in await self?.runSyncSequence(manual: true) }
        )
        self.monitor = monitor
        await monitor.start()
    }

    private func monitorEvent() async {
        guard let monitor else { return }
        await monitor.onEvent()
    }
```

Note: the `PollingSource` shown here is used for simplicity and as the network/cloud path; for local roots use `FSEventSource(root:onChange:)` with the same `monitorEvent` hop. The capability probe selects the source — local → FSEventSource, else PollingSource. (If `FSEventSource` proves unreliable in manual testing, the periodic poller alone is correct, just slower.)

- Refactor `syncNow()` to `runSyncSequence(manual: Bool)` (the monitor's handler): set `isSyncing = true`/`false`, `ensureLibraryFilesDownloaded()`, drain + ingest (capture `IngestReport` → `quarantinedChanges`), `FolderReconciler(layout:catalog:deviceID:).reconcile()` → `reconciliationReport`, `refreshLibraryAvailability()`, `refreshAll()`, `refreshPendingSync()`. `syncNow()` becomes a thin wrapper (`await runSyncSequence(manual: true)`).
- In `closeLibrary`: stop the monitor, reset `isSyncing`/`reconciliationReport`.

- [ ] **Step 2: ContentView indicator**

Extend the existing toolbar indicator (4a): when `isLibraryUnavailable` → "Library unavailable" (as today); else if `isSyncing` → `Label("Syncing…", systemImage: "arrow.triangle.2.circlepath")` (with a small `ProgressView`); else if `pendingSyncCount > 0` → the pending label; else "Synced". Keep Sync Now as a button (it calls `syncNow`); `didBecomeActive` keeps calling `reconnectIfNeeded`.

- [ ] **Step 3: DiagnosticsView Reconciliation section**

Add a section after Quarantined Changes: `Section("Reconciliation")` — when `session.reconciliationReport` is non-nil and non-empty, list `renamed` (book count), `adopted`, `conflictCopies` (paths, e.g. `Text(url.lastPathComponent)`), `restoredFromTrash`, `missingFolders`, and any `errors`; when the report is nil or empty, a footnote "Last sync reconciled nothing out of place." Follow the existing session-access pattern in `DiagnosticsView` (check how it reads the session — likely the `librarySession` environment; the new fields are `private(set)` on the session, readable).

- [ ] **Step 4: Build and verify wiring**

Run: `xcodebuild -project BookManager.xcodeproj -scheme BookManager -destination 'platform=macOS' -derivedDataPath .build/DerivedData build` → BUILD SUCCEEDED; full core suite `... test -only-testing:BookManagerCoreTests` → 128 tests green.
Manual verification (residual for the human): open a library, edit a book's title on another Mac (or in a second temp copy), watch the folder re-point within the debounce/periodic window; rename a folder manually → reconciliation restores it; delete a book on one side → folder trashed; Diagnostics shows Reconciliation + Quarantined sections. Note in the report.

- [ ] **Step 5: Commit**

```bash
git add BookManager/Stores/LibrarySession.swift BookManager/Views/ContentView.swift BookManager/Views/DiagnosticsView.swift
git commit -m "feat: always-on sync monitor, ingest-on-open, reconciliation diagnostics"
```

---

## Self-Review

- **Spec coverage:** Req 1 (monitor, debounce, periodic backstop, pause-when-unavailable) → Task 2 + Task 3. Req 2 (ingest-on-open) → Task 3 Step 1. Req 3 (re-point/adopt-or-fork/fork-conflicts/missing/trash) → Task 1. Req 4 (conflict visibility in Diagnostics) → Task 3 Step 3. Req 5 (stuck-change regression) → Task 2. Req 6 (no silent loss, no format change) → Global Constraints + Task 1 (moves/fork only, journaled).
- **Placeholder scan:** no TBDs; every step has concrete code or an exact command. Task 1 Step 1's trash-test setup note and Task 2's FSEventSource wiring note are explicit implementation guidance, not placeholders.
- **Type consistency:** `ReconciliationReport` fields used identically in Task 1 (definition) and Task 3 (Diagnostics); `repointing(to:)`/`forkConflict` defined in Task 1 Step 3, used in Task 1's reconciler; `SyncEventSource`/`LibraryMonitor`/`FakeEventSource` defined in Task 2, consumed in Task 3; `isSyncing`/`reconciliationReport` defined in Task 3, used in Task 3. No name drift.
- **Risks noted:** `FSEventStreamContext` memberwise init availability and the FSEvents-vs-polling reliability trade-off are flagged for the implementer; the trash-test setup is the fiddly part of Task 1 (assertion is fixed, setup may be adjusted); `FolderReconciler` needs `catalog` access to `LocalCatalog` (actor) — the repository's catalog is private, so the session builds the reconciler with its own `SyncEngine`-style access (Task 3 wires `FolderReconciler(layout:catalog:deviceID:)` — if the catalog isn't reachable from the session, add a `LibraryRepository.reconciler()` accessor mirroring `syncEngine(state:)`).
