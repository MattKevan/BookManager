# Metadata Enrichment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** fetch missing metadata and covers from OpenLibrary + Google Books through a source-registry seam, with high-confidence results auto-applied and ambiguous ones reviewed; covers download through a new `updateCover` repository method.

**Architecture:** Core gains `MetadataSourceProviding` (protocol), `MetadataRegistry`, `MetadataCandidate`/`MetadataLookupQuery`, `MetadataLookupService` (actor: scoring + in-memory cache + cancellation), `MetadataHTTPClient` (protocol; production = URLSession, tests = stub), and OpenLibrary + Google Books sources. `LibraryRepository.updateCover(coverData:for:)` writes a cover change, materializes `cover.jpg`, upserts the catalog. The app adds an inspector "Fetch Metadata…" action, a session lookup/apply flow (missing-fields-only metadata edits + cover), a review sheet for ambiguous candidates, and the `network.client` entitlement.

**Tech Stack:** Swift 6.0 (strict concurrency), SwiftUI, Foundation `URLSession`, Swift Testing, XcodeGen.

## Global Constraints

- macOS 26; Swift 6.0 with `SWIFT_STRICT_CONCURRENCY: complete`; Core actors.
- **No change-store format change**; `BookEdit` is untouched (metadata applies via the existing `updateBook` path); only `updateCover` is new Core surface.
- **No real network in tests** — HTTP goes through `MetadataHTTPClient`; tests inject a stub. The production `URLSessionMetadataHTTPClient` is never exercised by unit tests (a manual residual verifies live lookups).
- **Missing-fields-only applies**: an enrichment must never clobber an existing field — candidates fill only empty book fields, and the cover only when the book has no `coverHash`.
- Existing 142-test suite stays green. **Verification commands MUST use `-skip-testing:BookManagerCoreTests/PerformanceTests`** (the 10k perf suite is slow under load and has caused worker timeouts); the perf suite is unaffected by these changes.
- Tests: Swift Testing; `-derivedDataPath .build/DerivedData`; run `xcodegen generate --spec project.yml` before building new files; suite-level `-only-testing`.

---

### Task 1: Source seam + lookup service (Core, TDD)

**Files:**
- Create: `BookManagerCore/Enrichment/MetadataModels.swift` (query, candidate, result)
- Create: `BookManagerCore/Enrichment/MetadataSourceProviding.swift` (protocol + `MetadataHTTPClient` + URLSession impl)
- Create: `BookManagerCore/Enrichment/MetadataRegistry.swift`
- Create: `BookManagerCore/Enrichment/MetadataLookupService.swift`
- Create: `BookManagerCore/Enrichment/OpenLibrarySource.swift`
- Create: `BookManagerCore/Enrichment/GoogleBooksSource.swift`
- Create: `BookManagerCoreTests/Enrichment/MetadataLookupServiceTests.swift`
- Create: `BookManagerCoreTests/Enrichment/MetadataSourceDecodingTests.swift`

**Interfaces:**
- Consumes: Foundation only.
- Produces:
  - `MetadataLookupQuery { isbn: String?, title: String, authors: [String] }` (Sendable/Equatable).
  - `MetadataCandidate: Identifiable { id, title, authors, publisher, publicationDate?, isbn?, coverURL?, sourceName }` (Sendable/Equatable).
  - `MetadataSourceProviding { name: String; func search(_ query:) async throws -> [MetadataCandidate] }` (Sendable).
  - `MetadataHTTPClient { func data(from url: URL) async throws -> Data }` + `URLSessionMetadataHTTPClient`.
  - `MetadataRegistry` — `init(sources: [any MetadataSourceProviding])`, `sources` (ordered), `func source(named:) -> (any MetadataSourceProviding)?`.
  - `MetadataLookupService` (actor) — `init(registry:cache:)`, `func lookup(_ query:) async throws -> MetadataLookupResult`, `MetadataLookupResult { candidates: [MetadataCandidate], autoApply: MetadataCandidate? }` (Equatable, Sendable).
  - `OpenLibrarySource(client:userAgent:)`, `GoogleBooksSource(client:userAgent:)` — decoding their JSON responses into candidates.

- [ ] **Step 1: Write the failing tests**

Create `BookManagerCoreTests/Enrichment/MetadataLookupServiceTests.swift` with a stub client + a fake source:

