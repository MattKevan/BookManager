# Performance (Slice 4c, Plan A) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** the app stays responsive at 10,000 books — batch catalog writes (10k per-book transactions → 1), O(N + dirs) reconciler discovery via a folder index, a cancellable progress-reporting rebuild, and a CI-safe 10k benchmark suite.

**Architecture:** `LocalCatalog` gains `upsertBatch(_:)` (one SQLite transaction) and the per-book body is extracted so `rebuildCatalog`/`SyncEngine.ingest` batch. `FolderReconciler` builds a short-ID → folder-URL index from ONE root scan per pass. `LibraryRepository.rebuildCatalog` gains `progress`/`cancelled` closures (defaults keep existing callers) and throws `rebuildCancelled`; the session/Diagnostics wire a progress bar + Cancel. `PerformanceTests` seeds 10k books directly and asserts generous CI-safe bounds.

**Tech Stack:** Swift 6.0 (strict concurrency), GRDB, Swift Testing, XcodeGen.

## Global Constraints

- macOS 26; Swift 6.0 with `SWIFT_STRICT_CONCURRENCY: complete`; Core actors.
- **No change-store format change; no behavior change** — batching/indexing are pure performance refactors; existing tests (131/25 baseline, main `6ff71ef`) stay green and are the correctness proof.
- CI-safe benchmark bounds (generous, warm-up-tolerant): `allBooks` < 1s, `search` < 250ms, `facetCounts` < 1s at 10k.
- Tests: Swift Testing; xcodebuild with `-derivedDataPath .build/DerivedData`; run `xcodegen generate --spec project.yml` before building new files; suite-level `-only-testing`.

---

### Task 1: Batch catalog writes (Core, TDD)

**Files:**
- Modify: `BookManagerCore/Persistence/LocalCatalog.swift`
- Modify: `BookManagerCore/Library/LibraryRepository.swift` (`rebuildCatalog` batches)
- Modify: `BookManagerCore/Sync/SyncEngine.swift` (`ingest` batches)
- Create: `BookManagerCoreTests/Persistence/LocalCatalogBatchTests.swift`

**Interfaces:**
- Consumes: the existing `LocalCatalog.upsert` body (extracted per-book), `IndexedBook`, `JSONCoding`.
- Produces: `LocalCatalog.upsertBatch(_ books: [IndexedBook]) throws` (one `database.write` transaction for all books; the existing `upsert(_ book:)` keeps its signature).

- [ ] **Step 1: Write the failing tests**

Create `BookManagerCoreTests/Persistence/LocalCatalogBatchTests.swift`:

```swift
import Foundation
import Testing
@testable import BookManagerCore

@Suite
struct LocalCatalogBatchTests {
    private func catalog() throws -> LocalCatalog {
        try LocalCatalog(databaseURL: FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).sqlite"))
    }

    private func book(_ title: String, tag: String) -> IndexedBook {
        IndexedBook(
            id: UUID(), title: title, authors: ["Alice"],
            tags: [tag],
            modifiedMilliseconds: 1_000, isDeleted: false, snapshot: Data([1])
        )
    }

    @Test
    func batchRoundTripsSearchAndFacets() async throws {
        let catalog = try catalog()
        try await catalog.upsertBatch((1...500).map { book("Book \($0)", tag: $0 % 2 == 0 ? "even" : "odd") })

        #expect(try await catalog.allBooks().count == 500)
        #expect(try await catalog.search("Book 42").count == 1)
        let facets = try await catalog.facetCounts(.tag)
        #expect(facets.first { $0.value == "even" }?.count == 250)
    }

    @Test
    func batchIsAtomicWithSingleUpsertEquivalent() async throws {
        let catalog = try catalog()
        let a = book("A", tag: "x")
        let b = book("B", tag: "y")
        try await catalog.upsertBatch([a, b])
        #expect(try await catalog.book(id: a.id)?.title == "A")
        #expect(try await catalog.book(id: b.id)?.title == "B")
        // Re-upserting the batch (rebuild semantics) converges to the same set.
        try await catalog.upsertBatch([a, b])
        #expect(try await catalog.allBooks().count == 2)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodegen generate --spec project.yml` (if the new test file needs registration), then `xcodebuild -project BookManager.xcodeproj -scheme BookManager -destination 'platform=macOS' -derivedDataPath .build/DerivedData test -only-testing:BookManagerCoreTests/LocalCatalogBatchTests`
