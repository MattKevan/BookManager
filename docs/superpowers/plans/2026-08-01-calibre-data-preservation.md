# Calibre Data Preservation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Importing a Calibre library (schema versions 26 and 27) preserves every per-book datum — source identity, sort keys, modified date, original path, page counts, conversion options, original format names, duplicate identifiers, annotation search text, and full custom-column definitions — without a single schema or catalog migration.

**Architecture:** The reader gains a second schema adapter (`CalibreSchema27`, trivially thin — the verified 26→27 delta is: `books_pages_link` table + trigger + index, `meta` view recreated, `flags`/`isbn`/`lccn` columns dropped) behind the existing `CalibreSchemaAdapting` protocol, plus table-guarded fetchers for page counts and conversion options. `CalibreBookRecord` grows structured fields; `record()` folds them into the existing namespaced `rawMetadata` payload as JSON strings (the established `calibre.annotations` pattern) — so the import pipeline and Automerge schema v2 are untouched. `date(fromText:)` treats sub-1000-year dates (calibre-web's `0101-01-01` sentinel) as nil, and `series_index` decodes storage-class-tolerantly.

**Tech Stack:** Swift 6.0 (strict concurrency), GRDB 7.11, Swift Testing, XcodeGen. Sandboxed macOS app; core framework `BookManagerCore`.

## Global Constraints

- macOS 26 deployment target; Swift 6.0 with `SWIFT_STRICT_CONCURRENCY: complete`.
- **No Automerge schema bump, no catalog migration**: `rawMetadata` stays flat `[String: String]`; structured payloads are JSON strings under namespaced keys.
- Verified schema facts (from kovidgoyal/calibre `resources/metadata_sqlite.sql` + `schema_upgrades.py` upgrade_version_26): current Calibre creates `user_version=27`; v27 = v26 minus `flags`/`isbn`/`lccn` books columns plus `books_pages_link(book PK, pages, algorithm, format, format_size, timestamp, needs_scan)` (+ `books_pages_link_create_trigger`, `books_pages_link_pidx`, backfill `needs_scan=1`). `conversion_options(id, format, book, data BLOB)` and `annotations.searchable_text` exist in both versions.
- calibre-web writes ISO-8601 TEXT dates (root cause of the already-fixed `ca7d83e` crash), a `0101-01-01 00:00:00+00:00` sentinel pubdate, and can create TEXT-affinity `series_index` tables.
- Existing behavior must not change: the 87-test core suite stays green; `mapsFullMetadataMatrix`, `numericCustomColumnsDecodeWithoutCrash`, `textDatesDecodeWithoutCrash`, `blobCoversArePassedThrough` (asserts `calibre.pages == "320"` from the legacy `books.pages` variant column) all keep passing.
- Tests: Swift Testing (`@Suite`/`@Test`/`#expect`); xcodebuild with `-derivedDataPath .build/DerivedData`; fixture conventions in `CalibreFixture` (DDL subset of the authoritative SQL, variants via named builders).
- Errors keep current semantics: a missing optional table degrades to an empty fetch, never a crash; per-book failures stay `.failed` in the report.

---

### Task 1: v27 schema support (adapter + open dispatch + fixture)

**Files:**

- Modify: `BookManagerCore/Calibre/CalibreSchema.swift`
- Modify: `BookManagerCore/Calibre/CalibreReader.swift` (`open(libraryURL:)`)
- Modify: `BookManagerCoreTests/Calibre/CalibreFixture.swift`
- Test: `BookManagerCoreTests/Calibre/CalibreReaderTests.swift`

**Interfaces:**

- Consumes: `CalibreSchemaAdapting` protocol (existing), `CalibreReaderError.unsupportedSchemaVersion(Int)` (existing).
- Produces: `CalibreSchema27` (accepted by `CalibreReader.open`), protocol methods `fetchPageCounts(_ db:) throws -> [(book: Int, pages: Int, algorithm: Int, format: String, formatSize: Int64)]` and `fetchConversionOptions(_ db:) throws -> [(book: Int, format: String, data: Data)]`, and `CalibreFixture.makeVariantLibrary(named:userVersion:extraColumns:)` accepting `userVersion: 27`.

- [ ] **Step 1: Write the failing test — a v27 library must open**

In `BookManagerCoreTests/Calibre/CalibreReaderTests.swift` add:

```swift
    @Test
    func opensV27LibraryWithPageCounts() throws {
        // Regression: current Calibre creates user_version 27; the reader
        // pinned to 26 rejected it wholesale. v27 adds books_pages_link and
        // drops the books isbn/lccn/flags columns.
        let library = try CalibreFixture.makeVariantLibrary(
            named: "v27-\(UUID().uuidString)", userVersion: 27, extraColumns: false
        )
        let reader = try CalibreReader.open(libraryURL: library)
        defer { try? reader.close() }
        let summary = try reader.summary()
        #expect(summary.userVersion == 27)

        let records = try reader.books()
        let range = try #require(records.first { $0.calibreID == 1 })
        #expect(range.pages?.pages == 320)
        #expect(range.pages?.algorithm == 2)
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild -project BookManager.xcodeproj -scheme BookManager -destination 'platform=macOS' -derivedDataPath .build/DerivedData test -only-testing:BookManagerCoreTests/CalibreReaderTests/opensV27LibraryWithPageCounts`
Expected: FAIL — `CalibreReaderError.unsupportedSchemaVersion(27)` thrown from `open`.

- [ ] **Step 3: Add the v27 fixture shape**

In `CalibreFixture.swift`, branch the DDL on `userVersion == 27`:

- `books` table WITHOUT `isbn`, `lccn`, `flags` columns (mirror the upgrade's DROP) — keep `pages`/`cover` only in the `extraColumns` variant, unchanged.
- Add to the v27 DDL:

```sql
CREATE TABLE books_pages_link (
    book INTEGER PRIMARY KEY, pages INTEGER DEFAULT 0 NOT NULL,
    algorithm INTEGER DEFAULT 0 NOT NULL, format TEXT DEFAULT '' NOT NULL COLLATE NOCASE,
    format_size INTEGER DEFAULT 0 NOT NULL, timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    needs_scan INTEGER NOT NULL DEFAULT 0 CHECK(needs_scan IN (0, 1)),
    FOREIGN KEY (book) REFERENCES books(id) ON DELETE CASCADE);
CREATE TRIGGER books_pages_link_create_trigger AFTER INSERT ON books FOR EACH ROW
    BEGIN INSERT INTO books_pages_link(book) VALUES(NEW.id); END;
CREATE TABLE conversion_options (
    id INTEGER PRIMARY KEY, format TEXT NOT NULL COLLATE NOCASE,
    book INTEGER, data BLOB NOT NULL, UNIQUE(format, book));
```

- The `books` INSERT must not reference the dropped columns when `userVersion == 27` (parameterize the column list, mirroring how `extraColumns` already parameterizes the DDL).
- In `insert(_:db:textDates:)`, for the v27 shape set `last_modified` to a realistic ISO string (e.g. `"2024-06-15 10:30:00+00:00"`), keep `uuid` as `"uuid-\(spec.id)"`, `sort`/`author_sort`/`path` as today.
- After the books insert, when v27 and `spec.id == 1`: `UPDATE books_pages_link SET pages = 320, algorithm = 2, format = 'EPUB', format_size = 12345 WHERE book = 1` and `INSERT INTO conversion_options(format, book, data) VALUES ('EPUB', 1, ?)` with a small `Data` blob.

- [ ] **Step 4: Implement the adapter split**

In `CalibreSchema.swift`:

- Rename the shared query implementations into a base class `CalibreSchemaBase` conforming to `CalibreSchemaAdapting` (move `CalibreSchema26`'s bodies verbatim; `static var supportedUserVersion` becomes a stored property the subclasses override).
- Add:

```swift
final class CalibreSchema26: CalibreSchemaBase {
    override static var supportedUserVersion: Int { 26 }
}

final class CalibreSchema27: CalibreSchemaBase {
    override static var supportedUserVersion: Int { 27 }
}
```

- Add the two protocol methods with base implementations, both table-guarded (empty when absent — this also makes v26 safe):

```swift
func fetchPageCounts(_ db: Database) throws -> [(book: Int, pages: Int, algorithm: Int, format: String, formatSize: Int64)] {
    guard try !columns(in: "books_pages_link", db).isEmpty else { return [] }
    return try Row.fetchAll(db, sql: """
        SELECT book AS book, pages AS pages, algorithm AS algorithm,
               format AS format, format_size AS format_size
        FROM books_pages_link
        """).map {
            (
                book: $0["book"] as Int,
                pages: $0["pages"] as Int,
                algorithm: $0["algorithm"] as Int,
                format: $0["format"] as String,
                formatSize: $0["format_size"] as Int64
            )
        }
}

func fetchConversionOptions(_ db: Database) throws -> [(book: Int, format: String, data: Data)] {
    guard try !columns(in: "conversion_options", db).isEmpty else { return [] }
    return try Row.fetchAll(db, sql: """
        SELECT book AS book, format AS format, data AS data
        FROM conversion_options
        """).map { (book: $0["book"] as Int, format: $0["format"] as String, data: $0["data"] as Data) }
}
```

- [ ] **Step 4b: Add the page-count model so the test compiles**

In `BookManagerCore/Calibre/CalibreModels.swift` add:

```swift
/// Page counts from the v27 `books_pages_link` table.
public struct CalibrePageCount: Sendable, Equatable {
    public let pages: Int
    public let algorithm: Int
    public let format: String
    public let formatSize: Int64

    public init(pages: Int, algorithm: Int, format: String, formatSize: Int64) {
        self.pages = pages
        self.algorithm = algorithm
        self.format = format
        self.formatSize = formatSize
    }
}
```

Add a `pages: CalibrePageCount?` field to `CalibreBookRecord` (property + init parameter, wired through in the memberwise init). Populate it in `CalibreReader.record()` from the Task 1 `fetchPageCounts` result (keyed by book id, built in `makeLookups`). Task 2 adds the remaining record fields; do not add them here.

- [ ] **Step 5: Dispatch the adapter by version in `CalibreReader.open`**

Replace the hard-coded `let schema = CalibreSchema26()` with a version lookup: read `PRAGMA user_version` first (via `CalibreSchemaBase().userVersion(db)`), then:

```swift
let schema: any CalibreSchemaAdapting
switch version {
case CalibreSchema26.supportedUserVersion: schema = CalibreSchema26()
case CalibreSchema27.supportedUserVersion: schema = CalibreSchema27()
default: throw CalibreReaderError.unsupportedSchemaVersion(version)
}
```

Keep `validate` unchanged (`schema.validate(db, libraryURL:)` — the schema-version assertion now succeeds for both). The `validate` guard for the books table stays.

- [ ] **Step 6: Run the failing test to verify it passes, then the full suite**

Run the focused test, then `-only-testing:BookManagerCoreTests`. Expected: focused test passes; the full core suite stays 87/87 (the fixture's v26 shape is unchanged for `userVersion == 26`, so no existing test changes behavior).

- [ ] **Step 7: Commit**

```bash
git add BookManagerCore/Calibre/CalibreSchema.swift BookManagerCore/Calibre/CalibreReader.swift BookManagerCoreTests/Calibre/CalibreFixture.swift BookManagerCoreTests/Calibre/CalibreReaderTests.swift
git commit -m "feat: support Calibre user_version 27 libraries (books_pages_link, conversion_options)"
```

---

### Task 2: Preserve the remaining per-book data (fields + raw keys)

**Files:**

- Modify: `BookManagerCore/Calibre/CalibreModels.swift`
- Modify: `BookManagerCore/Calibre/CalibreSchema.swift` (extend `CalibreCustomColumn`, `fetchCustomValues` → `extra`, `fetchAnnotations` keys, `customColumns` query)
- Modify: `BookManagerCore/Calibre/CalibreReader.swift` (`makeLookups`, `record`)
- Modify: `BookManagerCoreTests/Calibre/CalibreFixture.swift` (populate new columns; v26 + v27)
- Test: `BookManagerCoreTests/Calibre/CalibreReaderTests.swift`

**Interfaces:**

- Consumes: Task 1's `fetchPageCounts`/`fetchConversionOptions`; the existing `BookLookups`, `CalibreCustomColumn`, `CalibreBookRecord`.
- Produces:
  - `CalibreBookRecord` gains: `sourceUUID: String?`, `titleSort: String?`, `authorSort: String?`, `lastModified: Date?`, `sourcePath: String?`, `pages: CalibrePageCount?`, `conversionOptions: [(format: String, data: Data)]`, `originalFormats: [CalibreOriginalFormat]`, `extraIdentifiers: [String: [String]]`, `customColumnDefinitions: [String: CalibreColumnDefinition]`.
  - New public structs in `CalibreModels.swift`: `CalibrePageCount { pages, algorithm, format, formatSize }`, `CalibreOriginalFormat { format, name, path? }`, `CalibreColumnDefinition { name, datatype, display, isMultiple, editable, normalized }`.
  - `CalibreCustomColumn` gains `display: String`, `editable: Bool`, `normalized: Bool`, `markForDelete: Bool`.
  - `fetchCustomValues` returns `[(book: Int, value: String?, extra: String?)]`.
  - `CalibreReader` static helpers `double(fromDatabaseValue:)` and `isoString(from:)`.
  - The `rawMetadata` keys documented in the table below.

- [ ] **Step 1: Write the failing tests — every new field lands, sentinel date is nil, TEXT series_index decodes**

In `CalibreReaderTests.swift` add:

```swift
    @Test
    func preservesSourceIdentityAndPayload() throws {
        let library = try CalibreFixture.makeLibrary(named: "preserve-\(UUID().uuidString)")
        let record = try book(1, from: library)

        #expect(record.sourceUUID == "uuid-1")
        #expect(record.titleSort == "Range: Why Generalists Triumph in a Specialized World")
        #expect(record.authorSort == "Epstein, David")
        #expect(record.sourcePath == "David Epstein/Range (1)")
        #expect(record.rawMetadata["calibre.uuid"] == "uuid-1")
        #expect(record.rawMetadata["calibre.titleSort"] == "Range: Why Generalists Triumph in a Specialized World")
        #expect(record.rawMetadata["calibre.authorSort"] == "Epstein, David")
        #expect(record.rawMetadata["calibre.sourcePath"] == "David Epstein/Range (1)")
        #expect(record.rawMetadata["calibre.lastModified"] != nil)
        #expect(record.rawMetadata["calibre.originalFormats"] != nil)
        #expect(record.rawMetadata["calibre.customColumns"] != nil)
        // Multi-value link extra surfaces as a parallel key.
        #expect(record.rawMetadata["calibre.custom.shelves.extra"] != nil)
    }

    @Test
    func calibreWebSentinelDateIsNilAndTextSeriesIndexDecodes() throws {
        // calibre-web writes "0101-01-01 00:00:00+00:00" (year-101 sentinel)
        // for missing pubdates — must import as nil, not year 101 — and can
        // create TEXT-affinity series_index tables.
        let library = try CalibreFixture.makeTextDateLibrary(named: "sentinel-\(UUID().uuidString)")
        let reader = try CalibreReader.open(libraryURL: library)
        defer { try? reader.close() }
        let records = try reader.books()
        let range = records.first { $0.calibreID == 1 }!
        #expect(range.publicationDate == nil)
        #expect(range.seriesIndex == 1.5)
        // Book 1's v26 base fixture has no books_pages_link; the sentinel
        // variant must not change the julian-date test.
        let records2 = try CalibreReader.open(libraryURL: library)
        defer { try? records2.close() }
    }
```

Then in `CalibreImportServiceTests.swift` add an end-to-end assertion (Task 3 placeholder here — implement in Task 3; Step 1 above is the reader-level gate).

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild ... test -only-testing:BookManagerCoreTests/CalibreReaderTests/preservesSourceIdentityAndPayload -only-testing:BookManagerCoreTests/CalibreReaderTests/calibreWebSentinelDateIsNilAndTextSeriesIndexDecodes`
Expected: FAIL — `CalibreBookRecord` has no member `sourceUUID`; sentinel test fails on `publicationDate != nil` (year 101) before the tolerant read exists.

- [ ] **Step 3: Extend the fixture with the preservation columns**

In `CalibreFixture.swift`:

- `BookSpec` gains `lastModifiedText: String?` (default nil → the insert uses `"2024-06-15 10:30:00+00:00"`).
- The `textDates` insert variant writes book 1's `pubdate` as `"0101-01-01 00:00:00+00:00"` (sentinel) instead of the julian date, and book 1's `series_index` as the TEXT string `"1.5"` (calibre-web shape). Keep `textDates` for all other books as-is.
- v26 base fixture: ensure `books.uuid` (already `"uuid-\(id)"`), `sort`, `author_sort`, `path`, `last_modified` are populated (they are; assert only).

- [ ] **Step 4: Implement the model + schema extensions**

In `CalibreModels.swift` add the three structs and the new `CalibreBookRecord` fields (append to the existing init with defaults where sensible — keep the init explicit, no default values that hide data). In `CalibreSchema.swift`: extend `CalibreCustomColumn` and its `customColumns` SELECT to also fetch `display`, `editable`, `normalized`, `mark_for_delete`; extend `fetchCustomValues`:

```swift
func fetchCustomValues(_ db: Database, column: CalibreCustomColumn) throws -> [(book: Int, value: String?, extra: String?)] {
    if column.isMultiple {
        let table = "books_custom_column_\(column.id)_link"
        guard try !columns(in: table, db).isEmpty else { return [] }
        return try Row.fetchAll(db, sql: "SELECT book AS book, value AS value, extra AS extra FROM \(table) ORDER BY book, id")
            .map { (book: $0["book"] as Int, value: Self.valueString($0["value"]?.databaseValue), extra: Self.valueString($0["extra"]?.databaseValue)) }
    }
    // single-value table unchanged, extra nil
}
```

Extend `fetchAnnotations`'s `groupJSON` keys to `["format", "user_type", "user", "annot_id", "annot_type", "annot_data", "searchable_text", "timestamp"]` (add the two columns to the SELECT; `timestamp` is REAL → the existing storage-class switch stringifies it).

- [ ] **Step 5: Implement `makeLookups`/`record` in `CalibreReader`**

- `makeLookups`: fetch page counts and conversion options once per pass; `fetchCustomValues` now returns `extra` — for multi-value columns, collect `extras` alongside `values` into `lookups.raw` under `calibre.custom.<label>` (values, as today) plus `calibre.custom.<label>.extra` (JSON array of extras, only when any is non-nil).
- Add a per-pass `columnDefinitions: [String: CalibreColumnDefinition]` built from `schema.customColumns(db)` keyed by `label`; in `record()`, include in `raw["calibre.customColumns"]` only labels present in that book's `calibre.custom.*` keys (JSON-encode `[label: {name, datatype, isMultiple, display, editable, normalized}]`).
- `record()`:
  - Read `uuid`, `sort`, `author_sort`, `last_modified`, `path` from the row (storage-tolerant reads: `row["uuid"] as String?` etc. are TEXT-safe; `last_modified` via `date(fromDatabaseValue:)`).
  - `originalFormats` from the existing `formats` lookups + `dataColumns.contains("path")` override (already resolved per record — carry `name` and the `path` override).
  - `extraIdentifiers`: in `makeLookups`, keep first-per-type in `lookups.identifiers` (as today) and collect the remainder into a `[Int: [String: [String]]]` → `raw["calibre.extraIdentifiers"]` (JSON).
  - `conversionOptions` and `pages` from the Task 1 fetchers (pages: prefer `books_pages_link`; fall back to the legacy `books.pages` column read only when the column exists, preserving the `blobCoversArePassedThrough` `"320"` assertion).
  - Add the new flat keys to `raw`:

```swift
if let sourceUUID { raw["calibre.uuid"] = sourceUUID }
if let titleSort { raw["calibre.titleSort"] = titleSort }
if let authorSort { raw["calibre.authorSort"] = authorSort }
if let lastModified { raw["calibre.lastModified"] = Self.isoString(from: lastModified) }
if let sourcePath { raw["calibre.sourcePath"] = sourcePath }
if let pages { raw["calibre.pages"] = "\(pages.pages)" }
if !conversionOptions.isEmpty { raw["calibre.conversionOptions"] = Self.jsonString(...) }
if !originalFormats.isEmpty { raw["calibre.originalFormats"] = Self.jsonString(...) }
if !extraIdentifiers.isEmpty { raw["calibre.extraIdentifiers"] = Self.jsonString(...) }
if !customColumnDefinitions.isEmpty { raw["calibre.customColumns"] = Self.jsonString(...) }
```

- `date(fromText:)`: after parsing, `guard let year = Calendar(identifier: .gregorian).dateComponents([.year], from: date).year, year >= 1000 else { return nil }` (sentinel → nil).
- `series_index`: replace `row["series_index"] as Double?` with `Self.double(fromDatabaseValue: row["series_index"]?.databaseValue)`; add the helper:

```swift
static func double(fromDatabaseValue value: DatabaseValue?) -> Double? {
    guard let value else { return nil }
    switch value.storage {
    case .double(let d): return d
    case .int64(let i): return Double(i)
    case .string(let s): return Double(s)
    case .blob, .null: return nil
    }
}
```

- JSON-string helpers (`jsonString(_:)`, `isoString(from:)`) are private static, created per call (Swift 6 concurrency — no shared non-Sendable formatter).

- [ ] **Step 6: Run the tests to verify they pass, then the full suite**

Run the two focused tests, then `-only-testing:BookManagerCoreTests`. Expected: focused tests pass; full core suite 87/87 (existing assertions — `mapsFullMetadataMatrix` raw keys, `calibre.pages == "320"` — unchanged).

- [ ] **Step 7: Commit**

```bash
git add BookManagerCore/Calibre/CalibreModels.swift BookManagerCore/Calibre/CalibreSchema.swift BookManagerCore/Calibre/CalibreReader.swift BookManagerCoreTests/Calibre/CalibreFixture.swift BookManagerCoreTests/Calibre/CalibreReaderTests.swift
git commit -m "feat: preserve calibre source identity, sort keys, pages, conversion options, custom columns, annotation search text"
```

---

### Task 3: End-to-end import preserves the payload

**Files:**

- Test: `BookManagerCoreTests/Calibre/CalibreImportServiceTests.swift`
- (No production changes unless the test exposes a gap — the reader already fills `rawMetadata` and `CalibreImportService.importOne` passes it through.)

**Interfaces:**

- Consumes: `CalibreImportService`, `CalibreMemoryRepository` (existing test double capturing `NewBookMetadata`), Task 1/2 fixtures.

- [ ] **Step 1: Write the failing end-to-end test**

```swift
    @Test
    func importPreservesRawPayloadEndToEnd() async throws {
        let layout = try layout()
        let service = CalibreImportService(layout: layout)
        let repository = CalibreMemoryRepository()
        let library = try CalibreFixture.makeVariantLibrary(
            named: "svc-v27-\(UUID().uuidString)", userVersion: 27, extraColumns: false
        )
        let reader = try CalibreReader.open(libraryURL: library)
        let records = try reader.books()
        try reader.close()

        let report = try await service.importBooks(
            records, from: library.path,
            libraryID: "acceptance-fixture-uuid",
            selection: [1], into: repository
        )
        #expect(report.imported.count == 1)

        let created = try #require(await repository.createdBooks().first)
        let raw = created.metadata.rawMetadata ?? [:]
        #expect(raw["calibre.uuid"] == "uuid-1")
        #expect(raw["calibre.titleSort"] == "Range: Why Generalists Triumph in a Specialized World")
        #expect(raw["calibre.authorSort"] == "Epstein, David")
        #expect(raw["calibre.sourcePath"] == "David Epstein/Range (1)")
        #expect(raw["calibre.pages"] == "320")
        #expect(raw["calibre.conversionOptions"] != nil)
        #expect(raw["calibre.originalFormats"] != nil)
        #expect(raw["calibre.customColumns"] != nil)
        #expect(raw["calibre.custom.genre"] == "science")
        #expect(raw["calibre.custom.shelves"] != nil)
    }
```

- [ ] **Step 2: Run the test to verify it fails or passes**

Run: `xcodebuild ... test -only-testing:BookManagerCoreTests/CalibreImportServiceTests/importPreservesRawPayloadEndToEnd`
Expected: PASS if Tasks 1–2 are complete (this test is the end-to-end gate; if it fails, the gap is in the reader mapping and must be fixed here — do not relax the assertions).

- [ ] **Step 3: Run the full core suite**

Run: `xcodebuild ... test -only-testing:BookManagerCoreTests`. Expected: 90 tests in 14 suites pass (87 + Task 1's `opensV27LibraryWithPageCounts` + Task 2's two tests).

- [ ] **Step 4: Commit**

```bash
git add BookManagerCoreTests/Calibre/CalibreImportServiceTests.swift
git commit -m "test: end-to-end calibre import preserves the raw payload"
```

---

## Self-Review

- **Spec coverage:** v27 acceptance → Task 1. Every `rawMetadata` key in the spec's table → Task 2 (uuid, titleSort, authorSort, lastModified, sourcePath, pages, conversionOptions, originalFormats, extraIdentifiers, customColumns + link extra + annotations searchable_text/timestamp). Sentinel date + TEXT series_index → Task 2. No schema/catalog migration → Global Constraints + Task 2 (flat raw keys only). End-to-end proof → Task 3. Acceptance criterion "v27 imports with books/formats/covers intact" → Task 1 + Task 3.
- **Placeholder scan:** no TBDs; every step has concrete code or an exact command. Task 3 Step 2's "fix here if it fails" is a gate, not a placeholder.
- **Type consistency:** `CalibreSchema27`, `fetchPageCounts`, `fetchConversionOptions`, `CalibrePageCount`, `CalibreOriginalFormat`, `CalibreColumnDefinition`, `double(fromDatabaseValue:)`, `isoString(from:)`, `calibre.custom.<label>.extra` are defined once and used with matching names across tasks. `fetchCustomValues` signature change (extra) is applied in Task 2 Step 4 and consumed in Task 2 Step 5. `CalibreBookRecord` init grows in Task 2 Step 4; Task 1's `opensV27LibraryWithPageCounts` reads `range.pages` which Task 1 must make compile-ready — note: Task 1's test references `range.pages?.pages`, so Task 1 Step 3 must include a minimal `CalibreBookRecord.pages` field (or Task 2's field set lands with Task 1's test adjusted). **Resolution:** add `pages` (and only `pages`) to `CalibreBookRecord` in Task 1 so its test compiles; Task 2 adds the rest.