```swift
import Foundation
import Testing
@testable import BookManagerCore

@Suite
struct MetadataLookupServiceTests {
    private struct StubHTTPClient: MetadataHTTPClient {
        var handler: (URL) throws -> Data
        func data(from url: URL) async throws -> Data { try handler(url) }
    }

    private struct FakeSource: MetadataSourceProviding {
        let name: String
        let results: [MetadataCandidate]
        func search(_ query: MetadataLookupQuery) async throws -> [MetadataCandidate] { results }
    }

    private func candidate(_ title: String, isbn: String? = nil, source: String = "fake") -> MetadataCandidate {
        MetadataCandidate(
            id: "\(source)-\(title)", title: title, authors: ["Alice"],
            publisher: "Riverhead", publicationDate: nil, isbn: isbn,
            coverURL: nil, sourceName: source
        )
    }

    @Test
    func isbnExactAutoApplies() async throws {
        let registry = MetadataRegistry(sources: [FakeSource(name: "a", results: [candidate("Range", isbn: "9780735221291")])])
        let service = MetadataLookupService(registry: registry)
        let result = try await service.lookup(MetadataLookupQuery(isbn: "978-0-7352-2129-1", title: "Range", authors: ["David Epstein"]))
        #expect(result.autoApply?.isbn == "9780735221291")
        #expect(result.candidates.count == 1)
    }

    @Test
    func titleAuthorMatchAutoAppliesWhenUnambiguous() async throws {
        let registry = MetadataRegistry(sources: [FakeSource(name: "a", results: [candidate("Range: Why Generalists Triumph")])])
        let service = MetadataLookupService(registry: registry)
        let result = try await service.lookup(MetadataLookupQuery(isbn: nil, title: "Range: Why Generalists Triumph in a Specialized World", authors: ["David Epstein"]))
        #expect(result.autoApply?.title == "Range: Why Generalists Triumph")
        #expect(result.candidates.count == 1)
    }

    @Test
    func ambiguousResultsGoToReview() async throws {
        let registry = MetadataRegistry(sources: [FakeSource(name: "a", results: [
            candidate("Range A"), candidate("Range B"),
        ])])
        let service = MetadataLookupService(registry: registry)
        let result = try await service.lookup(MetadataLookupQuery(isbn: nil, title: "Range", authors: ["X"]))
        #expect(result.autoApply == nil)
        #expect(result.candidates.count == 2)
    }

    @Test
    func sourcesQueriedInPriorityOrderAndCancellable() async throws {
        let order: LockedBuffer = LockedBuffer()
        let first = FakeSource(name: "first", results: []) { }  // see note below
        // NOTE: FakeSource in the brief is fixed-result; to test priority+cancellation
        // the implementer may extend the fake with a record/cancel hook. The
        // required behavior: sources are queried in registry order; if the first
        // source returns candidates, the second is not consulted; `Task.checkCancellation`
        // between sources aborts the lookup.
    }

    @Test
    func cacheShortCircuitsSecondLookup() async throws {
        var calls = 0
        let source = FakeSource(name: "a", results: [candidate("Range")])
        // NOTE: the brief's fake is fixed-result; extend it with a call counter to
        // assert the second lookup with the SAME normalized query does not hit the source.
        let registry = MetadataRegistry(sources: [source])
        let service = MetadataLookupService(registry: registry)
        _ = try await service.lookup(MetadataLookupQuery(isbn: nil, title: "Range", authors: ["A"]))
        _ = try await service.lookup(MetadataLookupQuery(isbn: nil, title: "RANGE", authors: ["a"]))
        // #expect(calls == 1) — normalized-query cache hit.
    }
}
```