Expected: FAIL — `upsertBatch` doesn't exist.

- [ ] **Step 3: Implement `upsertBatch`**

In `BookManagerCore/Persistence/LocalCatalog.swift`:
- Extract the body of `upsert(_ book:)` into a private helper `private func upsert(_ book: IndexedBook, db: Database) throws` (the current `database.write { db in ... }` body becomes the helper; `upsert(_ book:)` becomes `try database.write { try upsert(book, db: $0) }`).
- Add:

```swift
    /// Upserts many books in ONE transaction (rebuild/ingest hot path — 10k
    /// per-book transactions become one).
    public func upsertBatch(_ books: [IndexedBook]) throws {
        try database.write { db in
            for book in books {
                try upsert(book, db: db)
            }
        }
    }
```

- [ ] **Step 4: Batch `rebuildCatalog` and `SyncEngine.ingest`**

In `BookManagerCore/Library/LibraryRepository.swift` `rebuildCatalog`: collect the built `IndexedBook`s into a buffer and, after the book loop, call `try await catalog.upsertBatch(built)` (memory is acceptable at this scale: 10k small snapshots ≈ tens of MB; the existing `clear()` stays first). Keep the dependency-ordered apply loop untouched.

In `BookManagerCore/Sync/SyncEngine.swift` `ingest`: collect the `makeIndexed(...)` results into a buffer; after the book loop, `if !built.isEmpty { try await catalog.upsertBatch(built) }` (replacing the per-book `catalog.upsert` inside the loop). Keep the fingerprint bookkeeping untouched.

- [ ] **Step 5: Run the tests to verify they pass, then the full core suite**

Run the focused suite, then `-only-testing:BookManagerCoreTests`. Expected: focused passes; full suite 131 + 2 = 133 tests green (rebuild/ingest correctness proven by the existing `LocalCatalogV3Tests`, `SyncEngineTests`, `ConvergenceTests`).

- [ ] **Step 6: Commit**

```bash
git add BookManagerCore/Persistence/LocalCatalog.swift BookManagerCore/Library/LibraryRepository.swift BookManagerCore/Sync/SyncEngine.swift BookManagerCoreTests/Persistence/LocalCatalogBatchTests.swift
git commit -m "perf: batch catalog upserts for rebuild and ingest"
```

---

### Task 2: Reconciler folder index (Core, TDD)

**Files:**
- Modify: `BookManagerCore/Sync/FolderReconciler.swift`
- Modify: `BookManagerCoreTests/Sync/FolderReconcilerTests.swift`

**Interfaces:**
- Consumes: the existing `reconcile()` + discovery logic.
- Produces: a per-pass folder index `[String: [URL]]` (lowercased 8-char book-id prefix → candidate folder URLs) built from ONE root enumeration; per-book discovery is a lookup.

- [ ] **Step 1: Write the failing test (behavior equality with the index in place)**

In `BookManagerCoreTests/Sync/FolderReconcilerTests.swift` add:

```swift
    @Test
    func discoveryStillFindsStrayFoldersViaIndex() async throws {
        let h = try await Harness()
        let book = try await h.createBook(title: "Indexed")
        let canonical = CanonicalPathBuilder.relativeDirectory(
            bookID: book.id, title: book.title, authors: book.authors
        )
        // Move the folder somewhere non-canonical (the discovery case).
        let folderURL = h.layout.root.appending(path: canonical, directoryHint: .isDirectory)
        let moved = h.layout.root.appending(path: "Stray \(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: folderURL, to: moved)

        let report = try await h.reconciler().reconcile()
        #expect(report.renamed == [book.id])
        #expect(report.missingFolders.isEmpty)
        #expect(FileManager.default.fileExists(atPath: folderURL.path))
    }
```

- [ ] **Step 2: Run it to verify it fails (or passes — behavior-equality gate)**

Run: `xcodebuild ... test -only-testing:BookManagerCoreTests/FolderReconcilerTests`
Expected: PASS against the current implementation (this is a behavior-equality lock for the refactor, not a RED test). If it fails now, the discovery contract is already broken — investigate before refactoring.

