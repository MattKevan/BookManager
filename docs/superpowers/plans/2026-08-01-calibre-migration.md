# Calibre Migration Plan (Slice 3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Import a **copy** of an existing Calibre library into Book Manager without modifying the source: read `metadata.db` (schema `user_version` 26) read-only, map books/authors/series/tags/rating/publisher/dates/languages/identifiers/comments/cover/formats, preserve custom columns and unsupported metadata in a namespaced raw payload, cross-check against each book's `metadata.opf`, and drive the whole flow through a wizard (select library → counts → subset selection → resumable import → report).

**Architecture:** Everything flows Book Manager Core → Library Repository → Change Store exactly as Slice 2. New core components: a `Calibre` module area (`BookManagerCore/Calibre/`) with the read-only schema adapter (`CalibreSchema26`), reader (`CalibreReader`), DTOs, fixture generator (test target), and import service (`CalibreImportService`) with a resumable progress record. The CRDT schema gains ONE tolerant field for the raw metadata payload (a per-device LWW register holding a JSON string — set once at import, so no concurrent-write concerns). The app gains a wizard (`CalibreImportView`) and session actions. The source Calibre library is never written: GRDB opens `metadata.db` with `readOnly = true`, and all file reads are plain `FileManager` reads.

**Tech Stack:** Unchanged (macOS 26+, Swift 6 strict concurrency, SwiftUI, Observation, Automerge 0.7.2, GRDB 7.11.1, ZIPFoundation 0.9.19, PDFKit/CoreGraphics/ImageIO, XMLParser, CryptoKit, Swift Testing, XCTest UI testing, XcodeGen). No new dependencies.

## Global Constraints

- macOS 26 or later; Swift 6 with `SWIFT_STRICT_CONCURRENCY: complete`.
- Dependencies pinned by exact version; no new dependencies.
- `BookManagerCore` contains no SwiftUI. It may use Foundation, GRDB, XMLParser, ImageIO, CryptoKit, UniformTypeIdentifiers, and AppKit-free image conversion.
- The portable library's `.bookmanager/changes` directory is the source of truth. SQLite catalogue files under Application Support are disposable and rebuildable.
- An exact duplicate (same content hash) is never copied silently. A likely duplicate (normalized title + first author) is never merged silently.
- **The source Calibre library is read-only.** The acceptance fixture's `metadata.db` must have identical modification timestamp and content hash after any read.
- Every new field change is one Automerge commit and one immutable `.amchange` file.
- The app must remain runnable after every task; completed behavior is covered by automated tests.
- Public API compatibility with Slice 2: existing `NewBookMetadata`/`ResolvedBook`/`BookFolder`/`LibraryRepository`/`LibraryRepositoryImporting` signatures keep working; the new `rawMetadata` field is additive with defaults.

## Calibre Schema Facts (verified against Calibre's `resources/metadata_sqlite.sql` and `src/calibre/db/backend.py`)

