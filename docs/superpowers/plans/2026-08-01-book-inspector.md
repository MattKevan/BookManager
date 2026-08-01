# Right Inspector Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A right-side inspector panel (macOS 26 `.inspector`) showing the selected book's cover and full metadata — read-only, with an Edit path into the existing editor sheet — plus a collapsible "Calibre Source Data" section rendering the preserved raw payload with friendly custom-column names.

**Architecture:** `IndexedBook` gains `rawMetadata: [String: String]?` exposed through a disposable-catalog v3 migration (GRDB `DatabaseMigrator`, drop+recreate the `book` table — same pattern as `v2ExpandedBook`). A pure, tested `CalibreRawPresenter` maps the payload to display rows. The app layer adds `session.inspectorPresented` + auto-show on single selection, attaches `.inspector` to the `NavigationSplitView` in `ContentView`, and renders `BookInspectorView`. No Automerge schema change.

**Tech Stack:** Swift 6.0 (strict concurrency), SwiftUI (macOS 26 inspector), GRDB 7.11 (DatabaseMigrator), Swift Testing, XcodeGen.

## Global Constraints

- macOS 26 deployment target; Swift 6.0 with `SWIFT_STRICT_CONCURRENCY: complete`; `LibrarySession` is `@MainActor @Observable` in the app target.
- **No Automerge schema or change-store change.** `rawMetadata` already lives in the Automerge document; this plan only exposes it through the disposable catalog (rebuilt from changes — dropping the `book` table in a migration is safe, established precedent: `v2ExpandedBook`).
- Existing tests keep passing: core suite is 91 tests in 14 suites (Plan 1 merged); `LocalCatalogTests`/`LocalCatalogV2Tests`/`CalibreReaderTests`/`CalibreImportServiceTests` behavior unchanged.
- UI-test automation is environmental in this session (headless); the inspector UI is verified by build + manual run (residual for the human), not by UI tests.
- Tests: Swift Testing; xcodebuild with `-derivedDataPath .build/DerivedData`; the single-test `-only-testing:.../TestName` identifier quirk means suite-level runs give real results.

---

### Task 1: Catalog v3 — expose `rawMetadata` on `IndexedBook`

**Files:**
- Modify: `BookManagerCore/Persistence/IndexedBook.swift`
- Modify: `BookManagerCore/Persistence/LocalCatalog.swift`
- Modify: `BookManagerCore/Library/LibraryRepository.swift` (`makeIndexedBook`)
- Create: `BookManagerCoreTests/Persistence/LocalCatalogV3Tests.swift`
- Test: `BookManagerCoreTests/Persistence/LocalCatalogTests.swift` (if needed — existing suite must stay green)

**Interfaces:**
- Consumes: `JSONCoding.encode/decode` (existing), the GRDB `DatabaseMigrator` pattern from `LocalCatalog`, `ResolvedBook.rawMetadata` (Automerge, existing).
- Produces: `IndexedBook.rawMetadata: [String: String]?` (property, `==`, init default `nil`, `FetchableRecord` decode), catalog column `rawMetadata` (nullable TEXT), `LibraryRepository.makeIndexedBook` fills it from the document.

- [ ] **Step 1: Write the failing tests**

Create `BookManagerCoreTests/Persistence/LocalCatalogV3Tests.swift`:

```swift
import Foundation
import GRDB
import Testing
@testable import BookManagerCore

@Suite
struct LocalCatalogV3Tests {
    private func catalog() throws -> LocalCatalog {
        let databaseURL = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).sqlite")
        return try LocalCatalog(databaseURL: databaseURL)
    }

    private func book(
        id: UUID = UUID(),
        title: String = "Range",
        rawMetadata: [String: String]? = nil
    ) -> IndexedBook {
        IndexedBook(
            id: id, title: title, authors: ["David Epstein"],
            rawMetadata: rawMetadata,
            modifiedMilliseconds: 1_000, isDeleted: false, snapshot: Data([1, 2, 3])
        )
    }

    @Test
    func rawMetadataRoundTripsThroughUpsert() async throws {
        let catalog = try catalog()
        let payload = ["calibre.uuid": "uuid-1", "calibre.pages": "320"]
        let id = UUID()
        try await catalog.upsert(book(id: id, rawMetadata: payload))

        let stored = try await catalog.book(id: id)
        #expect(stored?.rawMetadata == payload)
        // Nil payload round-trips as nil, not an empty dict.
        try await catalog.upsert(book(id: UUID(), title: "NoPayload"))
        #expect(try await catalog.allBooks().first { $0.title == "NoPayload" }?.rawMetadata == nil)
    }

    @Test
    func equalityIncludesRawMetadata() {
        let id = UUID()
        let base = book(id: id)
        let withPayload = book(id: id, rawMetadata: ["calibre.uuid": "uuid-1"])
        #expect(base != withPayload)
        #expect(base == book(id: id))
    }

    @Test
    func v2DatabaseUpgradesToV3Schema() async throws {
        // Build a genuine v2 database exactly as createV2Schema did — book
        // table WITHOUT rawMetadata + FTS5 bookSearch + bookFacet +
        // bookFormatHash + the migrator's bookkeeping rows for 'createBookIndex'
        // and 'v2ExpandedBook' — insert a v2-shaped row, then reopen through
        // LocalCatalog. The v3 migration must run cleanly; the v2 row is
        // deliberately dropped (the catalogue is disposable and rebuilt from the
        // change store), so the assertion is that the upgrade runs and the v3
        // schema is live.
        let databaseURL = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).sqlite")
        let v2 = try DatabaseQueue(path: databaseURL.path)
        try await v2.write { db in
            try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
            try db.execute(sql: "INSERT INTO grdb_migrations(identifier) VALUES ('createBookIndex'), ('v2ExpandedBook')")
            try db.create(table: "book") { table in
                table.column("id", .text).primaryKey()
                table.column("title", .text).notNull()
                table.column("authors", .text).notNull()
                table.column("series", .text)
                table.column("seriesIndex", .double)
                table.column("tags", .text).notNull()
                table.column("rating", .integer)
                table.column("publisher", .text)
                table.column("publicationMilliseconds", .integer)
                table.column("addedMilliseconds", .integer)
                table.column("languages", .text).notNull()
                table.column("identifiers", .text).notNull()
                table.column("comments", .text)
                table.column("formats", .text).notNull()
                table.column("coverHash", .text)
                table.column("relativePath", .text).notNull()
                table.column("modifiedMilliseconds", .integer).notNull()
                table.column("isDeleted", .boolean).notNull()
                table.column("snapshot", .blob).notNull()
            }
            try db.create(virtualTable: "bookSearch", using: FTS5()) { table in
                table.column("bookID").notIndexed()
                table.column("title")
                table.column("authors")
                table.column("series")
                table.column("tags")
                table.column("identifiers")
                table.column("comments")
                table.tokenizer = .unicode61()
            }
            try db.create(table: "bookFacet") { table in
                table.column("type", .text).notNull()
                table.column("value", .text).notNull()
                table.column("bookID", .text).notNull()
                table.primaryKey(["type", "value", "bookID"])
            }
            try db.create(table: "bookFormatHash") { table in
                table.column("bookID", .text).notNull()
                table.column("kind", .text).notNull()
                table.column("contentHash", .text).notNull()
                table.primaryKey(["bookID", "kind", "contentHash"])
            }
            try db.execute(
                sql: "INSERT INTO book(id, title, authors, tags, languages, identifiers, formats, relativePath, modifiedMilliseconds, isDeleted, snapshot) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                arguments: [UUID().uuidString, "Old", "[\"A\"]", "[]", "[]", "{}", "[]", "p", 1_000, false, Data([9])]
            )
        }
        try v2.close()

        let catalog = try LocalCatalog(databaseURL: databaseURL)
        #expect(try await catalog.allBooks().isEmpty)

        // The v3 schema is live: upsert and read back a book with rawMetadata.
        try await catalog.upsert(book(title: "New", rawMetadata: ["calibre.uuid": "u"]))
        let after = try await catalog.allBooks()
        #expect(after.count == 1)
        #expect(after[0].rawMetadata == ["calibre.uuid": "u"])
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -project BookManager.xcodeproj -scheme BookManager -destination 'platform=macOS' -derivedDataPath .build/DerivedData test -only-testing:BookManagerCoreTests/LocalCatalogV3Tests`
Expected: FAIL — `IndexedBook` has no member `rawMetadata` (or the v3 migration doesn't exist → `no such column: rawMetadata`).

- [ ] **Step 3: Implement `IndexedBook.rawMetadata`**

In `BookManagerCore/Persistence/IndexedBook.swift`:
- Add `public let rawMetadata: [String: String]?` after `comments` (property + init parameter `rawMetadata: [String: String]? = nil`).
- Add `&& lhs.rawMetadata == rhs.rawMetadata` to `==`.
- In `FetchableRecord` `init(row:)`: `rawMetadata = (try? JSONCoding.decode([String: String].self, from: row["rawMetadata"] as String?))`.

- [ ] **Step 4: Implement the catalog v3 migration**

In `BookManagerCore/Persistence/LocalCatalog.swift`:
- Extract the book-table builder from `createV2Schema` into a shared helper:

```swift
private static func createBookTable(_ db: Database, rawMetadata: Bool) throws {
    try db.create(table: "book") { table in
        table.column("id", .text).primaryKey()
        table.column("title", .text).notNull()
        table.column("authors", .text).notNull()
        table.column("series", .text)
        table.column("seriesIndex", .double)
        table.column("tags", .text).notNull()
        table.column("rating", .integer)
        table.column("publisher", .text)
        table.column("publicationMilliseconds", .integer)
        table.column("addedMilliseconds", .integer)
        table.column("languages", .text).notNull()
        table.column("identifiers", .text).notNull()
        table.column("comments", .text)
        table.column("formats", .text).notNull()
        table.column("coverHash", .text)
        table.column("relativePath", .text).notNull()
        if rawMetadata {
            table.column("rawMetadata", .text)
        }
        table.column("modifiedMilliseconds", .integer).notNull()
        table.column("isDeleted", .boolean).notNull()
        table.column("snapshot", .blob).notNull()
    }
}
```
- `createV2Schema` calls `try createBookTable(db, rawMetadata: false)` instead of its inline book-table creation (the rest — bookSearch/bookFacet/bookFormatHash — unchanged).
- Register the v3 migration after `v2ExpandedBook`:

```swift
migrator.registerMigration("v3RawMetadata") { db in
    try db.drop(table: "book")
    try createBookTable(db, rawMetadata: true)
}
```
- `upsert`: add `rawMetadata` to the `book` INSERT column list, the `ON CONFLICT ... DO UPDATE SET` list, and the arguments (`book.rawMetadata.map { try JSONCoding.encode($0) }` → `String?`).

- [ ] **Step 5: Fill it from the document in the repository**

In `BookManagerCore/Library/LibraryRepository.swift` `makeIndexedBook`, add `rawMetadata: book.rawMetadata` to the `IndexedBook(...)` call (the local `book` is the `ResolvedBook`; its `rawMetadata` field is the Automerge payload, already used by `BookFolder.materialize`).

- [ ] **Step 6: Run the tests to verify they pass, then the full core suite**

Run the focused suite, then `-only-testing:BookManagerCoreTests`. Expected: new tests pass; full suite 91 + 3 = 94 tests, 14 suites, green (`LocalCatalogTests`/`LocalCatalogV2Tests` untouched).

- [ ] **Step 7: Commit**

```bash
git add BookManagerCore/Persistence/IndexedBook.swift BookManagerCore/Persistence/LocalCatalog.swift BookManagerCore/Library/LibraryRepository.swift BookManagerCoreTests/Persistence/LocalCatalogV3Tests.swift
git commit -m "feat: expose rawMetadata on IndexedBook via catalog v3 migration"
```

---

### Task 2: `CalibreRawPresenter` — friendly display rows for the payload

**Files:**
- Modify: `BookManagerCore/Calibre/CalibreModels.swift` (`CalibreColumnDefinition` gains `Codable`)
- Create: `BookManagerCore/Calibre/CalibreRawPresenter.swift`
- Create: `BookManagerCoreTests/Calibre/CalibreRawPresenterTests.swift`

**Interfaces:**
- Consumes: `CalibreColumnDefinition` (name, datatype, display, isMultiple, editable, normalized — Plan 1), the raw keys Plan 1 writes (`calibre.customColumns`, `calibre.custom.<label>`, `calibre.custom.<label>.extra`, `calibre.pages`, `calibre.uuid`, `calibre.titleSort`, `calibre.authorSort`, `calibre.sourcePath`, `calibre.lastModified`, `calibre.conversionOptions`, `calibre.originalFormats`).
- Produces: `CalibreRawRow { id, label, value }` (Identifiable/Equatable/Sendable) and `CalibreRawPresenter.rows(from rawMetadata: [String: String]) -> [CalibreRawRow]` — pure, non-throwing, used by `BookInspectorView` (Task 3).

- [ ] **Step 1: Write the failing tests**

Create `BookManagerCoreTests/Calibre/CalibreRawPresenterTests.swift`:

```swift
import Foundation
import Testing
@testable import BookManagerCore

@Suite
struct CalibreRawPresenterTests {
    private func definitionsJSON(_ defs: [String: [String: Any]]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: defs)
        return String(decoding: data, as: UTF8.self)
    }

    @Test
    func customColumnsUseFriendlyNamesFromDefinitions() {
        let defs = definitionsJSON([
            "genre": ["name": "Genre", "datatype": "text", "display": "{}", "isMultiple": false, "editable": true, "normalized": false]
        ])
        let rows = CalibreRawPresenter.rows(from: [
            "calibre.customColumns": defs,
            "calibre.custom.genre": "science",
        ])
        #expect(rows.contains { $0.label == "Genre" && $0.value == "science" })
        #expect(!rows.contains { $0.label == "genre" })
    }

    @Test
    func multiValueCustomColumnsJoinAndPairExtras() {
        let defs = definitionsJSON([
            "shelves": ["name": "Shelves", "datatype": "text", "display": "{}", "isMultiple": true, "editable": true, "normalized": false]
        ])
        let rows = CalibreRawPresenter.rows(from: [
            "calibre.customColumns": defs,
            "calibre.custom.shelves": "[\"read\",\"favorites\"]",
            "calibre.custom.shelves.extra": "[\"0.5\",\"\"]",
        ])
        let shelf = rows.first { $0.id == "calibre.custom.shelves" }
        #expect(shelf?.label == "Shelves")
        #expect(shelf?.value.contains("read") == true)
        #expect(shelf?.value.contains("favorites") == true)
        #expect(shelf?.value.contains("0.5") == true)
    }

    @Test
    func scalarKeysRenderInFixedOrderWithPagesUnknown() {
        let rows = CalibreRawPresenter.rows(from: [
            "calibre.pages": "0",
            "calibre.uuid": "uuid-1",
            "calibre.titleSort": "Range",
            "calibre.sourcePath": "David Epstein/Range (1)",
            "calibre.conversionOptions": "[{\"format\":\"EPUB\",\"data\":\"AQID\"}]",
            "calibre.originalFormats": "[{\"format\":\"EPUB\",\"name\":\"Range - David Epstein\",\"path\":null}]",
        ])
        let labels = rows.map(\.label)
        #expect(labels == ["Calibre UUID", "Title Sort", "Source Path", "Pages", "Conversion Options", "Original Formats"])
        #expect(rows.first { $0.label == "Pages" }?.value == "Unknown")
        #expect(rows.first { $0.label == "Conversion Options" }?.value == "1 format")
        #expect(rows.first { $0.label == "Original Formats" }?.value.contains("EPUB") == true)
    }

    @Test
    func malformedPayloadDegradesToRawRowsWithoutThrowing() {
        let rows = CalibreRawPresenter.rows(from: [
            "calibre.customColumns": "not-json",
            "calibre.custom.genre": "science",
            "calibre.conversionOptions": "not-json",
        ])
        // Unknown definition: the label falls back to the raw key suffix.
        #expect(rows.contains { $0.label == "genre" && $0.value == "science" })
        // Malformed scalar JSON: raw value, no crash.
        #expect(rows.contains { $0.label == "Conversion Options" && $0.value == "not-json" })
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild ... test -only-testing:BookManagerCoreTests/CalibreRawPresenterTests`
Expected: FAIL — `CalibreRawPresenter` has no member `rows(from:)` (or `CalibreColumnDefinition` is not `Codable`).

- [ ] **Step 3: Make `CalibreColumnDefinition` Codable**

In `BookManagerCore/Calibre/CalibreModels.swift`, change the declaration to `public struct CalibreColumnDefinition: Sendable, Equatable, Codable { ... }` (synthesized Codable round-trips the JSON `record()` encoded from the same struct; the stored properties are `name: String`, `datatype: String`, `display: String`, `isMultiple: Bool`, `editable: Bool`, `normalized: Bool`).

- [ ] **Step 4: Implement the presenter**

Create `BookManagerCore/Calibre/CalibreRawPresenter.swift`:

```swift
import Foundation

/// One display row for the inspector's Calibre source-data section.
public struct CalibreRawRow: Identifiable, Equatable, Sendable {
    /// The stable rawMetadata key this row came from.
    public let id: String
    public let label: String
    public let value: String

    public init(id: String, label: String, value: String) {
        self.id = id
        self.label = label
        self.value = value
    }
}

/// Renders the preserved `rawMetadata` payload (Plan 1) for display: custom
/// columns with friendly names resolved from `calibre.customColumns`, then the
/// fixed scalar keys. The payload is opaque and must never crash the UI — every
/// decode failure degrades to a row carrying the raw value.
public enum CalibreRawPresenter {
    private static let customPrefix = "calibre.custom."

    /// Scalar keys in fixed display order: (key, label).
    private static let scalarKeys: [(key: String, label: String)] = [
        ("calibre.uuid", "Calibre UUID"),
        ("calibre.titleSort", "Title Sort"),
        ("calibre.authorSort", "Author Sort"),
        ("calibre.sourcePath", "Source Path"),
        ("calibre.lastModified", "Source Modified"),
        ("calibre.pages", "Pages"),
        ("calibre.conversionOptions", "Conversion Options"),
        ("calibre.originalFormats", "Original Formats"),
    ]

    public static func rows(from rawMetadata: [String: String]) -> [CalibreRawRow] {
        let definitions = parseDefinitions(rawMetadata["calibre.customColumns"])
        var rows: [CalibreRawRow] = []

        let customKeys = rawMetadata.keys
            .filter { $0.hasPrefix(customPrefix) && !$0.hasSuffix(".extra") }
            .sorted()
        for key in customKeys {
            let label = String(key.dropFirst(customPrefix.count))
            let definition = definitions[label]
            var value = valueString(rawMetadata[key], multiple: definition?.isMultiple ?? false)
            let extraKey = "\(key).extra"
            if let extra = rawMetadata[extraKey], let extras = decodeStringArray(extra), !extras.isEmpty {
                let nonEmpty = extras.filter { !$0.isEmpty }
                if !nonEmpty.isEmpty {
                    value += " (extras: \(nonEmpty.joined(separator: ", ")))"
                }
            }
            rows.append(CalibreRawRow(id: key, label: definition?.name ?? label, value: value))
        }

        for (key, label) in scalarKeys {
            guard let value = rawMetadata[key] else { continue }
            rows.append(CalibreRawRow(id: key, label: label, value: summarize(key: key, value: value)))
        }
        return rows
    }

    private static func parseDefinitions(_ json: String?) -> [String: CalibreColumnDefinition] {
        guard let json, let data = json.data(using: .utf8),
              let defs = try? JSONDecoder().decode([String: CalibreColumnDefinition].self, from: data) else {
            return [:]
        }
        return defs
    }

    private static func decodeStringArray(_ json: String) -> [String]? {
        guard let data = json.data(using: .utf8),
              let array = try? JSONDecoder().decode([String].self, from: data) else {
            return nil
        }
        return array
    }

    private static func valueString(_ value: String?, multiple: Bool) -> String {
        guard let value, !value.isEmpty else { return "" }
        if multiple, let array = decodeStringArray(value) {
            return array.joined(separator: ", ")
        }
        return value
    }

    private static func summarize(key: String, value: String) -> String {
        switch key {
        case "calibre.pages":
            return value == "0" ? "Unknown" : value
        case "calibre.conversionOptions":
            guard let data = value.data(using: .utf8),
                  let options = try? JSONDecoder().decode([[String: String]].self, from: data) else {
                return value
            }
            let formats = options.compactMap { $0["format"] }
            return formats.isEmpty ? value : "\(formats.count) format\(formats.count == 1 ? "" : "s")"
        case "calibre.originalFormats":
            guard let data = value.data(using: .utf8),
                  let formats = try? JSONDecoder().decode([[String: String]].self, from: data) else {
                return value
            }
            let names = formats.compactMap { $0["format"] }
            return names.isEmpty ? value : names.joined(separator: ", ")
        default:
            return value
        }
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass, then the full core suite**

Run the focused suite, then `-only-testing:BookManagerCoreTests`. Expected: new tests pass; full suite green (94 + 5 = 99 tests, 14 suites).

- [ ] **Step 6: Commit**

```bash
git add BookManagerCore/Calibre/CalibreModels.swift BookManagerCore/Calibre/CalibreRawPresenter.swift BookManagerCoreTests/Calibre/CalibreRawPresenterTests.swift
git commit -m "feat: add CalibreRawPresenter for friendly inspector rows"
```

---

### Task 3: The inspector UI

**Files:**
- Modify: `BookManager/Stores/LibrarySession.swift` (`inspectorPresented`, `closeLibrary` reset)
- Modify: `BookManager/Views/ContentView.swift` (`.inspector`, auto-show `.onChange`, toolbar toggle)
- Create: `BookManager/Views/BookInspectorView.swift`

**Interfaces:**
- Consumes: `IndexedBook.rawMetadata` (Task 1), `CalibreRawPresenter.rows` (Task 2), `ThumbnailCache.shared.thumbnail(for:repository:)` (existing, see `CoverTile`), `session.selection`, `session.inspectorBook` (existing edit sheet), `session.repository`.
- Produces: `LibrarySession.inspectorPresented: Bool`, `BookInspectorView(session:)`.

- [ ] **Step 1: Session state**

In `BookManager/Stores/LibrarySession.swift` add `var inspectorPresented = false` (near `viewMode`); reset it in `closeLibrary()` alongside the other state resets.

- [ ] **Step 2: ContentView wiring**

In `BookManager/Views/ContentView.swift`:
- Attach to the `Group` (after `.frame(minWidth:minHeight:)`):
```swift
.onChange(of: session.selection) { _, newValue in
    if newValue.count == 1 { session.inspectorPresented = true }
}
```
- Attach to the `NavigationSplitView` in `loadedBody`:
```swift
.inspector(isPresented: $session.inspectorPresented) {
    BookInspectorView(session: session)
}
```
- Add a toolbar toggle in the `ToolbarItemGroup` (before the View picker):
```swift
Button {
    session.inspectorPresented.toggle()
} label: {
    Label("Inspector", systemImage: "sidebar.trailing")
}
.help("Show or hide the inspector")
```

- [ ] **Step 3: Implement `BookInspectorView`**

Create `BookManager/Views/BookInspectorView.swift` (mirror `CoverTile`'s cover pattern):

```swift
import AppKit
import BookManagerCore
import SwiftUI

/// Right-side inspector: cover + metadata for the single selected book, plus a
/// collapsible Calibre source-data section rendered from the raw payload.
struct BookInspectorView: View {
    @Bindable var session: LibrarySession
    @State private var coverImage: NSImage?

    private var book: IndexedBook? {
        guard let id = session.selection.first else { return nil }
        return session.books.first { $0.id == id }
    }

    private var rawRows: [CalibreRawRow] {
        book?.rawMetadata.map(CalibreRawPresenter.rows(from:)) ?? []
    }

    var body: some View {
        Group {
            if let book {
                contents(book)
            } else {
                ContentUnavailableView("No Selection", systemImage: "sidebar.trailing")
            }
        }
        .task(id: book?.id) {
            coverImage = await ThumbnailCache.shared.thumbnail(for: book, repository: session.repository)
        }
        .frame(minWidth: 280, idealWidth: 320)
    }

    private func contents(_ book: IndexedBook) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                cover(book)
                Group {
                    LabeledContent("Title", value: book.title)
                    LabeledContent("Authors", value: book.authors.joined(separator: ", "))
                    if let series = book.series {
                        LabeledContent("Series", value: book.seriesIndex.map { "\(series) #\($0)" } ?? series)
                    }
                    if let rating = book.rating {
                        LabeledContent("Rating", value: String(repeating: "★", count: rating))
                    }
                    if let publisher = book.publisher {
                        LabeledContent("Publisher", value: publisher)
                    }
                    if let date = book.publicationDate {
                        LabeledContent("Published", value: date.formatted(date: .abbreviated, time: .omitted))
                    }
                    LabeledContent("Added", value: (book.addedDate ?? .now).formatted(date: .abbreviated, time: .omitted))
                    if !book.languages.isEmpty {
                        LabeledContent("Languages", value: book.languages.joined(separator: ", "))
                    }
                    if !book.tags.isEmpty {
                        LabeledContent("Tags", value: book.tags.joined(separator: ", "))
                    }
                    if !book.identifiers.isEmpty {
                        LabeledContent("Identifiers", value: book.identifiers.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n"))
                    }
                    if !book.formats.isEmpty {
                        LabeledContent("Formats", value: book.formats.map { "\($0.kind) (\(Self.byteString($0.size)))" }.joined(separator: ", "))
                    }
                    if let comments = book.comments, !comments.isEmpty {
                        Text(comments)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .labelStyle(.titleAndIcon)

                if !rawRows.isEmpty {
                    DisclosureGroup("Calibre Source Data") {
                        ForEach(rawRows) { row in
                            LabeledContent(row.label, value: row.value)
                        }
                        .labelStyle(.titleAndIcon)
                    }
                }

                Button("Edit Metadata…") {
                    session.inspectorBook = book
                }
                .disabled(session.inspectorBook != nil)
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private func cover(_ book: IndexedBook) -> some View {
        if let coverImage {
            Image(nsImage: coverImage)
                .resizable()
                .scaledToFit()
                .frame(height: 220)
                .frame(maxWidth: .infinity)
        } else {
            Image(systemName: "book.closed")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
                .frame(height: 220)
                .frame(maxWidth: .infinity)
        }
    }

    private static func byteString(_ size: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}
```

Note: `LabeledContent` with a multi-line `value` (identifiers) works when given a `Text`; keep the join with `"\n"` — it renders on macOS. If the compile flags a `LabeledContent` overload ambiguity, split identifiers into their own `VStack(alignment: .leading)` of `Text` rows — do not over-engineer.

- [ ] **Step 4: Build and verify wiring**

Run: `xcodebuild -project BookManager.xcodeproj -scheme BookManager -destination 'platform=macOS' -derivedDataPath .build/DerivedData build`
Expected: BUILD SUCCEEDED (this is a new file — regenerate the project first with `xcodegen generate --spec project.yml` so the target picks it up).
Then run the full core suite to confirm no app-target changes regressed Core: `... test -only-testing:BookManagerCoreTests` → 99 tests green.
Manual GUI verification (auto-show on single selection, toggle, placeholder, raw section, Edit opens the sheet) is a residual for the human — note it in the report.

- [ ] **Step 5: Commit**

```bash
git add BookManager/Stores/LibrarySession.swift BookManager/Views/ContentView.swift BookManager/Views/BookInspectorView.swift
git commit -m "feat: right inspector with cover, metadata, and calibre source data"
```

---

## Self-Review

- **Spec coverage:** Requirement 1 (auto-show + toggle + placeholder) → Task 3 Step 2 + BookInspectorView placeholder. Requirement 2 (cover + all metadata fields) → Task 3 Step 3. Requirement 3 (raw section: friendly custom names, pages "0"→unknown, Plan 1 keys) → Task 2 (presenter) + Task 3 raw section. Requirement 4 (Edit → existing sheet) → Task 3 button via `session.inspectorBook`. Requirement 5 (no Automerge change) → Task 1 touches only the disposable catalog. Acceptance "Core suite green + no schema regression" → Task 1/2 tests + full-suite gates.
- **Placeholder scan:** no TBDs; every step has concrete code or an exact command.
- **Type consistency:** `IndexedBook.rawMetadata` defined in Task 1, consumed in Task 3 (`book.rawMetadata.map(CalibreRawPresenter.rows(from:))`); `CalibreRawRow`/`CalibreRawPresenter.rows` defined in Task 2, consumed in Task 3; `session.inspectorPresented` defined in Task 3 Step 1, used in Steps 2–3. `CalibreColumnDefinition` Codable added in Task 2 Step 3, decoded in Task 2 Step 4. No name drift.
- **Risk noted:** `LabeledContent` with a multiline value may need a `Text`-based overload — the fallback is specified inline in Task 3 Step 3.