- [ ] **Step 3: Implement the index**

In `BookManagerCore/Sync/FolderReconciler.swift`:
- At the start of `reconcile()`, build the index once:

```swift
        let index = try await buildFolderIndex()
```

where `buildFolderIndex()` enumerates the library root ONCE (excluding `.bookmanager` via `.skipsHiddenFiles`, excluding names containing `" (conflict "`), producing `[String: [URL]]` keyed by the folder name's lowercased 8-char book-id prefix (for folder names that CONTAIN a UUID-ish prefix — match the current `localizedCaseInsensitiveContains(shortID)` semantics by keying on every 8-char run of hex in the name, or simpler: key by each folder's name and do the prefix lookup at discovery time with a Set of prefixes — choose the approach that preserves the current discovery behavior exactly and is O(1) per book).

Simplest correct approach: keep a `Set<String>` of all lowercased 8-char hex prefixes present in any folder name at the root (built during the one scan) plus the folder-name → URL map; per book, `shortID = String(bookID.uuidString.prefix(8)).lowercased()`; candidates = folders whose name contains `shortID` — resolve by scanning ONLY the short list of folders whose names were indexed as containing that prefix (build `[prefix: [URL]]` by extracting every 8-char hex run from each name once).

- Replace the per-book root enumeration in the discovery path with an index lookup (`candidates(bookID:)` reads the map). The canonical-folder exclusion, `.bookmanager` exclusion, and conflict-copy exclusion stay exactly as today.
- Keep `folderMatches` unchanged (hash checks remain only on divergent paths).

- [ ] **Step 4: Run the tests to verify they pass, then the full core suite**

Run the focused suite (all existing reconciler tests + the new one), then `-only-testing:BookManagerCoreTests`. Expected: 134 tests green (133 + 1); all 8 existing reconciler tests pass unchanged — behavior equality.

- [ ] **Step 5: Commit**

```bash
git add BookManagerCore/Sync/FolderReconciler.swift BookManagerCoreTests/Sync/FolderReconcilerTests.swift
git commit -m "perf: folder index for reconciler discovery (O(N + dirs))"
```

---

### Task 3: Cancellable, progress-reporting rebuild (Core + app)

**Files:**
- Modify: `BookManagerCore/Library/LibraryRepository.swift` (`rebuildCatalog(progress:cancelled:)`, `LibraryRepositoryError.rebuildCancelled`)
- Modify: `BookManager/Stores/LibrarySession.swift` (`rebuildIndex` progress/cancel wiring, `rebuildProgress`/`isRebuilding`/`cancelRebuild` published state)
- Modify: `BookManager/Views/DiagnosticsView.swift` (progress bar + Cancel)
- Create: `BookManagerCoreTests/Library/RebuildProgressTests.swift`