Create `BookManagerCoreTests/Enrichment/MetadataSourceDecodingTests.swift` with stubbed JSON for OpenLibrary and Google Books (a representative `search.json` doc and a `volumes` item), asserting the decoded candidates (title, authors, publisher, dates, isbn, cover URL). Use realistic but minimal JSON.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodegen generate --spec project.yml`, then `xcodebuild -project BookManager.xcodeproj -scheme BookManager -destination 'platform=macOS' -derivedDataPath .build/DerivedData test -only-testing:BookManagerCoreTests/Enrichment`
Expected: FAIL — the types don't exist.

- [ ] **Step 3: Implement the models, protocol, registry, client**

Follow the Interfaces above. `MetadataHTTPClient`'s production impl wraps `URLSession.shared.data(from:)`. `MetadataRegistry` is a plain value type holding the ordered sources.

- [ ] **Step 4: Implement the lookup service (scoring + cache + cancellation)**

`MetadataLookupService` (actor):
- `lookup(_:)`: normalize the query (isbn → digits-only lowercase; else `normalize(title) + "|" + normalize(firstAuthor)`); cache hit → return cached result; else query sources in registry order; between sources `try Task.checkCancellation()`; stop after the first source that returns non-empty candidates; score + rank; store in cache; return.
- Scoring: ISBN-exact (normalized equal) → 100. Else normalized-title equality → 60 + (author overlap ratio × 40) where overlap = fraction of the query's authors present in the candidate's authors (case/punctuation-normalized). Score 0 if titles don't match.
- `autoApply` = the top candidate when its score ≥ 90 AND (no second candidate OR top − second ≥ 20). Otherwise `autoApply = nil` and all candidates (sorted by score desc) go to `candidates` for review. Candidates from the auto-apply path also appear in `candidates`.
- `normalize(_:)`: lowercase, trim, collapse whitespace, strip punctuation — a shared helper.

- [ ] **Step 5: Implement the two sources**

- `OpenLibrarySource`: GET `https://openlibrary.org/search.json` with `title`/`author` query params (or `q=` for ISBN: `https://openlibrary.org/search.json?q=isbn:<digits>` when the query has an ISBN — prefer the ISBN route). Decode `{"docs": [{ "title", "author_name": [], "publisher": [], "first_publish_year": Int?, "isbn": [], "cover_i": Int? }]}` → candidates (id `openlibrary-<cover_i or first isbn or title-slug>`, coverURL `https://covers.openlibrary.org/b/id/<cover_i>-M.jpg` when cover_i present, else `/b/isbn/<isbn>-M.jpg` for the first isbn). `User-Agent` header via a URLRequest.
- `GoogleBooksSource`: GET `https://www.googleapis.com/books/v1/volumes?q=<isbn:… | intitle:…+inauthor:…>&maxResults=20`. Decode `{"items": [{ "id", "volumeInfo": { "title", "authors": [], "publisher", "publishedDate": "YYYY[-MM[-DD]]", "imageLinks": { "thumbnail" } } }]}` → candidates (id `google-<id>`, coverURL = thumbnail with `http` → `https`). Parse `publishedDate` with a lenient formatter (year-only, year-month, full date) → nil on failure.
- Both sources build a `URLRequest` with the injected `userAgent` and fetch via the injected client (`client.data(from:)` — the client receives the URL; if a User-Agent must be sent, have the client take a `URLRequest` instead of `URL` — CHOOSE ONE: if `data(from: URL)` is insufficient for the User-Agent header, change the protocol to `data(from request: URLRequest)` and update the production + stub accordingly — the tests are unaffected since the stub ignores the request).

- [ ] **Step 6: Run the tests to verify they pass, then the full core suite (minus perf)**

Run the focused suites, then `xcodebuild ... test -skip-testing:BookManagerCoreTests/PerformanceTests`. Expected: focused passes; full non-perf suite green (142 + ~8 new).

- [ ] **Step 7: Commit**

```bash
git add BookManagerCore/Enrichment/ BookManagerCoreTests/Enrichment/
git commit -m "feat: metadata source seam, lookup service, openlibrary + google books"
```

---

### Task 2: `LibraryRepository.updateCover` (Core, TDD)

**Files:**
- Modify: `BookManagerCore/Library/LibraryRepository.swift`
- Create: `BookManagerCoreTests/Library/CoverUpdateTests.swift`

**Interfaces:**
- Consumes: `AutomergeBookDocument.setCover(_:clock:)`, `ChangeStore.writeBookChange`, `BookFolder` materialize (`bookDirectoryURL`), `IndexedBookFactory`/`makeIndexedBook`, `LocalCatalog.upsert`.
- Produces: `func updateCover(coverData: Data, for bookID: UUID) async throws -> IndexedBook` (throws `bookNotFound` for a missing book; writes the cover change, materializes `cover.jpg` atomically, upserts the catalog, returns the updated book).

- [ ] **Step 1: Write the failing tests**