- `user_version` is read via `PRAGMA user_version`; the acceptance library is `26`. Versioned schema adapters isolate the mapping; an unknown version is rejected with a clear error.
- `books`: `id, title, sort, author_sort, series_index, timestamp, pubdate, path, uuid, has_cover, cover (BLOB), last_modified` (+ possibly `pages`, `lccn`). Dates are stored as **Julian day numbers** (convert: `Date(timeIntervalSince1970: (julian - 2440587.5) * 86400)`).
- `authors(id, name, sort)`; `books_authors_link(book, author)` — **author order is the link row insertion order** (Calibre's `meta` view does `sortconcat(bal.id, name)`).
- `series(id, name, sort)`; `books_series_link(book, series)`; series index lives in `books.series_index` in the v26 era — read defensively (`PRAGMA table_info`), fall back to `books_series_link.series_index` if the column is absent.
- `tags(id, name)`; `books_tags_link(book, tag)`; `ratings(id, rating)`; `books_ratings_link(book, rating)`; `publishers(id, name)`; `books_publishers_link(book, publisher)`.
- `data(id, book, format, uncompressed_size, name, path)` — format files live at `<library>/<book.path>/<name>.<format.lowercased()>`.
- `comments(id, book, text)` — HTML text; preserve verbatim.
- `identifiers(id, book, type, val)` — map into the identifiers dictionary.
- `languages(id, lang_code)`; `books_languages_link(book, lang_code | lang)` — column drift; read defensively.
- `custom_columns(id, label, name, datatype, is_multiple, ...)`; per-column value tables `custom_column_N(id, book, value)` and link tables `books_custom_column_N_link(id, book, value, extra)` for `is_multiple = 1`.
- `library_id(uuid)`.
- Each book folder contains Calibre's auto-maintained `metadata.opf` — parsed with Foundation `XMLParser` as cross-check + fallback (the DB stays authoritative).

**Fixture strategy:** tests build a **generated** fixture (faithful v26 subset DDL + 13 books covering the mapping matrix). The **supplied 13-book acceptance library** (user-provided, `user_version` 26) is used read-only for local acceptance only — never copied into the repo. The implementer fetches the authoritative DDL for the v26-era tables from `kovidgoyal/calibre` (`resources/metadata_sqlite.sql`) during Task 2 and includes the needed tables verbatim in the fixture generator.

## File Map

```text
project.yml                                           (unchanged)
BookManagerCore/
├── CRDT/
│   ├── BookValues.swift                              (modify: NewBookMetadata.rawMetadata, default nil)
│   ├── BookDocumentSchema.swift                      (modify: rawMetadata register field, tolerant decoding)
│   └── AutomergeBookDocument.swift                   (modify: setRawMetadata, resolvedBook().rawMetadata)
├── Library/
│   ├── BookFolder.swift                              (modify: materialize writes raw_metadata.json sidecar)
│   └── LibraryRepository.swift                       (modify: writeChanges writes rawMetadata change)
├── Persistence/
│   └── IndexedBook.swift                             (unchanged — raw payload stays out of the catalogue)
└── Calibre/
    ├── CalibreModels.swift                           (create: CalibreBookRecord, CalibreFormatRecord, CalibreCover, CalibreLibrarySummary, CalibreImportReport/Item)
    ├── CalibreSchema.swift                           (create: CalibreSchemaAdapting protocol + CalibreSchema26 + defensive helpers)
    ├── CalibreReader.swift                           (create: read-only GRDB open, validation, book enumeration, OPF cross-check)
    └── CalibreImportService.swift                    (create: selection-aware import, progress record, resume, report)
BookManager/
├── Stores/
│   └── LibrarySession.swift                          (modify: calibre summary/import state + actions)
└── Views/
    ├── CalibreImportView.swift                       (create: wizard — summary, selection, progress, report)
    └── ContentView.swift                             (modify: "Import from Calibre…" entry point)
BookManagerCoreTests/
├── Calibre/
│   ├── CalibreFixture.swift                          (create: generated user_version-26 library builder)
│   ├── CalibreReaderTests.swift                      (create)
│   └── CalibreImportServiceTests.swift               (create)
└── CRDT/
    └── SchemaV2Tests.swift                           (modify: rawMetadata round-trip test)
BookManagerUITests/BookManagerUITests.swift           (unchanged)
docs/superpowers/specs/2026-07-29-book-manager-design.md  (modify: Slice 3 status)
README.md                                            (modify: Slice 3 status)
```

---

### Task 1: Raw Metadata in the CRDT and Book Folder

**Files:**

- Modify: `BookManagerCore/CRDT/BookValues.swift`
- Modify: `BookManagerCore/CRDT/BookDocumentSchema.swift`
- Modify: `BookManagerCore/CRDT/AutomergeBookDocument.swift`
- Modify: `BookManagerCore/Library/BookFolder.swift`
- Modify: `BookManagerCore/Library/LibraryRepository.swift`
- Modify: `BookManagerCoreTests/CRDT/SchemaV2Tests.swift`

**Interfaces:**

- Consumes: v2 schema adapter (Slice 2), `ResolvedBook`, `BookFolder.materialize`.
- Produces: `NewBookMetadata.rawMetadata: [String: String]?` (default nil), schema field `rawMetadata: [String: VersionedValue<String>]` (device → JSON string), `setRawMetadata(_ payload: [String: String], clock:)`, `ResolvedBook.rawMetadata: [String: String]?`, a `raw_metadata.json` sidecar written during materialize, and `writeChanges` writing the raw change when present. Tolerant decoding keeps every v1/v2 document working.

- [ ] **Step 1: Write the failing test**

Append to `BookManagerCoreTests/CRDT/SchemaV2Tests.swift`:

```swift
    @Test
    func rawMetadataRoundTripsAndSurvivesRebuild() throws {
        let source = try document()
        _ = try source.setTitle("Range", clock: .init(physicalMilliseconds: 1_000, nodeID: deviceA))
        let payload = ["calibre.custom.genre": #"["science"]"#, "calibre.pages": "320"]
        let change = try source.setRawMetadata(payload, clock: .init(physicalMilliseconds: 2_000, nodeID: deviceA))

        let replica = try AutomergeBookDocument.empty(deviceID: deviceB)
        try replica.apply(change)
        #expect(try replica.resolvedBook().rawMetadata == payload)

        // v2 documents without the field still resolve with nil raw metadata.
        let v2 = try AutomergeBookDocument.new(bookID: bookID, deviceID: deviceA)
        #expect(try v2.resolvedBook().rawMetadata == nil)
    }
```

- [ ] **Step 2: Run it to verify RED**

```bash
xcodegen generate --spec project.yml
xcodebuild -project BookManager.xcodeproj -scheme BookManager -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:BookManagerCoreTests/SchemaV2Tests/rawMetadataRoundTripsAndSurvivesRebuild test
```

Expected: compilation fails (`rawMetadata`/`setRawMetadata` undefined).

- [ ] **Step 3: Add the schema field**

In `BookDocumentSchema.swift`, add `rawMetadata: [String: VersionedValue<String>]` (per-device register holding a JSON string), defaulting to `[:]`, included in `init`, the custom `init(from:)` via `decodeIfPresent ?? [:]` (tolerant), and `CodingKeys`. In `ResolvedBook`, add `let rawMetadata: [String: String]?`.

- [ ] **Step 4: Add the adapter setter + resolution**

In `AutomergeBookDocument.swift`:

```swift
    public func setRawMetadata(_ payload: [String: String], clock: HybridLogicalClock) throws -> Data {
        var schema = try decode()
        let json = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
        schema.rawMetadata[deviceID.uuidString] = VersionedValue(value: json, clock: clock)
        return try commit(schema, message: "set-raw-metadata", timestamp: clock.date)
    }
```

In `resolvedBook()`, resolve `newest(schema.rawMetadata)?.value` and decode the JSON into `[String: String]?` (on decode failure, treat as nil and let diagnostics surface it — log via `assert` only in debug). Include the raw clock in the modified-clock computation.

- [ ] **Step 5: NewBookMetadata + writeChanges + sidecar**

- `NewBookMetadata` gains `public var rawMetadata: [String: String]?` (default nil; added to init with default).
- `LibraryRepository.writeChanges`: after the other fields, `if let raw = metadata.rawMetadata, !raw.isEmpty { try await write(document.setRawMetadata(raw, clock: current.tick()), clock: current) }`.
- `BookFolder.materialize`: when `resolved.rawMetadata` is non-empty, write `raw_metadata.json` (pretty-printed JSON) atomically next to `metadata.opf`.

- [ ] **Step 6: Run the schema + repository tests**

```bash
xcodebuild -project BookManager.xcodeproj -scheme BookManager -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:BookManagerCoreTests/SchemaV2Tests -only-testing:BookManagerCoreTests/LibraryRepositoryV2Tests test
xcodebuild -project BookManager.xcodeproj -scheme BookManager -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:BookManagerCoreTests test
```

Expected: new test green; full core suite green (Slice 1 + 2 suites unchanged).

- [ ] **Step 7: Commit**

```bash
git add BookManagerCore BookManagerCoreTests BookManager.xcodeproj
git commit -m "feat: add raw metadata payload to the book schema"
```

### Task 2: Calibre Reader and Fixture Generator

**Files:**

- Create: `BookManagerCore/Calibre/CalibreModels.swift`
- Create: `BookManagerCore/Calibre/CalibreSchema.swift`
- Create: `BookManagerCore/Calibre/CalibreReader.swift`
- Create: `BookManagerCoreTests/Calibre/CalibreFixture.swift`
- Create: `BookManagerCoreTests/Calibre/CalibreReaderTests.swift`

**Interfaces:**

- Consumes: GRDB (read-only), XMLParser, Foundation.
- Produces:
  - `CalibreBookRecord { calibreID, title, authors: [(name, sort)], series, seriesIndex, tags, rating, publisher, publicationDate, addedDate, languages, identifiers, comments, formats: [CalibreFormatRecord], cover: CalibreCover?, rawMetadata, opfPath }`
  - `CalibreFormatRecord { format, name, sourceURL, size }`
  - `CalibreCover { case blob(Data), file(URL) }`
  - `CalibreLibrarySummary { userVersion, libraryID, bookCount, formatCount, titles: [String] }`
  - `CalibreSchemaAdapting` protocol + `CalibreSchema26` (validation: `PRAGMA user_version == 26`; defensive column discovery via `PRAGMA table_info`; SQL for all mapped tables)
  - `CalibreReader.open(libraryURL:) throws -> CalibreReader`, `summary()`, `books() -> [CalibreBookRecord]`

- [ ] **Step 1: Write the reader tests + fixture**

Create `BookManagerCoreTests/Calibre/CalibreFixture.swift`:

```swift
import Foundation
import GRDB
import Testing
@testable import BookManagerCore

enum CalibreFixture {
    /// A faithful Calibre user_version-26 subset: books, authors, series, tags,
    /// ratings, publishers, data, comments, identifiers, languages, custom
    /// columns (scalar + multiple), library_id, plus per-book folders with
    /// format files, covers, and metadata.opf.
    static func makeLibrary(named name: String = "fixture-library") throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: name, directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try buildDatabase(at: root.appending(path: "metadata.db"))
        try writeBookFolders(at: root)
        return root
    }

    private static func buildDatabase(at url: URL) throws {
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            // Schema (v26-era DDL — fetch verbatim from kovidgoyal/calibre
            // resources/metadata_sqlite.sql during implementation; the subset
            // below covers every table the reader queries).
            try db.execute(sql: """
                CREATE TABLE books (id INTEGER PRIMARY KEY, title TEXT NOT NULL DEFAULT '',
                    sort TEXT NOT NULL DEFAULT '', author_sort TEXT NOT NULL DEFAULT '',
                    series_index REAL NOT NULL DEFAULT 0, timestamp REAL NOT NULL DEFAULT 0,
                    pubdate REAL NOT NULL DEFAULT 0, path TEXT NOT NULL DEFAULT '',
                    uuid TEXT NOT NULL DEFAULT '', has_cover BOOL NOT NULL DEFAULT 0,
                    cover BLOB, last_modified REAL NOT NULL DEFAULT 0, pages INTEGER, lccn TEXT);
                CREATE TABLE authors (id INTEGER PRIMARY KEY, name TEXT NOT NULL, sort TEXT NOT NULL DEFAULT '');
                CREATE TABLE books_authors_link (id INTEGER PRIMARY KEY, book INTEGER NOT NULL, author INTEGER NOT NULL, UNIQUE(book, author));
                CREATE TABLE series (id INTEGER PRIMARY KEY, name TEXT NOT NULL, sort TEXT NOT NULL DEFAULT '');
                CREATE TABLE books_series_link (id INTEGER PRIMARY KEY, book INTEGER NOT NULL, series INTEGER NOT NULL, UNIQUE(book, series));
                CREATE TABLE tags (id INTEGER PRIMARY KEY, name TEXT NOT NULL);
                CREATE TABLE books_tags_link (id INTEGER PRIMARY KEY, book INTEGER NOT NULL, tag INTEGER NOT NULL, UNIQUE(book, tag));
                CREATE TABLE ratings (id INTEGER PRIMARY KEY, rating INTEGER NOT NULL);
                CREATE TABLE books_ratings_link (id INTEGER PRIMARY KEY, book INTEGER NOT NULL, rating INTEGER NOT NULL, UNIQUE(book, rating));
                CREATE TABLE publishers (id INTEGER PRIMARY KEY, name TEXT NOT NULL);
                CREATE TABLE books_publishers_link (id INTEGER PRIMARY KEY, book INTEGER NOT NULL, publisher INTEGER NOT NULL, UNIQUE(book, publisher));
                CREATE TABLE data (id INTEGER PRIMARY KEY, book INTEGER NOT NULL, format TEXT NOT NULL COLLATE NOCASE, uncompressed_size INTEGER NOT NULL, name TEXT NOT NULL, UNIQUE(book, format));
                CREATE TABLE comments (id INTEGER PRIMARY KEY, book INTEGER NOT NULL, text TEXT NOT NULL);
                CREATE TABLE identifiers (id INTEGER PRIMARY KEY, book INTEGER NOT NULL, type TEXT NOT NULL, val TEXT NOT NULL);
                CREATE TABLE languages (id INTEGER PRIMARY KEY, lang_code TEXT NOT NULL);
                CREATE TABLE books_languages_link (id INTEGER PRIMARY KEY, book INTEGER NOT NULL, lang_code TEXT NOT NULL, UNIQUE(book, lang_code));
                CREATE TABLE custom_columns (id INTEGER PRIMARY KEY, label TEXT NOT NULL, name TEXT NOT NULL, datatype TEXT NOT NULL, mark_for_delete BOOL NOT NULL DEFAULT 0, editable BOOL NOT NULL DEFAULT 1, display TEXT NOT NULL DEFAULT '{}', is_multiple BOOL NOT NULL DEFAULT 0, normalized BOOL NOT NULL, UNIQUE(label));
                CREATE TABLE custom_column_1 (id INTEGER PRIMARY KEY, book INTEGER NOT NULL, value TEXT);
                CREATE TABLE books_custom_column_2_link (id INTEGER PRIMARY KEY, book INTEGER NOT NULL, value TEXT, extra TEXT);
                CREATE TABLE library_id (uuid TEXT NOT NULL);
                """)
            // ... insert 13 books covering the mapping matrix (multi-author
            // ordering, multi-format, tags+series, rating+publisher, julian
            // dates, languages, identifiers, comments, covers both as BLOB and
            // as file, custom columns scalar + multiple, unsupported fields
            // pages/lccn). Julian conversion helper: Date -> julian =
            // timeIntervalSince1970 / 86400 + 2440587.5.
            try db.execute(sql: "PRAGMA user_version = 26")
            try db.execute(sql: "INSERT INTO library_id(uuid) VALUES (?)", arguments: ["acceptance-fixture-uuid"])
        }
        try queue.close()
    }

    private static func writeBookFolders(at root: URL) throws {
        // For each book: <root>/<Author>/<Title> (<id>)/ with format files
        // (matching data.name + format extension), cover.jpg when has_cover and
        // no BLOB, and metadata.opf (parsed by the reader's cross-check).
    }
}
```

Note: `try queue.close()` — verify GRDB's close API (`close()` throws) vs async in the project's version and adapt. The DDL must be **verified against the authoritative v26 schema** during implementation (fetch `resources/metadata_sqlite.sql` from `kovidgoyal/calibre` at a v26-era commit and align every column the reader queries). The `sortconcat` author ordering is by `books_authors_link.id` — insert authors in the intended order.

Create `BookManagerCoreTests/Calibre/CalibreReaderTests.swift` (13 books):

- `opensAndSummarizesFixtureLibrary` — `summary()` returns userVersion 26, libraryID, bookCount 13, formatCount matching the fixture's format files, non-empty titles.
- `mapsFullMetadataMatrix` — pick the fixture's "kitchen-sink" book; assert every mapped field (multi-author order preserved, series+index, tags, rating, publisher, julian→Date conversion correct (compare to an explicit Date), languages, identifiers, comments HTML verbatim, custom columns scalar + multiple in rawMetadata with namespaced keys `calibre.custom.<label>`).
- `preservesUnsupportedValuesInRawPayload` — pages/lccn land in rawMetadata (`calibre.pages`, `calibre.lccn`).
- `resolvesFormatsAndCovers` — formats resolve to existing files with correct sizes; covers resolve both from BLOB and from `cover.jpg` file.
- `opfCrossCheckFallsBackWhenDatabaseIncomplete` — a book whose DB title/authors are empty but whose `metadata.opf` has them: reader falls back to OPF values.
- `rejectsUnsupportedSchemaVersion` — a fixture with `PRAGMA user_version = 99` throws `CalibreReaderError.unsupportedSchemaVersion(99)`.
- `doesNotModifySourceLibrary` — record `metadata.db` mtime + SHA-256 before and after a full `books()` read; assert identical.

- [ ] **Step 2: Run the reader tests to verify RED**

```bash
xcodegen generate --spec project.yml
xcodebuild -project BookManager.xcodeproj -scheme BookManager -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:BookManagerCoreTests/CalibreReaderTests test
```

Expected: compilation fails (`CalibreReader` etc. undefined).

- [ ] **Step 3: Implement the models, schema adapter, and reader**

- `CalibreModels.swift` — the DTOs above (all `Sendable`).
- `CalibreSchema.swift` — `CalibreSchemaAdapting` protocol with the SQL surface; `CalibreSchema26` implementing it; `enum CalibreReaderError: Error, Equatable { case missingMetadataDatabase(URL), unsupportedSchemaVersion(Int), notACalibreLibrary(URL) }`; defensive helper `columns(in:table:)` via `PRAGMA table_info` so optional columns (`books.pages`, `books.lccn`, `data.path`, `books_languages_link.lang`) degrade gracefully.
- `CalibreReader.swift` — `static func open(libraryURL:)` locates `metadata.db` (accept either the library folder or the db file itself), opens a `DatabaseQueue` with `Configuration().readOnly = true`, validates `PRAGMA user_version == 26`, reads `library_id`; `summary()` counts books (`SELECT COUNT(*) FROM books`) and formats (`SELECT COUNT(*) FROM data`); `books()` enumerates ordered by `books.id` and builds `CalibreBookRecord` per book with:
  - authors ordered by `books_authors_link.id` (`ORDER BY id`);
  - series via `books_series_link` joined to `series`, index from `books.series_index` (or the link table fallback);
  - tags, rating (first non-null), publisher, dates (julian conversion), languages, identifiers (`type`→`val`, case-insensitive dedupe by type), comments (`text` verbatim);
  - formats from `data` joined to `book.path`, file URL = `<library>/<book.path>/<name>.<format.lowercased()>` with existence check (missing format files are reported as `failed`-eligible or skipped with a note — decide: a missing format file yields an import failure for that book, consistent with Slice 2's `missingFormatFiles` semantics);
  - cover: BLOB when `cover` is non-empty, else `<library>/<book.path>/cover.jpg` when `has_cover` and the file exists, else nil;
  - rawMetadata: custom columns (`calibre.custom.<label>`, JSON-encoded typed value; scalar table `custom_column_N`, multiple via `books_custom_column_N_link`) + `calibre.pages`/`calibre.lccn` when present;
  - OPF cross-check: parse `<library>/<book.path>/metadata.opf` with a small `XMLParser` delegate (reuse the `OPFParser` pattern from `MetadataExtractor` if accessible — it is `private`; either extract it or write a local `CalibreOPFParser`); if the DB title is empty or authors are empty, fill from OPF; keep `opfPath` on the record.

- [ ] **Step 4: Run the reader tests**

Run the command from Step 2. Expected: all seven tests pass. Verify the julian conversion against a hand-computed Date in the test.

- [ ] **Step 5: Run the full core suite**

```bash
xcodebuild -project BookManager.xcodeproj -scheme BookManager -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:BookManagerCoreTests test
```

- [ ] **Step 6: Commit**

```bash
git add BookManagerCore/Calibre BookManagerCoreTests/Calibre BookManager.xcodeproj
git commit -m "feat: read Calibre user_version-26 libraries"
```

### Task 3: Calibre Import Service with Resume

**Files:**

- Create: `BookManagerCore/Calibre/CalibreImportService.swift`
- Create: `BookManagerCoreTests/Calibre/CalibreImportServiceTests.swift`

**Interfaces:**

- Consumes: `CalibreReader`/`CalibreBookRecord` (Task 2), `NewBookMetadata.rawMetadata` (Task 1), `LibraryRepositoryImporting` (Slice 2), `BookFolder` staging.
- Produces: `CalibreImportProgress` (Codable; source path hash, selection, completed book ids), `CalibreImportItem { calibreID, title, status (.imported(UUID) | .duplicate(UUID) | .failed(String) | .skipped) }`, `CalibreImportReport { items, imported, duplicates, failed, skipped, summary }`, and the `CalibreImportService` actor:
  - `importBooks(_ records: [CalibreBookRecord], selection: [Int]?, into repository: LibraryRepositoryImporting) async throws -> CalibreImportReport`
  - resume: progress stored at `<library control root>/calibre-imports/<sourcePathHash>/progress.json`; completed book ids are skipped on re-run.

- [ ] **Step 1: Write the service tests**

Create `BookManagerCoreTests/Calibre/CalibreImportServiceTests.swift` (reuse the Slice 2 `MemoryRepository` double pattern — if it is `private` in `ImportServiceTests.swift`, move it to a shared test helper or duplicate it here):

- `importsAllSelectedBooks` — build a 3-book fixture, select all, assert 3 imported, report summary correct, and each book materialized through the repository double with `metadata.rawMetadata` populated.
- `subsetSelectionImportsOnlySelected` — select 2 of 3, assert 2 imported, 1 not present.
- `exactDuplicatesAreSkipped` — pre-register one format hash in the double; re-import → that book reports `.duplicate`, others imported; the duplicate's files are never staged into the double (no silent copy).
- `resumeSkipsCompletedBooks` — run with a deliberately failing repository for the second book (e.g. a double that throws for one calibreID), assert 1 imported + 1 failed; re-run the SAME selection with a healthy double → the first (completed) is `.skipped`, the failed one imports; assert progress file contents.
- `progressFileIsWrittenUnderControlRoot` — after an import, `<layout.controlRoot>/calibre-imports/<hash>/progress.json` exists and decodes.

- [ ] **Step 2: Run to verify RED**

```bash
xcodegen generate --spec project.yml
xcodebuild -project BookManager.xcodeproj -scheme BookManager -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:BookManagerCoreTests/CalibreImportServiceTests test
```

Expected: compilation fails (`CalibreImportService` undefined).

- [ ] **Step 3: Implement the service**

Per-book pipeline (mirroring `ImportService.importFiles`): for each selected, non-completed record — stage every format file through `BookFolder.stage(from:)`; for each staged file run `repository.bookIDs(byFormatHash:)`; if ANY format hash matches, report `.duplicate` and remove staged files (no silent copy; the whole book is skipped, matching Slice 2's per-file semantics but at book granularity — document this choice); else compute the likely-duplicate hint (normalized title + first author via `allBooksForDuplicateCheck()`), map to `NewBookMetadata` (title, authors, series, seriesIndex, tags, rating, publisher, publicationDate, addedDate, languages, identifiers, comments, rawMetadata), stage the cover (BLOB → write to a temp file for staging; file → stage directly), and call `repository.createBook(metadata:staged:cover:)`. Update the progress record after each book (write atomically). Wrap each book in do/catch → `.failed(error.localizedDescription)`.

`CalibreImportProgress`:

```swift
public struct CalibreImportProgress: Codable, Sendable {
    public var sourcePath: String
    public var libraryID: String
    public var selection: [Int]?          // nil = all
    public var completedBookIDs: [Int]
}
```

Source path hash = SHA-256 of the canonical source path, first 32 hex chars. Progress file: `<controlRoot>/calibre-imports/<hash>/progress.json`.

- [ ] **Step 4: Run the service tests**

Run the command from Step 2. Expected: all five tests pass.

- [ ] **Step 5: Run the full core suite**

```bash
xcodebuild -project BookManager.xcodeproj -scheme BookManager -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:BookManagerCoreTests test
```

- [ ] **Step 6: Commit**

```bash
git add BookManagerCore/Calibre BookManagerCoreTests/Calibre
git commit -m "feat: resumable Calibre library import"
```

### Task 4: Calibre Import Wizard (App)

**Files:**

- Create: `BookManager/Views/CalibreImportView.swift`
- Modify: `BookManager/Stores/LibrarySession.swift`
- Modify: `BookManager/Views/ContentView.swift`

**Interfaces:**

- Consumes: `CalibreReader`, `CalibreImportService`, `CalibreImportReport` (Tasks 2-3), session repository.
- Produces: session state (`calibreSummary: CalibreLibrarySummary?`, `calibreImportReport: CalibreImportReport?`, `calibreBooks: [CalibreBookRecord]`, `calibreSelectedIDs: Set<Int>`, `calibreImportProgress: Double?`, error surfacing via `lastError`) and actions (`selectCalibreLibrary(at:)`, `importCalibre()`), plus the wizard view and a ContentView entry point ("Import from Calibre…" toolbar button, shown when the library is loaded).

- [ ] **Step 1: Session actions**

- `selectCalibreLibrary(at url: URL) async`: opens `CalibreReader` (errors → `lastError`, e.g. unsupported schema version), loads `summary()` + `books()`, default-selects all book ids.
- `importCalibre() async`: builds the service over `repository.root`, runs `importBooks(records, selection: nil-or-selected, into: repository)`, sets `calibreImportReport`, refreshes the browser afterwards.

- [ ] **Step 2: Wizard view**

`CalibreImportView` (sheet):

- Header: source name, `userVersion`, counts (`N books · M formats`), read-only note.
- List of books (title + author + formats) with per-row toggle; Select All / Clear; disabled Import when nothing selected.
- Progress: `ProgressView(value:)` over `calibreImportProgress` while running; then a report section (imported/duplicates/failed/skipped rows) with Done.
- Errors (unsupported version, missing db, read failure) render in the sheet via `session.lastError`.

- [ ] **Step 3: ContentView entry point**

A toolbar button "Import from Calibre…" (systemImage "tray.and.arrow.down") enabled only when `session.state == .loaded`; on click, present a `fileImporter` for a folder (reuse the `isPickerPresented`/`pickerPurpose` pattern — extend `PickerPurpose` with `.calibre`), then `Task { await session.selectCalibreLibrary(at: urls[0]); showCalibreImport = session.calibreSummary != nil }`; `.sheet(isPresented: $showCalibreImport) { CalibreImportView() }`.

- [ ] **Step 4: Build and full suite**

```bash
xcodegen generate --spec project.yml
xcodebuild -project BookManager.xcodeproj -scheme BookManager -destination 'platform=macOS' -derivedDataPath .build/DerivedData build
xcodebuild -project BookManager.xcodeproj -scheme BookManager -destination 'platform=macOS' -derivedDataPath .build/DerivedData test
```

Expected: build with no NEW warnings from files you touch; all core + UI tests green (58 core + 2 UI + new core suites).

- [ ] **Step 5: Commit**

```bash
git add BookManager BookManager.xcodeproj
git commit -m "feat: add Calibre import wizard"
```

### Task 5: Slice Verification and Documentation

**Files:**

- Modify: `README.md`
- Modify: `docs/superpowers/specs/2026-07-29-book-manager-design.md`

- [ ] **Step 1: Update README**

In the Slices section, change Slice 3 to "**Calibre migration** — implemented (this slice: import a copy of a Calibre library read-only, map full metadata, preserve custom columns and unsupported values, resumable import, report)". Update the feature summary line to mention Calibre import.

- [ ] **Step 2: Update the design spec status**

In `docs/superpowers/specs/2026-07-29-book-manager-design.md` Implementation Status block, change Slice 3 to "implemented and verified".

- [ ] **Step 3: Static checks and clean build + full suite**

```bash
xcodegen generate --spec project.yml
git diff --check
xcodebuild -project BookManager.xcodeproj -scheme BookManager -destination 'platform=macOS' -derivedDataPath .build/DerivedData analyze
xcodebuild -project BookManager.xcodeproj -scheme BookManager clean
xcodebuild -project BookManager.xcodeproj -scheme BookManager -destination 'platform=macOS' -derivedDataPath .build/DerivedData test
```

Expected: ANALYZE SUCCEEDED, CLEAN SUCCEEDED, TEST SUCCEEDED.

- [ ] **Step 4: Acceptance note**

The supplied 13-book acceptance library is used read-only by the human partner: import it via the wizard, verify counts (13 books / 13 formats) and that `metadata.db` mtime + content hash are unchanged afterward. This step is manual; record the outcome in the commit message or a follow-up note.

- [ ] **Step 5: Commit documentation**

```bash
git add README.md docs/superpowers/specs/2026-07-29-book-manager-design.md
git commit -m "docs: document Calibre migration"
```

- [ ] **Step 6: Confirm the repository is clean**

```bash
git status --short --branch
```

Expected: branch header only.