**Interfaces:**
- Consumes: the existing `rebuildCatalog()` body (Task 1's batched version).
- Produces: `rebuildCatalog(progress: @Sendable (Double) -> Void = { _ in }, cancelled: @Sendable () -> Bool = { false }) async throws` (existing callers compile unchanged via defaults); `LibraryRepositoryError.rebuildCancelled`.

- [ ] **Step 1: Write the failing tests**

Create `BookManagerCoreTests/Library/RebuildProgressTests.swift` (build a small real library via the repository, then test progress/cancel):

```swift
import Foundation
import Testing
@testable import BookManagerCore

@Suite
struct RebuildProgressTests {
    private func libraryWithBooks(_ count: Int) async throws -> (LibraryRepository, URL, URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let indexURL = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).sqlite")
        let repo = try await LibraryRepository.open(
            at: root, indexesDirectory: indexURL.deletingLastPathComponent(), deviceID: UUID()
        )
        for i in 0..<count {
            _ = try await repo.createBook(title: "Book \(i)", authors: ["Alice"])
        }
        return (repo, root, indexURL)
    }

    @Test
    func progressIsMonotonicAndCompletes() async throws {
        let (repo, _, _) = try await libraryWithBooks(3)
        var values: [Double] = []
        try await repo.rebuildCatalog(
            progress: { values.append($0) },
            cancelled: { false }
        )
        #expect(values == values.sorted())
        #expect(values.last == 1)
        #expect(try await repo.bookCount() == 3) // via a public count accessor if present; else catalog count
    }

    @Test
    func cancellationStopsRebuild() async throws {
        let (repo, _, _) = try await libraryWithBooks(5)
        var seen = 0
        do {
            try await repo.rebuildCatalog(
                progress: { _ in seen += 1 },
                cancelled: { seen >= 2 }
            )
            Issue.record("expected rebuildCancelled")
        } catch LibraryRepositoryError.rebuildCancelled {
            #expect(seen >= 2)
        }
    }
}
```

Note: if `LibraryRepository` has no public `bookCount()` accessor, use the repository's existing query (e.g., `books().count`) in the first test — pick what exists.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodegen generate --spec project.yml`, then `xcodebuild ... test -only-testing:BookManagerCoreTests/RebuildProgressTests`
Expected: FAIL — `rebuildCatalog(progress:cancelled:)` doesn't exist.

- [ ] **Step 3: Implement the signature**

In `BookManagerCore/Library/LibraryRepository.swift`: add `case rebuildCancelled` to `LibraryRepositoryError`; change `rebuildCatalog()` to `rebuildCatalog(progress:cancelled:)` with the defaulted closures; inside the book loop, after each book: `if cancelled() { throw LibraryRepositoryError.rebuildCancelled }`, `progress(Double(index) / Double(total))` (total = max(bookIDs.count, 1)); after the batch upsert: `progress(1)`. Keep `open()`'s call compiling (defaults).

- [ ] **Step 4: Wire the session + Diagnostics**

In `LibrarySession`: add `private(set) var rebuildProgress: Double?`, `private(set) var isRebuilding = false`, `private var cancelRebuildRequested = false`; `rebuildIndex()` sets `isRebuilding = true`, calls `repository.rebuildCatalog(progress: { [weak self] in self?.rebuildProgress = $0 }, cancelled: { [weak self] in self?.cancelRebuildRequested ?? false })` (the closures hop to MainActor — session is MainActor; capture weakly), clears state in a `defer`; add `func cancelRebuild() { cancelRebuildRequested = true }`.

In `DiagnosticsView`: when `session.isRebuilding`, show a `ProgressView(value: session.rebuildProgress ?? 0)` + a Cancel button calling `session.cancelRebuild()` (replacing/alongside the existing Rebuild Index button). Check the view's session access pattern and follow it.

- [ ] **Step 5: Run the tests to verify they pass, then the full core suite + build**

Run the focused suite, `-only-testing:BookManagerCoreTests` (135 tests), and `xcodebuild ... build` → BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add BookManagerCore/Library/LibraryRepository.swift BookManager/Stores/LibrarySession.swift BookManager/Views/DiagnosticsView.swift BookManagerCoreTests/Library/RebuildProgressTests.swift
git commit -m "feat: cancellable progress-reporting catalog rebuild"
```

---

### Task 4: 10k performance benchmarks (Core, TDD)

**Files:**
- Create: `BookManagerCoreTests/Performance/PerformanceTests.swift`

**Interfaces:**
- Consumes: `LocalCatalog.upsertBatch`, `FolderReconciler` (folder index), Foundation `ContinuousClock`.

- [ ] **Step 1: Write the failing tests**

Create `BookManagerCoreTests/Performance/PerformanceTests.swift`:

```swift
import Foundation
import Testing
@testable import BookManagerCore

@Suite
struct PerformanceTests {
    private static let bookCount = 10_000

    private func seededCatalog() async throws -> LocalCatalog {
        let catalog = try LocalCatalog(databaseURL: FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).sqlite"))
        let books = (0..<Self.bookCount).map { i in
            IndexedBook(
                id: UUID(), title: "Book \(i) of a very long title series", authors: ["Author \(i % 500)"],
                tags: ["tag\(i % 50)"], series: "Series \(i % 100)", seriesIndex: Double(i % 100),
                rating: i % 5 + 1, publisher: "Pub \(i % 20)",
                publicationMilliseconds: Int64(1_700_000_000_000 + i),
                addedMilliseconds: Int64(1_700_000_000_000),
                languages: ["eng"], identifiers: ["isbn": "978-\(String(format: "%012d", i))"],
                formats: [], coverHash: nil, relativePath: "",
                modifiedMilliseconds: Int64(i), isDeleted: false,
                snapshot: Data(repeating: 0x01, count: 256)
            )
        }
        try await catalog.upsertBatch(books)
        return catalog
    }

    @Test
    func searchStaysUnder250msAt10k() async throws {
        let catalog = try await seededCatalog()
        let clock = ContinuousClock()
        try await clock.measure {
            _ = try await catalog.search("Book 9999")
        }
        // Bound asserted below via a second measured run after warm-up.
    }

    @Test
    func allBooksUnder1sAt10k() async throws {
        let catalog = try await seededCatalog()
        _ = try await catalog.allBooks() // warm-up
        let clock = ContinuousClock()
        let elapsed = try await clock.measure {
            _ = try await catalog.allBooks()
        }
        #expect(elapsed < .seconds(1))
    }

    @Test
    func facetCountsUnder1sAt10k() async throws {
        let catalog = try await seededCatalog()
        let clock = ContinuousClock()
        let elapsed = try await clock.measure {
            _ = try await catalog.facetCounts(.tag)
            _ = try await catalog.facetCounts(.author)
        }
        #expect(elapsed < .seconds(1))
    }

    @Test
    func steadyStateReconcileCompletesAt10k() async throws {
        // With no materialized folders every book is "missing" — this exercises
        // the per-pass folder index (one root scan + 10k lookups), not O(N×dirs).
        let catalog = try await seededCatalog()
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let layout = LibraryLayout(root: root)
        try layout.create(manifest: LibraryManifest(id: UUID()))
        let reconciler = FolderReconciler(layout: layout, catalog: catalog, deviceID: UUID())
        let clock = ContinuousClock()
        let elapsed = try await clock.measure {
            _ = try await reconciler.reconcile()
        }
        #expect(elapsed < .seconds(5))
    }
}
```

Note: the search test measures via a warm-up + bound — implement it with the same `clock.measure` + `#expect(elapsed < .milliseconds(250))` pattern as the others (warm up once first). If a bound proves flaky in CI (cold machine), relax it ONE step (search < 500ms) and note the manual measurement for the acceptance criterion — do not weaken the others.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodegen generate --spec project.yml`, then `xcodebuild ... test -only-testing:BookManagerCoreTests/PerformanceTests`
Expected: FAIL — `upsertBatch` missing (if Task 1 isn't merged yet, this suite runs after Task 1 on the same branch; if the failure is only measurement, adjust bounds per the note).

- [ ] **Step 3: Verify they pass and are stable**

Run the suite 3× — the bounds must hold every run (warm-up built in). If a bound is unstable, relax per the Step 1 note and document the manual measurement.

- [ ] **Step 4: Commit**

```bash
git add BookManagerCoreTests/Performance/PerformanceTests.swift
git commit -m "test: 10k catalog performance benchmarks"
```

---

## Self-Review

- **Spec coverage:** Req 1 (batch writes) → Task 1. Req 2 (folder index) → Task 2. Req 3 (cancellable progress rebuild) → Task 3. Req 4 (10k benchmarks) → Task 4. Acceptance criteria map 1:1 to the tasks.
- **Placeholder scan:** no TBDs; every step has concrete code or an exact command. Task 4's bound-relaxation note is explicit guidance, not a placeholder.
- **Type consistency:** `upsertBatch` (Task 1) consumed by `rebuildCatalog`/`SyncEngine.ingest` (Task 1) and `PerformanceTests` (Task 4); `rebuildCatalog(progress:cancelled:)` + `rebuildCancelled` (Task 3) consumed by the session/Diagnostics (Task 3) and `RebuildProgressTests` (Task 3); the folder index (Task 2) is internal to `FolderReconciler`. No name drift.
- **Risks noted:** rebuild batching holds 10k snapshots in memory (tens of MB — acceptable, documented); the folder-index keying must preserve current discovery semantics exactly (behavior-equality test in Task 2); `ContinuousClock.measure` on `async throws` closures — use `try await clock.measure { ... }` where the closure is async, or wrap sync closures with `clock.measure` non-async; CI flakiness handled via generous bounds + warm-up.