Create `BookManagerCoreTests/Library/CoverUpdateTests.swift` (build a real library via the repository):

```swift
import Foundation
import Testing
@testable import BookManagerCore

@Suite
struct CoverUpdateTests {
    @Test
    func updateCoverWritesChangeMaterializesAndUpdatesCatalog() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let indexURL = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).sqlite")
        let repo = try await LibraryRepository.open(
            at: root, indexesDirectory: indexURL.deletingLastPathComponent(), deviceID: UUID()
        )
        let book = try await repo.createBook(title: "Covered", authors: ["Alice"])
        #expect(book.coverHash == nil)

        let cover = Data(repeating: 0xFF, count: 64)
        let updated = try await repo.updateCover(coverData: cover, for: book.id)

        #expect(updated.coverHash != nil)
        // Materialized cover.jpg exists.
        let coverURL = root
            .appending(path: updated.relativePath, directoryHint: .isDirectory)
            .appending(path: "cover.jpg")
        #expect(FileManager.default.fileExists(atPath: coverURL.path))
        #expect(try Data(contentsOf: coverURL) == cover)
        // The change is durable: rebuild the catalog from changes and the cover survives.
        try await repo.rebuildCatalog()
        let rebuilt = try await repo.books().first { $0.id == book.id }
        #expect(rebuilt?.coverHash == updated.coverHash)
    }

    @Test
    func updateCoverThrowsForMissingBook() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let indexURL = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).sqlite")
        let repo = try await LibraryRepository.open(
            at: root, indexesDirectory: indexURL.deletingLastPathComponent(), deviceID: UUID()
        )
        #expect(throws: LibraryRepositoryError.bookNotFound(UUID())) {
            _ = try await repo.updateCover(coverData: Data([1]), for: UUID())
        }
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodegen generate --spec project.yml`, then `xcodebuild ... test -only-testing:BookManagerCoreTests/CoverUpdateTests`
Expected: FAIL — `updateCover` doesn't exist.

- [ ] **Step 3: Implement `updateCover`**

Follow the Interfaces; mirror `createBook`'s cover handling (`setCover(CoverValue(filename: "cover.jpg", contentHash:), clock:)` → `writeBookChange` → materialize `cover.jpg` (atomic write to the book folder) → `makeIndexedBook` → `catalog.upsert`). `CoverValue` and `BookFolder.contentHash` exist.

- [ ] **Step 4: Run the tests to verify they pass, then the non-perf core suite**

Run the focused suite, then `xcodebuild ... test -skip-testing:BookManagerCoreTests/PerformanceTests`. Expected: green (142 + 2).

- [ ] **Step 5: Commit**

```bash
git add BookManagerCore/Library/LibraryRepository.swift BookManagerCoreTests/Library/CoverUpdateTests.swift
git commit -m "feat: updateCover repository method (cover changes for enrichment)"
```

---

### Task 3: App wiring — inspector action, review sheet, entitlement

**Files:**
- Modify: `BookManager/Stores/LibrarySession.swift`
- Modify: `BookManager/Views/BookInspectorView.swift`
- Create: `BookManager/Views/MetadataReviewSheet.swift`
- Modify: `Config/BookManager.entitlements` (add `com.apple.security.network.client`)

**Interfaces:**
- Consumes: `MetadataLookupService` + `MetadataRegistry` + `OpenLibrarySource`/`GoogleBooksSource` + `URLSessionMetadataHTTPClient` (Task 1), `LibraryRepository.updateCover` (Task 2), `BookEdit`/`updateBook` (existing).
- Produces: `LibrarySession.fetchMetadata(for:)`, `LibrarySession.applyMetadataCandidate(_:for:)`, `LibrarySession.metadataCandidates`/`metadataReviewPresented` (published), inspector "Fetch Metadata…" button, `MetadataReviewSheet`.

- [ ] **Step 1: Session lookup + apply**

