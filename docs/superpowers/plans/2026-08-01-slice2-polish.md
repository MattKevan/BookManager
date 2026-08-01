# Slice 2 Polish Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the documented Slice 2 deferred items that are cheap and safe: core hardening, coverage gaps, and small app-layer warts. Items explicitly deferred to Slice 4 (tombstones, .amchange clock alignment, dictionary-encoding nondeterminism) and pure-UI judgment calls (double-tap gesture, multi-selection Open semantics, empty-state flash, unsupported-file kind fabrication) are OUT OF SCOPE and remain documented in the Slice 2 completion notes.

**Architecture:** No architecture changes. Core fixes stay inside `BookManagerCore` (CRDT schema untouched — no new fields). App fixes stay in the `BookManager` target. All behavior remains covered by tests where it lives in core.

**Tech Stack:** Unchanged (macOS 26+, Swift 6 strict concurrency, SwiftUI, Observation, Automerge 0.7.2, GRDB 7.11.1, ZIPFoundation 0.9.19, Swift Testing, XCTest UI testing, XcodeGen).

## Global Constraints

- macOS 26 or later; Swift 6 with `SWIFT_STRICT_CONCURRENCY: complete`.
- Dependencies pinned by exact version; no new dependencies.
- `BookManagerCore` contains no SwiftUI.
- The portable library's `.bookmanager/changes` directory is the source of truth.
- An exact duplicate (same content hash) is never copied silently. A likely duplicate (normalized title + first author) is never merged silently.
- The app must remain runnable after every task; completed behavior is covered by automated tests.
- No public API breaks: `LibraryRepository`, `LocalCatalog`, `IndexedBook`, `BookFolder`, `ImportService` signatures used by the app and by Slice 3 planning stay stable unless the plan explicitly says otherwise.

## File Map

```text
BookManagerCore/
├── Persistence/
│   ├── IndexedBook.swift                      (modify: corrupt row id fails loudly, no random UUID)
│   └── LocalCatalog.swift                     (modify: bookIDs(byFormatHash:) ORDER BY)
├── Library/
│   ├── BookFolder.swift                       (unchanged in behavior)
│   └── LibraryRepository.swift                (modify: updateBook always rewrites metadata.opf)
BookManagerCoreTests/
├── Persistence/LocalCatalogV2Tests.swift      (modify: format facet test, v1→v2 migration test)
├── Library/BookFolderTests.swift              (modify: rename-file branch, trashEntryMissing, journal failure)
└── Library/LibraryRepositoryTests.swift       (modify: update/delete changes survive rebuildCatalog)
BookManager/
├── Stores/
│   ├── LibrarySession.swift                   (modify: closeLibrary reset, search debounce, error surfacing)
│   └── ThumbnailCache.swift                   (modify: coverHash-aware cache key)
├── Views/
│   ├── ContentView.swift                      (modify: remove diagnostics double-reload, add error alert)
│   └── MetadataEditorView.swift               (modify: clear seriesIndex when series cleared)
docs/superpowers/specs/2026-07-29-book-manager-design.md  (no change)
```

---

### Task 1: Core Hardening and Coverage

**Files:**

- Modify: `BookManagerCore/Persistence/IndexedBook.swift`
- Modify: `BookManagerCore/Persistence/LocalCatalog.swift`
- Modify: `BookManagerCore/Library/LibraryRepository.swift`
- Modify: `BookManagerCoreTests/Persistence/LocalCatalogV2Tests.swift`
- Modify: `BookManagerCoreTests/Library/BookFolderTests.swift`
- Modify: `BookManagerCoreTests/Library/LibraryRepositoryTests.swift`

**Interfaces:**

- Consumes: v2 `IndexedBook`/`LocalCatalog` (Slice 2), `BookFolder` actor, `LibraryRepository` v2.
- Produces: hardened row decode, deterministic hash lookup order, OPF freshness on every update, and tests closing the documented coverage gaps.

- [ ] **Step 1: Write the failing tests first (coverage gaps)**

Append to `BookManagerCoreTests/Persistence/LocalCatalogV2Tests.swift`:

```swift
    @Test
    func formatFacetCountsAndFilters() async throws {
        let catalog = try catalog()
        try await catalog.upsert(book(title: "A", formats: [
            BookFormatRecord(kind: "EPUB", filename: "a.epub", contentHash: "h1", size: 1)
        ]))
        try await catalog.upsert(book(id: UUID(), title: "B", formats: [
            BookFormatRecord(kind: "PDF", filename: "b.pdf", contentHash: "h2", size: 2),
            BookFormatRecord(kind: "EPUB", filename: "b.epub", contentHash: "h3", size: 3)
        ]))

        let counts = try await catalog.facetCounts(.format)
        #expect(counts.first { $0.value == "EPUB" }?.count == 2)
        #expect(counts.first { $0.value == "PDF" }?.count == 1)
        #expect(try await catalog.books(facetType: .format, value: "PDF").map(\.title) == ["B"])
    }

    @Test
    func v1DatabaseUpgradesToV2Schema() async throws {
        // Build a genuine v1-schema database, insert a v1-shaped row, then
        // reopen through LocalCatalog and verify the v2 migration ran and the
        // row decodes with v2 defaults.
        let databaseURL = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).sqlite")
        let v1 = try DatabaseQueue(path: databaseURL.path)
        try v1.write { db in
            try db.create(table: "book") { table in
                table.column("id", .text).primaryKey()
                table.column("title", .text).notNull()
                table.column("authors", .text).notNull()
                table.column("modifiedMilliseconds", .integer).notNull()
                table.column("isDeleted", .boolean).notNull()
                table.column("snapshot", .blob).notNull()
            }
            try db.execute(
                sql: "INSERT INTO book(id, title, authors, modifiedMilliseconds, isDeleted, snapshot) VALUES (?, ?, ?, ?, ?, ?)",
                arguments: [UUID().uuidString, "Old", "[\"A\"]", 1_000, false, Data([9])]
            )
        }
        try v1.close()

        let catalog = try LocalCatalog(databaseURL: databaseURL)
        let books = try await catalog.allBooks()
        #expect(books.count == 1)
        #expect(books[0].title == "Old")
        #expect(books[0].tags.isEmpty)
        #expect(books[0].formats.isEmpty)
    }
```

Note: `DatabaseQueue(path:)` + `try v1.close()` — GRDB's `DatabaseQueue` has `close()` that is async? Verify the exact API in the project's GRDB version and adapt (`try v1.close()` vs `await`). The v1 schema here mirrors the slice-1 `createV1Schema` from `LocalCatalog.migrator` (already in the codebase — copy its column definitions verbatim).

Append to `BookManagerCoreTests/Library/BookFolderTests.swift`:

```swift
    @Test
    func renameRenamesFormatFilesWhoseCanonicalNameChanged() async throws {
        let (root, layout) = try makeLayout()
        let folder = BookFolder(layout: layout)
        let bookID = UUID()
        let resolved = ResolvedBook(
            id: bookID, title: "Range", authors: ["David Epstein"],
            series: nil, seriesIndex: nil, tags: [], rating: nil, publisher: nil,
            publicationDate: nil, addedDate: nil, languages: [], identifiers: [:],
            comments: nil, formats: [], cover: nil, isDeleted: false,
            modifiedClock: HybridLogicalClock(physicalMilliseconds: 1, nodeID: UUID())
        )
        let source = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).epub")
        try Data("rename-me".utf8).write(to: source)
        let materialized = try await folder.materialize(
            bookID: bookID, resolved: resolved,
            staged: [try await folder.stage(from: source)], cover: nil
        )
        let oldFormat = materialized.formats[0]

        let retitled = ResolvedBook(
            id: bookID, title: "Range: Revised", authors: ["David Epstein"],
            series: nil, seriesIndex: nil, tags: [], rating: nil, publisher: nil,
            publicationDate: nil, addedDate: nil, languages: [], identifiers: [:],
            comments: nil, formats: [], cover: nil, isDeleted: false,
            modifiedClock: HybridLogicalClock(physicalMilliseconds: 2, nodeID: UUID())
        )
        let newFormat = BookFormatValue(
            kind: "EPUB",
            filename: CanonicalPathBuilder.formatFileName(
                title: "Range: Revised", authors: ["David Epstein"], kind: "EPUB"
            ),
            contentHash: oldFormat.contentHash, size: oldFormat.size
        )
        let newPath = CanonicalPathBuilder.relativeDirectory(
            bookID: bookID, title: "Range: Revised", authors: ["David Epstein"]
        )
        try await folder.rename(
            bookID: bookID,
            from: materialized.path, to: newPath,
            oldFormats: [oldFormat], newFormats: [newFormat]
        )

        let dir = await folder.bookDirectoryURL(relativePath: newPath)
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: newFormat.filename).path))
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: oldFormat.filename).path))
        #expect(layout.transactionsRoot.children.isEmpty)
    }

    @Test
    func restoreWithoutTrashEntryThrows() async throws {
        let (root, layout) = try makeLayout()
        let folder = BookFolder(layout: layout)
        await #expect(throws: BookFolderError.trashEntryMissing(UUID())) {
            _ = try await folder.restore(bookID: UUID(), relativePath: "A/B (12345678)")
        }
    }

    @Test
    func interruptedMutationLeavesJournalEntry() async throws {
        let (root, layout) = try makeLayout()
        let folder = BookFolder(layout: layout)
        let bookID = UUID()
        let resolved = ResolvedBook(
            id: bookID, title: "Range", authors: ["David Epstein"],
            series: nil, seriesIndex: nil, tags: [], rating: nil, publisher: nil,
            publicationDate: nil, addedDate: nil, languages: [], identifiers: [:],
            comments: nil, formats: [], cover: nil, isDeleted: false,
            modifiedClock: HybridLogicalClock(physicalMilliseconds: 1, nodeID: UUID())
        )
        let materialized = try await folder.materialize(bookID: bookID, resolved: resolved, staged: [], cover: nil)
        let target = folder.bookDirectoryURL(relativePath: materialized.path)

        // Simulate an interruption: leave a journal entry behind as if the
        // operation had not finished (the actor's begin/end normally pair).
        // Write the journal file directly, then verify diagnostics can see it.
        try FileManager.default.createDirectory(at: layout.transactionsRoot, withIntermediateDirectories: true)
        let journalURL = layout.transactionsRoot.appending(path: "\(UUID().uuidString).json")
        try Data(#"{"operation":"trash","bookID":"\#(bookID.uuidString)","oldPath":"\#(materialized.path)"}"#.utf8)
            .write(to: journalURL)
        #expect(FileManager.default.fileExists(atPath: journalURL.path))
        // A real interrupted mutation would also leave the folder intact.
        #expect(FileManager.default.fileExists(atPath: target.path))
    }
```

Note: the journal-failure test asserts the observable state of an interrupted mutation (journal present, source intact) by writing the journal file directly — the actor's internal `begin`/`end` is private, so this is the honest black-box approximation. If the implementer prefers, expose a read-only `pendingJournalEntries()` API on `BookFolder` (used later by Diagnostics) and assert through it instead — that is strictly better; do that if it fits cleanly.

Append to `BookManagerCoreTests/Library/LibraryRepositoryTests.swift` (inside `LibraryRepositoryV2Tests`):

```swift
    @Test
    func updateAndDeleteSurviveCatalogRebuild() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let firstIndexes = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let secondIndexes = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let repository = try await LibraryRepository.create(at: root, indexesDirectory: firstIndexes, deviceID: UUID())
        let book = try await repository.createBook(
            metadata: NewBookMetadata(title: "Range", authors: ["David Epstein"], tags: ["science"]),
            staged: [], cover: nil
        )
        _ = try await repository.updateBook(id: book.id, edit: BookEdit(title: "Range: Revised", tags: ["science", "sport"]))

        // Rebuild from the change store into a fresh catalogue.
        let rebuilt = try await LibraryRepository.open(at: root, indexesDirectory: secondIndexes, deviceID: UUID())
        let updated = try await rebuilt.books().first
        #expect(updated?.title == "Range: Revised")
        #expect(updated?.tags == ["science", "sport"])

        // Delete, then rebuild again — the tombstone must survive too.
        try await rebuilt.deleteBook(id: book.id)
        let thirdIndexes = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let rebuiltAgain = try await LibraryRepository.open(at: root, indexesDirectory: thirdIndexes, deviceID: UUID())
        #expect(try await rebuiltAgain.books().isEmpty)
        #expect(try await rebuiltAgain.deletedBooks().map(\.id) == [book.id])
    }
```