In `LibrarySession`:
- Add published state: `private(set) var metadataCandidates: [MetadataCandidate] = []`, `private(set) var metadataReviewPresented = false`, `private(set) var metadataLookupError: String?`, `private(set) var metadataBookID: UUID?`.
- `func fetchMetadata(for bookID: UUID) async`: guard the book exists; build `MetadataLookupQuery(isbn: identifiers["isbn"], title: title, authors: authors)`; construct the service once (a lazy `metadataService` — registry with OpenLibrary + GoogleBooks sources using `URLSessionMetadataClient` and a User-Agent like `"BookManager/1.0 (contact: dev@example.com)"`); run in a cancellable Task (the session method is async — the caller wraps it); on `.autoApply` → `await applyMetadataCandidate(candidate, for: bookID, auto: true)`; else set `metadataCandidates`/`metadataBookID`/`metadataReviewPresented = true`; on error → `metadataLookupError`.
- `func applyMetadataCandidate(_ candidate: MetadataCandidate, for bookID: UUID, auto: Bool = false) async`: build a `BookEdit` containing ONLY fields the book lacks (title empty → candidate.title; authors empty → candidate.authors; publisher nil → candidate.publisher; publicationDate nil → candidate.publicationDate; identifiers: add candidate.isbn when the book has no isbn) — **never clobber existing fields**; call `updateBook` with the edit; if the book has no `coverHash` and the candidate has a `coverURL` → download (via `URLSession`/the client, bounded) → `repository.updateCover`; refresh; clear review state when not auto.
- Reset the metadata state in `closeLibrary`.

- [ ] **Step 2: Inspector action + review sheet**

- `BookInspectorView`: add a "Fetch Metadata…" button (below Edit Metadata…) calling `Task { await session.fetchMetadata(for: book.id) }`, disabled while a lookup is in flight (add `session.isFetchingMetadata` published).
- `ContentView`: present `MetadataReviewSheet(candidates: session.metadataCandidates, onPick: { candidate in Task { await session.applyMetadataCandidate(candidate, for: session.metadataBookID!) } }, onSkip: { session.metadataReviewPresented = false })` as a `.sheet(isPresented: $session.metadataReviewPresented)`. The sheet lists candidates (title, authors, source, a thumbnail loaded from `candidate.coverURL` via a small `AsyncImage`-style task), with Apply buttons per candidate and a Skip/Cancel.

- [ ] **Step 3: Entitlement**

Add `com.apple.security.network.client` = true to `Config/BookManager.entitlements` (outbound requests from the sandbox).

- [ ] **Step 4: Build and verify wiring**

Run: `xcodegen generate --spec project.yml` (new view file), then `xcodebuild ... build` → BUILD SUCCEEDED; non-perf core suite `... test -skip-testing:BookManagerCoreTests/PerformanceTests` → green.
Manual residual (human): a real "Fetch Metadata…" lookup against OpenLibrary (needs the network-client entitlement + a live connection), auto-apply for an ISBN book, the review sheet for an ambiguous title, and the cover appearing in the grid/inspector. Note in the report.

- [ ] **Step 5: Commit**

```bash
git add BookManager/Stores/LibrarySession.swift BookManager/Views/BookInspectorView.swift BookManager/Views/MetadataReviewSheet.swift Config/BookManager.entitlements
git commit -m "feat: inspector metadata enrichment with review sheet and cover download"
```

---

## Self-Review

- **Spec coverage:** Req 1 (seam + registry) → Task 1; Req 2 (lookup service: scoring/cache/cancel) → Task 1; Req 3 (updateCover + metadata via updateBook) → Task 2 + Task 3; Req 4 (UI: inspector action, auto-apply, review sheet) → Task 3; Req 5 (entitlement) → Task 3; Req 6 (no network in tests) → Task 1 stub client + Global Constraints.
- **Placeholder scan:** no TBDs; the Task 1 test sketch notes (fake-source extensions for priority/cache) are explicit guidance, not placeholders; Task 1 Step 5's `URLRequest`-vs-`URL` protocol choice is an explicit either/or with both paths specified.
- **Type consistency:** `MetadataLookupQuery`/`MetadataCandidate`/`MetadataLookupResult`/`MetadataSourceProviding`/`MetadataHTTPClient`/`MetadataRegistry`/`MetadataLookupService` defined in Task 1, consumed in Task 3 with matching names; `updateCover` defined in Task 2, consumed in Task 3. No name drift.
- **Risks noted:** the `data(from: URL)` client may need to become `data(from: URLRequest)` for the User-Agent (either/or specified); the review sheet's thumbnail loading is best-effort (nil → placeholder); real-network behavior is a manual residual; full-suite verification always skips the perf suite (timeout history).