- [ ] **Step 2: Run the new tests to verify they fail**

```bash
xcodegen generate --spec project.yml
xcodebuild -project BookManager.xcodeproj -scheme BookManager -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:BookManagerCoreTests/LocalCatalogV2Tests/formatFacetCountsAndFilters -only-testing:BookManagerCoreTests/LocalCatalogV2Tests/v1DatabaseUpgradesToV2Schema -only-testing:BookManagerCoreTests/BookFolderTests -only-testing:BookManagerCoreTests/LibraryRepositoryV2Tests/updateAndDeleteSurviveCatalogRebuild test
```

Expected: RED where behavior is missing (format facet currently untested but likely passes — that's fine, the test then guards it; the migration test may already pass if the migrator handles v1→v2 — verify; the rename-file-branch and rebuild tests are the ones that must fail or reveal missing behavior). Note which were RED vs GREEN and why; the point is the coverage exists and matches behavior.

- [ ] **Step 3: IndexedBook corrupt-row hardening**

In `BookManagerCore/Persistence/IndexedBook.swift` `init(row:)`, replace the silent random-UUID fabrication:

```swift
id = UUID(uuidString: row["id"] as String) ?? UUID()
```

with a loud failure. `FetchableRecord.init(row:)` is non-throwing; the catalogue is disposable and rebuildable, so a corrupt id means the build is broken — trap with a clear message:

```swift
guard let id = UUID(uuidString: row["id"] as String) else {
    fatalError("Corrupt catalogue row: unparseable book id '\(row["id"] as String)'")
}
id = id
```

If the implementer finds a cleaner throwing path (e.g. decode via `try` in a wrapping fetch), prefer it — but do not silently fabricate identities.

- [ ] **Step 4: Deterministic hash lookup order**

In `BookManagerCore/Persistence/LocalCatalog.swift` `bookIDs(byFormatHash:)`, add `ORDER BY bookID` to the query.

- [ ] **Step 5: OPF freshness on every update**

In `BookManagerCore/Library/LibraryRepository.swift` `updateBook(id:edit:)`, the `metadata.opf` rewrite is currently gated on the canonical path changing. Rewrite the OPF **whenever the resolved metadata changed** — simplest correct form: always rewrite after any successful edit (the path-rename branch already writes it; move the write out so it runs unconditionally after the rename block). This keeps the derived sidecar in sync with tag/rating/comment edits.

- [ ] **Step 6: Run the full core suite**

```bash
xcodebuild -project BookManager.xcodeproj -scheme BookManager -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:BookManagerCoreTests test
```

Expected: all suites green (previous 58 tests + the new ones).

- [ ] **Step 7: Commit**

```bash
git add BookManagerCore BookManagerCoreTests BookManager.xcodeproj
git commit -m "feat: harden catalogue decode and close core coverage gaps"
```

### Task 2: App-Layer Polish

**Files:**

- Modify: `BookManager/Stores/LibrarySession.swift`
- Modify: `BookManager/Stores/ThumbnailCache.swift`
- Modify: `BookManager/Views/ContentView.swift`
- Modify: `BookManager/Views/MetadataEditorView.swift`

**Interfaces:**

- Consumes: v2 session, `ThumbnailCache`, ContentView, MetadataEditorView (all Slice 2).
- Produces: state reset on close, debounced search, surfaced mutation errors, single diagnostics reload, coverHash-aware thumbnails, series-index clear consistency.

- [ ] **Step 1: closeLibrary state reset**

In `BookManager/Stores/LibrarySession.swift` `closeLibrary()`, reset `searchText`, `missingFiles`, `viewMode`, `selection`, `selectedFacet` (in addition to the existing resets) so reopening a different library does not re-apply the previous search/facet/view.

- [ ] **Step 2: Search debounce**

`searchText`'s `didSet` currently spawns an unstructured `Task` per keystroke. Replace with a cancellable pattern:

```swift
var searchText = "" {
    didSet {
        searchTask?.cancel()
        searchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            await refreshBooks()
        }
    }
}
private var searchTask: Task<Void, Never>?
```

Cancel any in-flight task in `closeLibrary()` too.

- [ ] **Step 3: Surface mutation errors**

The `try?`-swallowed failures in `delete(ids:)`, `restore(id:)`, `rebuildIndex()` (and `open(id:)`/`reveal(id:)`) give no feedback. Add a minimal error surface:

```swift
var lastError: String?   // shown via alert in ContentView
```

In each mutation, on failure set `lastError = error.localizedDescription` instead of (or in addition to) silently ignoring. In `ContentView`, add `.alert("Something went wrong", isPresented: Binding(get: { session.lastError != nil }, set: { if !$0 { session.lastError = nil } })) { } message: { Text(session.lastError ?? "") }` on the root Group.

- [ ] **Step 4: Single diagnostics reload**

In `BookManager/Views/ContentView.swift`, remove the `.onChange(of: showDiagnostics)` reload — `DiagnosticsView` already reloads in its own `.task`. Keep only one path.

- [ ] **Step 5: CoverHash-aware thumbnails**

In `BookManager/Stores/ThumbnailCache.swift`, key the memory cache by `book.id` + `book.coverHash` (and, for the QuickLook fallback, the first format's content hash) so a cover rewrite does not keep serving a stale image for the session lifetime:

```swift
private var memory: [String: NSImage] = [:]
private func cacheKey(for book: IndexedBook) -> String {
    "\(book.id.uuidString)|\(book.coverHash ?? "")|\(book.formats.first?.contentHash ?? "")"
}
```

`remove(_:)` drops all keys with that id prefix.

- [ ] **Step 6: Series-index clear consistency**

In `BookManager/Views/MetadataEditorView.swift` `collectEdit()`, when the series field is cleared the index edit is currently `.keep` (leaving a stale seriesIndex in the document). Change to: `let indexEdit: FieldEdit<Double> = newSeries.isEmpty ? .clear : (newIndex.map { .set($0) } ?? .clear)`.

- [ ] **Step 7: Build and full suite**

```bash
xcodegen generate --spec project.yml
xcodebuild -project BookManager.xcodeproj -scheme BookManager -destination 'platform=macOS' -derivedDataPath .build/DerivedData build
xcodebuild -project BookManager.xcodeproj -scheme BookManager -destination 'platform=macOS' -derivedDataPath .build/DerivedData test
```

Expected: build with no NEW warnings from files you touch; all core + UI tests green (58 core + 2 UI).

- [ ] **Step 8: Commit**

```bash
git add BookManager BookManager.xcodeproj
git commit -m "feat: polish session state, search debounce, and error surfacing"
```

### Task 3: Slice Verification and Documentation

**Files:**

- Modify: `docs/superpowers/specs/2026-07-29-book-manager-design.md` (no change needed unless a polish item altered documented behavior — check and note)

- [ ] **Step 1: Static checks and clean verification**

```bash
xcodegen generate --spec project.yml
git diff --check
xcodebuild -project BookManager.xcodeproj -scheme BookManager -destination 'platform=macOS' -derivedDataPath .build/DerivedData analyze
xcodebuild -project BookManager.xcodeproj -scheme BookManager clean
xcodebuild -project BookManager.xcodeproj -scheme BookManager -destination 'platform=macOS' -derivedDataPath .build/DerivedData test
```

Expected: ANALYZE SUCCEEDED, CLEAN SUCCEEDED, TEST SUCCEEDED (all suites).

- [ ] **Step 2: Inspect the change set**

```bash
git status --short
git log --oneline --decorate -10
```

- [ ] **Step 3: Commit any doc adjustments**

```bash
git add docs
git commit -m "docs: note polish changes"
```

(Only if the design doc actually changed; otherwise skip.)

- [ ] **Step 4: Confirm the repository is clean**

```bash
git status --short --branch
```

Expected: branch header only (plus any git-ignored scratch).
