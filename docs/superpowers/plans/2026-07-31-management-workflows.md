# Management Workflows Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the Slice 1 library foundation into a working book manager: import EPUB/PDF/DJVU files, edit metadata, browse with facets and a cover grid, open books externally, delete/restore from trash, and view diagnostics.

**Architecture:** Every mutation still flows SwiftUI → Library Repository → Automerge Domain Adapter → Change Store → Filesystem Reconciliation → Local Catalogue. Slice 2 expands the per-book Automerge schema (series, tags, rating, dates, identifiers, formats, cover), materializes Calibre-style book folders from staged imports, rebuilds the GRDB catalogue with facet tables and FTS5 search over the richer fields, and layers the SwiftUI browser (sidebar facets, table/grid, inspector, import report, diagnostics) on top.

**Tech Stack:** macOS 26+, Swift 6 strict concurrency, SwiftUI, Observation, Automerge Swift 0.7.2 (pinned), GRDB.swift 7.11.1 (pinned), **ZIPFoundation 0.9.19 (new, pinned)**, PDFKit + CoreGraphics/ImageIO for PDF and cover handling, QuickLookThumbnailing for grid thumbnails, XMLParser for OPF, CryptoKit for SHA-256, Swift Testing, XCTest UI testing, XcodeGen.

## Global Constraints

- macOS 26 or later; Swift 6 with `SWIFT_STRICT_CONCURRENCY: complete`.
- Dependencies pinned by exact version in `project.yml` and `Package.resolved`: Automerge 0.7.2, GRDB 7.11.1, ZIPFoundation 0.9.19. Major-version updates require explicit review.
- `BookManagerCore` contains no SwiftUI. It may use Foundation, Automerge, GRDB, ZIPFoundation, PDFKit, CoreGraphics, ImageIO, CryptoKit, UniformTypeIdentifiers, XMLParser, and AppKit-free image conversion.
- The portable library's `.bookmanager/changes` directory is the source of truth. SQLite catalogue files under Application Support are disposable and rebuildable; never store them in a synchronized library.
- `BookManagerCore` is sandboxed; folder access is via security-scoped bookmarks. All file work inside a library happens through `NSFileCoordinator`-free simple FileManager calls in Slice 2 (coordinated access is Slice 4); the code must remain protocol-friendly.
- An exact duplicate (same content hash) is never copied silently. A likely duplicate (normalized title + first author) is never merged silently.
- Every new field change is one Automerge commit and one immutable `.amchange` file. Same-field concurrent edits resolve to the newest hybrid logical clock value.
- The app must remain runnable after every task; completed behavior is covered by automated tests.

## File Map

```text
project.yml                                          (modify: add ZIPFoundation)
BookManagerCore/
├── CRDT/
│   ├── BookDocumentSchema.swift                     (modify: v2 fields, tolerant decoding)
│   ├── AutomergeBookDocument.swift                  (modify: v2 setters, resolvedBook expansion)
│   └── BookValues.swift                             (create: BookFormatValue, CoverValue, NewBookMetadata, BookEdit, FieldEdit, FacetType)
├── Library/
│   ├── CanonicalPathBuilder.swift                   (modify: formatFileName)
│   ├── BookFolder.swift                             (create: staging, materialize, trash/restore/rename, journal, cover/opf writes)
│   ├── OpfGenerator.swift                           (create: metadata.opf projection)
│   ├── ChangeStore.swift                            (unchanged)
│   ├── LibraryManifest.swift                        (unchanged)
│   ├── LibraryLayout.swift                          (unchanged)
│   └── LibraryRepository.swift                      (modify: v2 create/update/delete/restore/open/reveal/diagnostics APIs)
├── Import/
│   ├── MetadataExtractor.swift                      (create: EPUB/PDF/DJVU extraction + covers)
│   └── ImportService.swift                          (create: staged import pipeline + report)
└── Persistence/
    ├── IndexedBook.swift                            (modify: v2 fields, BookFormatRecord, explicit row decode)
    └── LocalCatalog.swift                           (modify: v2 migration, facets, format hashes, extended search)
BookManager/
├── App/BookManagerApp.swift                         (unchanged)
├── Stores/
│   ├── LibrarySession.swift                         (modify: v2 state + actions)
│   └── ThumbnailCache.swift                         (create: cover + QuickLook thumbnail resolution)
└── Views/
    ├── ContentView.swift                            (modify: sidebar, toolbar, drop target, sheets)
    ├── SidebarView.swift                            (create: All Books + facet sections)
    ├── BookTableView.swift                          (modify: richer columns + context menu)
    ├── CoverGridView.swift                          (create: cover grid)
    ├── MetadataEditorView.swift                     (create: inspector form)
    ├── ImportReportView.swift                       (create: import result sheet)
    └── DiagnosticsView.swift                        (create: missing files, trash, index rebuild, history)
BookManagerCoreTests/
├── CRDT/
│   ├── AutomergeBookDocumentTests.swift             (modify: only if compile breaks — expected stable)
│   └── SchemaV2Tests.swift                          (create: new-field merges, tags, old-doc tolerance)
├── Import/
│   ├── Fixtures.swift                               (create: EPUB/PDF/DJVU fixture builders)
│   ├── MetadataExtractorTests.swift                 (create)
│   └── ImportServiceTests.swift                     (create)
├── Library/
│   ├── BookFolderTests.swift                        (create: materialize/rename/trash/restore/journal)
│   └── LibraryRepositoryTests.swift                 (modify: v2 create/update/delete/restore flows)
└── Persistence/
    ├── LocalCatalogTests.swift                      (modify: v2 init updates only)
    └── LocalCatalogV2Tests.swift                    (create: facets, extended search, hash lookup)
BookManagerUITests/BookManagerUITests.swift          (modify: keep stable tests)
docs/superpowers/specs/2026-07-29-book-manager-design.md  (modify: Slice 2 status)
```

---

### Task 1: Expanded CRDT Schema and Domain Adapter

**Files:**

- Create: `BookManagerCore/CRDT/BookValues.swift`
- Modify: `BookManagerCore/CRDT/BookDocumentSchema.swift`
- Modify: `BookManagerCore/CRDT/AutomergeBookDocument.swift`
- Test: `BookManagerCoreTests/CRDT/SchemaV2Tests.swift`

**Interfaces:**

- Consumes: `VersionedValue<Value>`, `HybridLogicalClock` (Slice 1).
- Produces: `BookFormatValue {kind, filename, contentHash, size}`, `CoverValue {filename, contentHash}`, `NewBookMetadata`, `BookEdit` + `FieldEdit<T>` (with `.keep/.set/.clear`), `FacetType {author, series, tag, format}`, expanded `ResolvedBook`, and adapter setters: `setSeries`, `setSeriesIndex`, `setTags`, `setRating`, `setPublisher`, `setPublicationDate`, `setAddedDate`, `setLanguages`, `setIdentifiers`, `setComments`, `setFormat`, `removeFormat`, `setCover`, `setDeleted`.

- [ ] **Step 1: Write the schema v2 acceptance tests**

Create `BookManagerCoreTests/CRDT/SchemaV2Tests.swift`:

```swift
import Automerge
import Foundation
import Testing
@testable import BookManagerCore

@Suite
struct SchemaV2Tests {
    private let bookID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    private let deviceA = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
    private let deviceB = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!

    private func document(deviceID: UUID = deviceA) throws -> AutomergeBookDocument {
        try AutomergeBookDocument.new(bookID: bookID, deviceID: deviceID)
    }

    @Test
    func oldDocumentsWithoutV2FieldsStillDecode() throws {
        // Encode a genuine v1-shaped document (bookID, titles, authors, deletions only)
        // through the raw Automerge encoder, then resolve it with the v2 adapter.
        let clock = HybridLogicalClock(physicalMilliseconds: 1_000, nodeID: deviceA)
        var v1 = V1Shape(bookID: bookID)
        v1.titles[deviceA.uuidString] = VersionedValue(value: "Range", clock: clock)
        let document = Document()
        document.actor = ActorId(uuid: deviceA)
        try AutomergeEncoder(doc: document).encode(v1)

        let reopened = try AutomergeBookDocument(snapshot: document.save(), deviceID: deviceB)
        let resolved = try reopened.resolvedBook()

        #expect(resolved.title == "Range")
        #expect(resolved.tags.isEmpty)
        #expect(resolved.formats.isEmpty)
        #expect(resolved.cover == nil)
        #expect(resolved.series == nil)
        #expect(resolved.identifiers.isEmpty)
        #expect(resolved.languages.isEmpty)
        #expect(resolved.rating == nil)
        #expect(resolved.comments == nil)
    }

    @Test
    func applyEditProducesChangesAndResolves() throws {
        let source = try document()
        let changes = try source.apply(
            BookEdit(title: "New Title", authors: ["Someone"], tags: ["x"], rating: .set(3)),
            clock: .init(physicalMilliseconds: 1_000, nodeID: deviceA),
            date: Date(timeIntervalSince1970: 1)
        )

        #expect(changes.count == 4)
        let resolved = try source.resolvedBook()
        #expect(resolved.title == "New Title")
        #expect(resolved.authors == ["Someone"])
        #expect(resolved.tags == ["x"])
        #expect(resolved.rating == 3)
    }

    private struct V1Shape: Codable {
        var schemaVersion: Int = 1
        var bookID: UUID?
        var titles: [String: VersionedValue<String>] = [:]
        var authors: [String: VersionedValue<[String]>] = [:]
        var deletions: [String: VersionedValue<Bool>] = [:]
    }

    @Test
    func v2FieldsResolveAcrossReplicas() throws {
        let source = try document()
        let base = try source.setTitle("Range", clock: .init(physicalMilliseconds: 1_000, nodeID: deviceA))
        let replica = try AutomergeBookDocument.empty(deviceID: deviceB)
        try replica.apply(base)

        let series = try replica.setSeries("Studies", clock: .init(physicalMilliseconds: 2_000, nodeID: deviceB))
        let format = BookFormatValue(
            kind: "EPUB",
            filename: "Range - David Epstein.epub",
            contentHash: "abc123",
            size: 42
        )
        let formatChange = try replica.setFormat(format, clock: .init(physicalMilliseconds: 2_100, nodeID: deviceB))
        let cover = CoverValue(filename: "cover.jpg", contentHash: "def456")
        let coverChange = try replica.setCover(cover, clock: .init(physicalMilliseconds: 2_200, nodeID: deviceB))

        try source.apply(series)
        try source.apply(formatChange)
        try source.apply(coverChange)

        #expect(try source.resolvedBook().series == "Studies")
        #expect(try source.resolvedBook().formats == [format])
        #expect(try source.resolvedBook().cover == cover)
        #expect(try source.resolvedBook().isDeleted == false)
    }

    @Test
    func tagsResolveNewestAddOrRemovePerTag() throws {
        let source = try document()
        let replica = try AutomergeBookDocument.empty(deviceID: deviceB)
        try replica.apply(try source.setTitle("Range", clock: .init(physicalMilliseconds: 1_000, nodeID: deviceA)))

        let addChange = try replica.setTags(["science", "sport"], clock: .init(physicalMilliseconds: 2_000, nodeID: deviceB))
        try source.apply(addChange)
        #expect(try source.resolvedBook().tags == ["science", "sport"])

        let removeChange = try replica.setTags(["science"], clock: .init(physicalMilliseconds: 3_000, nodeID: deviceB))
        try source.apply(removeChange)
        #expect(try source.resolvedBook().tags == ["science"])
    }

    @Test
    func concurrentFormatReplacementKeepsNewestPerKind() throws {
        let source = try document()
        let base = try source.setTitle("Range", clock: .init(physicalMilliseconds: 1_000, nodeID: deviceA))
        let first = try AutomergeBookDocument.empty(deviceID: deviceA)
        let second = try AutomergeBookDocument.empty(deviceID: deviceB)
        try first.apply(base)
        try second.apply(base)

        let older = BookFormatValue(kind: "EPUB", filename: "older.epub", contentHash: "old", size: 1)
        let newer = BookFormatValue(kind: "EPUB", filename: "newer.epub", contentHash: "new", size: 2)
        let olderChange = try first.setFormat(older, clock: .init(physicalMilliseconds: 2_000, nodeID: deviceA))
        let newerChange = try second.setFormat(newer, clock: .init(physicalMilliseconds: 3_000, nodeID: deviceB))

        try first.apply(newerChange)
        try second.apply(olderChange)

        #expect(try first.resolvedBook().formats == [newer])
        #expect(try second.resolvedBook().formats == [newer])
    }

    @Test
    func tombstoneAndRestoreResolveNewest() throws {
        let source = try document()
        _ = try source.setTitle("Range", clock: .init(physicalMilliseconds: 1_000, nodeID: deviceA))

        let delete = try source.setDeleted(true, clock: .init(physicalMilliseconds: 2_000, nodeID: deviceA))
        let replica = try AutomergeBookDocument.empty(deviceID: deviceB)
        try replica.apply(delete)
        #expect(try replica.resolvedBook().isDeleted)

        let restore = try replica.setDeleted(false, clock: .init(physicalMilliseconds: 3_000, nodeID: deviceB))
        try source.apply(restore)
        #expect(!try source.resolvedBook().isDeleted)
    }

    @Test
    func identifiersUseIndependentRegistersPerType() throws {
        let source = try document()
        _ = try source.setIdentifiers(
            ["isbn": "1234", "google": "abcd"],
            clock: .init(physicalMilliseconds: 1_000, nodeID: deviceA)
        )
        let change = try source.setIdentifiers(
            ["isbn": "9999"],
            clock: .init(physicalMilliseconds: 2_000, nodeID: deviceA)
        )
        let replica = try AutomergeBookDocument.empty(deviceID: deviceB)
        try replica.apply(change)
        #expect(try replica.resolvedBook().identifiers["isbn"] == "9999")
    }
}
```

- [ ] **Step 2: Run the schema tests to verify they fail**

Run (from the worktree root, see Task 9 for setup notes):

```bash
xcodegen generate --spec project.yml
xcodebuild -project BookManager.xcodeproj -scheme BookManager -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:BookManagerCoreTests/SchemaV2Tests test
```

Expected: compilation fails because `BookFormatValue`, `CoverValue`, and the v2 setters are undefined.

- [ ] **Step 3: Add the v2 value types**

Create `BookManagerCore/CRDT/BookValues.swift`:

```swift
import Foundation

public struct BookFormatValue: Codable, Equatable, Sendable {
    public let kind: String
    public let filename: String
    public let contentHash: String
    public let size: Int64

    public init(kind: String, filename: String, contentHash: String, size: Int64) {
        self.kind = kind
        self.filename = filename
        self.contentHash = contentHash
        self.size = size
    }
}

public struct CoverValue: Codable, Equatable, Sendable {
    public let filename: String
    public let contentHash: String

    public init(filename: String, contentHash: String) {
        self.filename = filename
        self.contentHash = contentHash
    }
}

public enum FacetType: String, Codable, Sendable {
    case author
    case series
    case tag
    case format
}

public struct NewBookMetadata: Sendable {
    public var title: String
    public var authors: [String]
    public var series: String?
    public var seriesIndex: Double?
    public var tags: [String]
    public var rating: Int?
    public var publisher: String?
    public var publicationDate: Date?
    public var languages: [String]
    public var identifiers: [String: String]
    public var comments: String?

    public init(
        title: String,
        authors: [String] = [],
        series: String? = nil,
        seriesIndex: Double? = nil,
        tags: [String] = [],
        rating: Int? = nil,
        publisher: String? = nil,
        publicationDate: Date? = nil,
        languages: [String] = [],
        identifiers: [String: String] = [:],
        comments: String? = nil
    ) {
        self.title = title
        self.authors = authors
        self.series = series
        self.seriesIndex = seriesIndex
        self.tags = tags
        self.rating = rating
        self.publisher = publisher
        self.publicationDate = publicationDate
        self.languages = languages
        self.identifiers = identifiers
        self.comments = comments
    }
}

public enum FieldEdit<T: Sendable & Equatable>: Equatable, Sendable {
    case keep
    case set(T)
    case clear
}

public struct BookEdit: Sendable {
    public var title: String?
    public var authors: [String]?
    public var series: FieldEdit<String> = .keep
    public var seriesIndex: FieldEdit<Double> = .keep
    public var tags: [String]?
    public var rating: FieldEdit<Int> = .keep
    public var publisher: FieldEdit<String> = .keep
    public var publicationDate: FieldEdit<Date> = .keep
    public var languages: [String]?
    public var identifiers: [String: String]?
    public var comments: FieldEdit<String> = .keep

    public init(
        title: String? = nil,
        authors: [String]? = nil,
        series: FieldEdit<String> = .keep,
        seriesIndex: FieldEdit<Double> = .keep,
        tags: [String]? = nil,
        rating: FieldEdit<Int> = .keep,
        publisher: FieldEdit<String> = .keep,
        publicationDate: FieldEdit<Date> = .keep,
        languages: [String]? = nil,
        identifiers: [String: String]? = nil,
        comments: FieldEdit<String> = .keep
    ) {
        self.title = title
        self.authors = authors
        self.series = series
        self.seriesIndex = seriesIndex
        self.tags = tags
        self.rating = rating
        self.publisher = publisher
        self.publicationDate = publicationDate
        self.languages = languages
        self.identifiers = identifiers
        self.comments = comments
    }
}
```

- [ ] **Step 4: Expand the schema with tolerant decoding**

Replace the contents of `BookManagerCore/CRDT/BookDocumentSchema.swift`:

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
    public var series: [String: VersionedValue<String>]
    public var seriesIndexes: [String: VersionedValue<Double>]
    public var tags: [String: [String: VersionedValue<Bool>]]
    public var ratings: [String: VersionedValue<Int>]
    public var publishers: [String: VersionedValue<String>]
    public var publicationDates: [String: VersionedValue<Date>]
    public var addedDates: [String: VersionedValue<Date>]
    public var languages: [String: VersionedValue<[String]>]
    public var identifiers: [String: [String: VersionedValue<String>]]
    public var comments: [String: VersionedValue<String>]
    public var formats: [String: [String: VersionedValue<BookFormatValue>]]
    public var covers: [String: VersionedValue<CoverValue>]

    public init(
        schemaVersion: Int = 2,
        bookID: UUID? = nil,
        titles: [String: VersionedValue<String>] = [:],
        authors: [String: VersionedValue<[String]>] = [:],
        deletions: [String: VersionedValue<Bool>] = [:],
        series: [String: VersionedValue<String>] = [:],
        seriesIndexes: [String: VersionedValue<Double>] = [:],
        tags: [String: [String: VersionedValue<Bool>]] = [:],
        ratings: [String: VersionedValue<Int>] = [:],
        publishers: [String: VersionedValue<String>] = [:],
        publicationDates: [String: VersionedValue<Date>] = [:],
        addedDates: [String: VersionedValue<Date>] = [:],
        languages: [String: VersionedValue<[String]>] = [:],
        identifiers: [String: [String: VersionedValue<String>]] = [:],
        comments: [String: VersionedValue<String>] = [:],
        formats: [String: [String: VersionedValue<BookFormatValue>]] = [:],
        covers: [String: VersionedValue<CoverValue>] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.bookID = bookID
        self.titles = titles
        self.authors = authors
        self.deletions = deletions
        self.series = series
        self.seriesIndexes = seriesIndexes
        self.tags = tags
        self.ratings = ratings
        self.publishers = publishers
        self.publicationDates = publicationDates
        self.addedDates = addedDates
        self.languages = languages
        self.identifiers = identifiers
        self.comments = comments
        self.formats = formats
        self.covers = covers
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, bookID, titles, authors, deletions, series, seriesIndexes
        case tags, ratings, publishers, publicationDates, addedDates
        case languages, identifiers, comments, formats, covers
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        bookID = try container.decodeIfPresent(UUID.self, forKey: .bookID)
        titles = try container.decodeIfPresent([String: VersionedValue<String>].self, forKey: .titles) ?? [:]
        authors = try container.decodeIfPresent([String: VersionedValue<[String]>].self, forKey: .authors) ?? [:]
        deletions = try container.decodeIfPresent([String: VersionedValue<Bool>].self, forKey: .deletions) ?? [:]
        series = try container.decodeIfPresent([String: VersionedValue<String>].self, forKey: .series) ?? [:]
        seriesIndexes = try container.decodeIfPresent([String: VersionedValue<Double>].self, forKey: .seriesIndexes) ?? [:]
        tags = try container.decodeIfPresent([String: [String: VersionedValue<Bool>]].self, forKey: .tags) ?? [:]
        ratings = try container.decodeIfPresent([String: VersionedValue<Int>].self, forKey: .ratings) ?? [:]
        publishers = try container.decodeIfPresent([String: VersionedValue<String>].self, forKey: .publishers) ?? [:]
        publicationDates = try container.decodeIfPresent([String: VersionedValue<Date>].self, forKey: .publicationDates) ?? [:]
        addedDates = try container.decodeIfPresent([String: VersionedValue<Date>].self, forKey: .addedDates) ?? [:]
        languages = try container.decodeIfPresent([String: VersionedValue<[String]>].self, forKey: .languages) ?? [:]
        identifiers = try container.decodeIfPresent([String: [String: VersionedValue<String>]].self, forKey: .identifiers) ?? [:]
        comments = try container.decodeIfPresent([String: VersionedValue<String>].self, forKey: .comments) ?? [:]
        formats = try container.decodeIfPresent([String: [String: VersionedValue<BookFormatValue>]].self, forKey: .formats) ?? [:]
        covers = try container.decodeIfPresent([String: VersionedValue<CoverValue>].self, forKey: .covers) ?? [:]
    }
}

public struct ResolvedBook: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let title: String
    public let authors: [String]
    public let series: String?
    public let seriesIndex: Double?
    public let tags: [String]
    public let rating: Int?
    public let publisher: String?
    public let publicationDate: Date?
    public let addedDate: Date?
    public let languages: [String]
    public let identifiers: [String: String]
    public let comments: String?
    public let formats: [BookFormatValue]
    public let cover: CoverValue?
    public let isDeleted: Bool
    public let modifiedClock: HybridLogicalClock
}
```

- [ ] **Step 5: Extend the domain adapter**

Append to `BookManagerCore/CRDT/AutomergeBookDocument.swift` (keep all existing code):

```swift
    public func setSeries(_ value: String, clock: HybridLogicalClock) throws -> Data {
        var schema = try decode()
        schema.series[deviceID.uuidString] = VersionedValue(value: value, clock: clock)
        return try commit(schema, message: "set-series", timestamp: clock.date)
    }

    public func setSeriesIndex(_ value: Double, clock: HybridLogicalClock) throws -> Data {
        var schema = try decode()
        schema.seriesIndexes[deviceID.uuidString] = VersionedValue(value: value, clock: clock)
        return try commit(schema, message: "set-series-index", timestamp: clock.date)
    }

    public func setTags(_ tags: [String], clock: HybridLogicalClock) throws -> Data {
        var schema = try decode()
        var resolved = resolvedTagNames(schema.tags)
        for tag in tags where !resolved.contains(tag) {
            schema.tags[tag, default: [:]][deviceID.uuidString] = VersionedValue(value: true, clock: clock)
        }
        for tag in resolved where !tags.contains(tag) {
            schema.tags[tag, default: [:]][deviceID.uuidString] = VersionedValue(value: false, clock: clock)
        }
        return try commit(schema, message: "set-tags", timestamp: clock.date)
    }

    public func setRating(_ value: Int, clock: HybridLogicalClock) throws -> Data {
        var schema = try decode()
        schema.ratings[deviceID.uuidString] = VersionedValue(value: value, clock: clock)
        return try commit(schema, message: "set-rating", timestamp: clock.date)
    }

    public func setPublisher(_ value: String, clock: HybridLogicalClock) throws -> Data {
        var schema = try decode()
        schema.publishers[deviceID.uuidString] = VersionedValue(value: value, clock: clock)
        return try commit(schema, message: "set-publisher", timestamp: clock.date)
    }

    public func setPublicationDate(_ value: Date, clock: HybridLogicalClock) throws -> Data {
        var schema = try decode()
        schema.publicationDates[deviceID.uuidString] = VersionedValue(value: value, clock: clock)
        return try commit(schema, message: "set-publication-date", timestamp: clock.date)
    }

    public func setAddedDate(_ value: Date, clock: HybridLogicalClock) throws -> Data {
        var schema = try decode()
        schema.addedDates[deviceID.uuidString] = VersionedValue(value: value, clock: clock)
        return try commit(schema, message: "set-added-date", timestamp: clock.date)
    }

    public func setLanguages(_ value: [String], clock: HybridLogicalClock) throws -> Data {
        var schema = try decode()
        schema.languages[deviceID.uuidString] = VersionedValue(value: value, clock: clock)
        return try commit(schema, message: "set-languages", timestamp: clock.date)
    }

    public func setIdentifiers(_ value: [String: String], clock: HybridLogicalClock) throws -> Data {
        var schema = try decode()
        let existing = resolvedIdentifiers(schema.identifiers)
        for type in existing.keys where value[type] == nil {
            schema.identifiers.removeValue(forKey: type)
        }
        for (type, identifier) in value {
            schema.identifiers[type, default: [:]][deviceID.uuidString] = VersionedValue(value: identifier, clock: clock)
        }
        return try commit(schema, message: "set-identifiers", timestamp: clock.date)
    }

    public func setComments(_ value: String, clock: HybridLogicalClock) throws -> Data {
        var schema = try decode()
        schema.comments[deviceID.uuidString] = VersionedValue(value: value, clock: clock)
        return try commit(schema, message: "set-comments", timestamp: clock.date)
    }

    public func setFormat(_ value: BookFormatValue, clock: HybridLogicalClock) throws -> Data {
        var schema = try decode()
        schema.formats[value.kind, default: [:]][deviceID.uuidString] = VersionedValue(value: value, clock: clock)
        return try commit(schema, message: "set-format-\(value.kind)", timestamp: clock.date)
    }

    public func removeFormat(kind: String, clock: HybridLogicalClock) throws -> Data {
        var schema = try decode()
        schema.formats.removeValue(forKey: kind)
        return try commit(schema, message: "remove-format-\(kind)", timestamp: clock.date)
    }

    public func setCover(_ value: CoverValue?, clock: HybridLogicalClock) throws -> Data {
        var schema = try decode()
        if let value {
            schema.covers[deviceID.uuidString] = VersionedValue(value: value, clock: clock)
        } else {
            schema.covers.removeValue(forKey: deviceID.uuidString)
        }
        return try commit(schema, message: "set-cover", timestamp: clock.date)
    }

    public func setDeleted(_ deleted: Bool, clock: HybridLogicalClock) throws -> Data {
        var schema = try decode()
        schema.deletions[deviceID.uuidString] = VersionedValue(value: deleted, clock: clock)
        return try commit(schema, message: deleted ? "delete-book" : "restore-book", timestamp: clock.date)
    }

    public func apply(_ edits: BookEdit, clock: HybridLogicalClock, date: Date) throws -> [Data] {
        var changes: [Data] = []
        var current = clock
        if let title = edits.title {
            changes.append(try setTitle(title, clock: current.tick(at: date)))
        }
        if let authors = edits.authors {
            changes.append(try setAuthors(authors, clock: current.tick(at: date)))
        }
        switch edits.series {
        case .keep: break
        case .set(let value): changes.append(try setSeries(value, clock: current.tick(at: date)))
        case .clear: changes.append(try setSeries("", clock: current.tick(at: date)))
        }
        switch edits.seriesIndex {
        case .keep: break
        case .set(let value): changes.append(try setSeriesIndex(value, clock: current.tick(at: date)))
        case .clear: changes.append(try setSeriesIndex(0, clock: current.tick(at: date)))
        }
        if let tags = edits.tags {
            changes.append(try setTags(tags, clock: current.tick(at: date)))
        }
        switch edits.rating {
        case .keep: break
        case .set(let value): changes.append(try setRating(value, clock: current.tick(at: date)))
        case .clear: changes.append(try setRating(0, clock: current.tick(at: date)))
        }
        switch edits.publisher {
        case .keep: break
        case .set(let value): changes.append(try setPublisher(value, clock: current.tick(at: date)))
        case .clear: changes.append(try setPublisher("", clock: current.tick(at: date)))
        }
        switch edits.publicationDate {
        case .keep: break
        case .set(let value): changes.append(try setPublicationDate(value, clock: current.tick(at: date)))
        case .clear: changes.append(try setPublicationDate(Date(timeIntervalSince1970: 0), clock: current.tick(at: date)))
        }
        if let languages = edits.languages {
            changes.append(try setLanguages(languages, clock: current.tick(at: date)))
        }
        if let identifiers = edits.identifiers {
            changes.append(try setIdentifiers(identifiers, clock: current.tick(at: date)))
        }
        switch edits.comments {
        case .keep: break
        case .set(let value): changes.append(try setComments(value, clock: current.tick(at: date)))
        case .clear: changes.append(try setComments("", clock: current.tick(at: date)))
        }
        return changes
    }
```

Replace `resolvedBook()` in the same file with the expanded version:

```swift
    public func resolvedBook() throws -> ResolvedBook {
        let schema = try decode()
        guard let id = schema.bookID else {
            throw BookDocumentError.missingBookID
        }

        let title = newest(schema.titles)?.value ?? "Unknown"
        let authors = newest(schema.authors)?.value ?? ["Unknown"]
        let series = newest(schema.series)?.value
        let seriesIndex = newest(schema.seriesIndexes)?.value
        let tags = resolvedTagNames(schema.tags)
        let rating = newest(schema.ratings)?.value
        let publisher = newest(schema.publishers)?.value
        let publicationDate = newest(schema.publicationDates)?.value
        let addedDate = newest(schema.addedDates)?.value
        let languages = newest(schema.languages)?.value ?? []
        let identifiers = resolvedIdentifiers(schema.identifiers)
        let comments = newest(schema.comments)?.value
        let formats = resolvedFormats(schema.formats)
        let cover = newest(schema.covers)?.value
        let deletion = newest(schema.deletions)
        let clocks = [
            newest(schema.titles)?.clock,
            newest(schema.authors)?.clock,
            newest(schema.series)?.clock,
            newest(schema.seriesIndexes)?.clock,
            newest(schema.ratings)?.clock,
            newest(schema.publishers)?.clock,
            newest(schema.publicationDates)?.clock,
            newest(schema.addedDates)?.clock,
            newest(schema.languages)?.clock,
            newest(schema.comments)?.clock,
            newest(schema.covers)?.clock,
            deletion?.clock
        ].compactMap { $0 }
        // Tags and identifiers participate in the modified clock through their own newest entries.
        let tagClocks = schema.tags.values.flatMap { $0.values }.map(\.clock)
        let identifierClocks = schema.identifiers.values.flatMap { $0.values }.map(\.clock)
        let formatClocks = schema.formats.values.flatMap { $0.values }.map(\.clock)

        guard let modifiedClock = (clocks + tagClocks + identifierClocks + formatClocks).max() else {
            throw BookDocumentError.missingClock
        }

        return ResolvedBook(
            id: id,
            title: title,
            authors: authors,
            series: series,
            seriesIndex: seriesIndex,
            tags: tags,
            rating: rating,
            publisher: publisher,
            publicationDate: publicationDate,
            addedDate: addedDate,
            languages: languages,
            identifiers: identifiers,
            comments: comments,
            formats: formats,
            cover: cover,
            isDeleted: deletion?.value ?? false,
            modifiedClock: modifiedClock
        )
    }

    private func resolvedTagNames(_ tags: [String: [String: VersionedValue<Bool>]]) -> [String] {
        tags.compactMap { tag, devices in
            guard let newest = devices.values.max(by: { $0.clock < $1.clock }) else { return nil }
            return newest.value ? tag : nil
        }.sorted()
    }

    private func resolvedIdentifiers(_ identifiers: [String: [String: VersionedValue<String>]]) -> [String: String] {
        identifiers.compactMapValues { devices in
            devices.values.max(by: { $0.clock < $1.clock })?.value
        }
    }

    private func resolvedFormats(_ formats: [String: [String: VersionedValue<BookFormatValue>]]) -> [BookFormatValue] {
        formats.compactMapValues { devices in
            devices.values.max(by: { $0.clock < $1.clock })?.value
        }.values.sorted { $0.kind < $1.kind }
    }
```

Also change `new(bookID:deviceID:)` so a fresh document is a v2 schema:

```swift
    public static func new(bookID: UUID, deviceID: UUID) throws -> AutomergeBookDocument {
        let result = AutomergeBookDocument(document: Document(), deviceID: deviceID)
        var schema = BookDocumentSchema(schemaVersion: 2, bookID: bookID)
        schema.deletions[deviceID.uuidString] = VersionedValue(
            value: false,
            clock: HybridLogicalClock(nodeID: deviceID)
        )
        try result.encode(schema)
        return result
    }
```

Note: `setSeries("", ...)`, `setRating(0, ...)`, `setPublisher("", ...)`, `setComments("", ...)`, and `setPublicationDate(.init(timeIntervalSince1970: 0), ...)` are the *clear* sentinels; the repository converts empty-string/zero values back to `nil` when building `IndexedBook` (Task 5). This keeps the change log append-only without tombstones for scalars.

- [ ] **Step 6: Run the schema tests**

Run the command from Step 2. Expected: all six tests pass.

- [ ] **Step 7: Run the full core suite (slice-1 tests must stay green)**

```bash
xcodebuild -project BookManager.xcodeproj -scheme BookManager -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:BookManagerCoreTests test
```

Expected: `** TEST SUCCEEDED **` (the v1 `AutomergeBookDocumentTests` use `setTitle`/`setAuthors`/`resolvedBook().title|authors|id|isDeleted`, all still present).

- [ ] **Step 8: Commit**

```bash
git add BookManagerCore/CRDT BookManagerCoreTests/CRDT
git commit -m "feat: expand book schema with management fields"
```

### Task 2: Canonical Format Paths and Book Folders

**Files:**

- Modify: `BookManagerCore/Library/CanonicalPathBuilder.swift`
- Create: `BookManagerCore/Library/OpfGenerator.swift`
- Create: `BookManagerCore/Library/BookFolder.swift`
- Test: `BookManagerCoreTests/Library/BookFolderTests.swift`

**Interfaces:**

- Consumes: `ResolvedBook`, `BookFormatValue`, `LibraryLayout` (Slice 1).
- Produces: `CanonicalPathBuilder.formatFileName(title:authors:kind:)`, `OpfGenerator.opfData(bookID:resolved:)`, and `BookFolder` actor with:
  - `struct StagedFile: Sendable { kind, contentHash, size, url }`
  - `func stage(from sourceURL: URL) throws -> StagedFile`
  - `func materialize(bookID: UUID, resolved: ResolvedBook, staged: [StagedFile], cover: Data?) throws -> (path: String, formats: [BookFormatValue])`
  - `func trash(bookID: UUID, relativePath: String) throws`
  - `func restore(bookID: UUID, relativePath: String) throws -> String`
  - `func rename(bookID: UUID, from oldPath: String, to newPath: String, oldFormats: [BookFormatValue], newFormats: [BookFormatValue]) throws`
  - `func formatFileURL(relativePath: String, filename: String) -> URL`
  - `func bookDirectoryURL(relativePath: String) -> URL`

- [ ] **Step 1: Write the folder behavior tests**

Create `BookManagerCoreTests/Library/BookFolderTests.swift`:

```swift
import Foundation
import Testing
@testable import BookManagerCore

@Suite
struct BookFolderTests {
    private func makeLayout() throws -> (root: URL, layout: LibraryLayout) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let layout = LibraryLayout(root: root)
        try layout.create(manifest: LibraryManifest(id: UUID()))
        return (root, layout)
    }

    @Test
    func formatFileNameCombinesTitleAuthorAndKind() {
        let name = CanonicalPathBuilder.formatFileName(
            title: "Range: Why Generalists Triumph?",
            authors: ["David Epstein"],
            kind: "EPUB"
        )
        #expect(name == "Range_ Why Generalists Triumph_ - David Epstein.epub")
    }

    @Test
    func materializeCreatesCalibreStyleFolderWithFilesAndSidecars() async throws {
        let (root, layout) = try makeLayout()
        let folder = BookFolder(layout: layout)
        let bookID = UUID()
        let resolved = ResolvedBook(
            id: bookID,
            title: "Range",
            authors: ["David Epstein"],
            series: nil, seriesIndex: nil,
            tags: [], rating: nil, publisher: nil,
            publicationDate: nil, addedDate: nil,
            languages: [], identifiers: [:], comments: nil,
            formats: [], cover: nil,
            isDeleted: false,
            modifiedClock: HybridLogicalClock(physicalMilliseconds: 1, nodeID: UUID())
        )
        let source = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).epub")
        try Data("epub-bytes".utf8).write(to: source)

        let staged = try await folder.stage(from: source)
        #expect(staged.kind == "EPUB")
        #expect(staged.contentHash == "bd93fefcffbd3707e18d27bd9faca7b7")
        #expect(staged.size == 10)

        let result = try await folder.materialize(
            bookID: bookID,
            resolved: resolved,
            staged: [staged],
            cover: nil
        )

        #expect(result.path == "David Epstein/Range (\(String(bookID.uuidString.prefix(8)).lowercased()))")
        let dir = folder.bookDirectoryURL(relativePath: result.path)
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "Range - David Epstein.epub").path))
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "metadata.opf").path))
        #expect(result.formats.count == 1)
        #expect(result.formats[0].filename == "Range - David Epstein.epub")
        #expect(!FileManager.default.fileExists(atPath: source.path))
    }

    @Test
    func materializeWritesCoverAndOpf() async throws {
        let (root, layout) = try makeLayout()
        let folder = BookFolder(layout: layout)
        let bookID = UUID()
        let resolved = ResolvedBook(
            id: bookID, title: "Range", authors: ["David Epstein"],
            series: "Studies", seriesIndex: 1, tags: ["science"], rating: 4,
            publisher: "Riverhead", publicationDate: Date(timeIntervalSince1970: 1_000),
            addedDate: Date(timeIntervalSince1970: 2_000), languages: ["eng"],
            identifiers: ["isbn": "123"], comments: "A book.",
            formats: [], cover: nil, isDeleted: false,
            modifiedClock: HybridLogicalClock(physicalMilliseconds: 1, nodeID: UUID())
        )
        let coverBytes = try Self.jpegFixture()

        let result = try await folder.materialize(
            bookID: bookID, resolved: resolved, staged: [], cover: coverBytes
        )

        let dir = folder.bookDirectoryURL(relativePath: result.path)
        let coverURL = dir.appending(path: "cover.jpg")
        #expect(FileManager.default.fileExists(atPath: coverURL.path))
        let opf = try String(contentsOf: dir.appending(path: "metadata.opf"), encoding: .utf8)
        #expect(opf.contains("<dc:title>Range</dc:title>"))
        #expect(opf.contains("<dc:creator>David Epstein</dc:creator>"))
        #expect(opf.contains("Studies"))
    }

    @Test
    func renameMovesFolderAndSidecars() async throws {
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
        let old = try await folder.materialize(bookID: bookID, resolved: resolved, staged: [], cover: nil)

        let edited = ResolvedBook(
            id: bookID, title: "Range: Revised", authors: ["David Epstein"],
            series: nil, seriesIndex: nil, tags: [], rating: nil, publisher: nil,
            publicationDate: nil, addedDate: nil, languages: [], identifiers: [:],
            comments: nil, formats: [], cover: nil, isDeleted: false,
            modifiedClock: HybridLogicalClock(physicalMilliseconds: 2, nodeID: UUID())
        )
        let newPath = CanonicalPathBuilder.relativeDirectory(
            bookID: bookID, title: "Range: Revised", authors: ["David Epstein"]
        )
        try await folder.rename(bookID: bookID, from: old.path, to: newPath, oldFormats: [], newFormats: [])

        let oldDir = folder.bookDirectoryURL(relativePath: old.path)
        let newDir = folder.bookDirectoryURL(relativePath: newPath)
        #expect(!FileManager.default.fileExists(atPath: oldDir.path))
        #expect(FileManager.default.fileExists(atPath: newDir.appending(path: "metadata.opf").path))
        #expect(layout.transactionsRoot.children().isEmpty)
    }

    @Test
    func trashAndRestoreRoundTrip() async throws {
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

        try await folder.trash(bookID: bookID, relativePath: materialized.path)
        #expect(!FileManager.default.fileExists(atPath: folder.bookDirectoryURL(relativePath: materialized.path).path))

        let restored = try await folder.restore(bookID: bookID, relativePath: materialized.path)
        #expect(restored == materialized.path)
        #expect(FileManager.default.fileExists(atPath: folder.bookDirectoryURL(relativePath: restored).path))
        #expect(layout.transactionsRoot.children().isEmpty)
    }

    private static func jpegFixture() throws -> Data {
        // 1x1 red JPEG produced via ImageIO.
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        let image = context.makeImage()!
        let destination = CGImageDestinationCreateWithData(
            NSMutableData(), "public.jpeg" as CFString, 1, nil
        )!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return destination as! Data
    }
}

private extension URL {
    var children: [URL] {
        (try? FileManager.default.contentsOfDirectory(at: self, includingPropertiesForKeys: nil)) ?? []
    }
}
```

Note: `staged.contentHash` of `"epub-bytes"` is `bd93fefcffbd3707e18d27bd9faca7b7` (SHA-256, first 32 hex chars). The implementation hashes 32 hex characters (the `amchange` filenames use 64; book hashes use the first 32).

- [ ] **Step 2: Run the folder tests to verify they fail**

```bash
xcodegen generate --spec project.yml
xcodebuild -project BookManager.xcodeproj -scheme BookManager -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:BookManagerCoreTests/BookFolderTests test
```

Expected: compilation fails (`BookFolder`, `OpfGenerator`, `formatFileName` undefined).

- [ ] **Step 3: Add the canonical format filename**

Append to `BookManagerCore/Library/CanonicalPathBuilder.swift`:

```swift
    public static func formatFileName(
        title: String,
        authors: [String],
        kind: String
    ) -> String {
        let safeTitle = sanitized(title.isEmpty ? "Unknown" : title)
        let author = sanitized(authors.first ?? "Unknown")
        return "\(safeTitle) - \(author).\(kind.lowercased())"
    }
```

- [ ] **Step 4: Add the OPF projection generator**

Create `BookManagerCore/Library/OpfGenerator.swift`:

```swift
import Foundation

public enum OpfGenerator {
    /// Minimal, portable OPF 2.0 projection of merged metadata. Not a synchronization authority.
    public static func opfData(bookID: UUID, resolved: ResolvedBook) -> Data {
        let shortID = String(bookID.uuidString.prefix(8)).lowercased()
        let seriesMeta: String
        if let series = resolved.series, !series.isEmpty {
            let index = resolved.seriesIndex.map { String($0) } ?? ""
            seriesMeta = """
                <meta name="calibre:series" content="\(escaped(series))"/><meta name="calibre:series_index" content="\(escaped(index))"/>
            """
        } else {
            seriesMeta = ""
        }
        let tags = resolved.tags.map { "<dc:subject>\(escaped($0))</dc:subject>" }.joined()
        let identifiers = resolved.identifiers.map { type, value in
            "<dc:identifier opf:scheme=\"\(escaped(type.uppercased()))\">\(escaped(value))</dc:identifier>"
        }.joined()

        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="bookid">
        <metadata>
        <dc:identifier opf:scheme="BOOKMANAGER" id="bookid">\(shortID)</dc:identifier>
        <dc:title>\(escaped(resolved.title))</dc:title>
        \(resolved.authors.map { "<dc:creator opf:role=\"aut\">\(escaped($0))</dc:creator>" }.joined(separator: "\n"))
        \(tags)
        \(identifiers)
        \(seriesMeta)
        </metadata>
        </package>
        """

        return Data(xml.utf8)
    }

    private static func escaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
```

- [ ] **Step 5: Implement the BookFolder actor**

Create `BookManagerCore/Library/BookFolder.swift`:

```swift
import CryptoKit
import Foundation

/// Owns the physical book folders inside a library: staging, materialization,
/// metadata-driven renames, and trash/restore. All multi-step mutations are
/// journaled so an interrupted operation is visible in diagnostics.
public actor BookFolder {
    public struct StagedFile: Sendable {
        public let kind: String
        public let contentHash: String
        public let size: Int64
        public let url: URL

        public init(kind: String, contentHash: String, size: Int64, url: URL) {
            self.kind = kind
            self.contentHash = contentHash
            self.size = size
            self.url = url
        }
    }

    private struct JournalEntry: Codable {
        var operation: String
        var bookID: UUID
        var oldPath: String?
        var newPath: String?
    }

    private let layout: LibraryLayout
    private let manager = FileManager.default

    public init(layout: LibraryLayout) {
        self.layout = layout
    }

    private var stagingRoot: URL {
        layout.controlRoot.appending(path: "staging", directoryHint: .isDirectory)
    }

    public func stage(from sourceURL: URL) throws -> StagedFile {
        let kind = sourceURL.pathExtension.uppercased()
        let stagingDir = stagingRoot.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try manager.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let destination = stagingDir.appending(path: sourceURL.lastPathComponent)
        try manager.copyItem(at: sourceURL, to: destination)
        let data = try Data(contentsOf: destination)
        let hash = Self.contentHash(data)
        return StagedFile(kind: kind, contentHash: hash, size: Int64(data.count), url: destination)
    }

    public static func contentHash(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined().prefix(32).description
    }

    @discardableResult
    public func materialize(
        bookID: UUID,
        resolved: ResolvedBook,
        staged: [StagedFile],
        cover: Data?
    ) throws -> (path: String, formats: [BookFormatValue]) {
        let path = CanonicalPathBuilder.relativeDirectory(
            bookID: bookID,
            title: resolved.title,
            authors: resolved.authors
        )
        let directory = bookDirectoryURL(relativePath: path)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)

        var formats: [BookFormatValue] = []
        for file in staged {
            let filename = CanonicalPathBuilder.formatFileName(
                title: resolved.title,
                authors: resolved.authors,
                kind: file.kind
            )
            let destination = directory.appending(path: filename)
            try manager.moveItem(at: file.url, to: destination)
            formats.append(
                BookFormatValue(
                    kind: file.kind,
                    filename: filename,
                    contentHash: file.contentHash,
                    size: file.size
                )
            )
        }

        if let cover {
            try cover.write(to: directory.appending(path: "cover.jpg"), options: .atomic)
        }

        try OpfGenerator.opfData(bookID: bookID, resolved: resolved)
            .write(to: directory.appending(path: "metadata.opf"), options: .atomic)

        return (path, formats)
    }

    public func trash(bookID: UUID, relativePath: String) throws {
        let journal = try begin(operation: "trash", bookID: bookID, oldPath: relativePath, newPath: nil)
        defer { try? end(journal) }
        let source = bookDirectoryURL(relativePath: relativePath)
        let trashDir = layout.trashRoot.appending(path: bookID.uuidString, directoryHint: .isDirectory)
        if manager.fileExists(atPath: source.path) {
            try manager.createDirectory(at: layout.trashRoot, withIntermediateDirectories: true)
            try manager.moveItem(at: source, to: trashDir)
        }
    }

    public func restore(bookID: UUID, relativePath: String) throws -> String {
        let trashDir = layout.trashRoot.appending(path: bookID.uuidString, directoryHint: .isDirectory)
        guard manager.fileExists(atPath: trashDir.path) else {
            throw BookFolderError.trashEntryMissing(bookID)
        }
        let target = bookDirectoryURL(relativePath: relativePath)
        try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let journal = try begin(operation: "restore", bookID: bookID, oldPath: relativePath, newPath: relativePath)
        defer { try? end(journal) }
        try manager.moveItem(at: trashDir, to: target)
        return relativePath
    }

    public func rename(
        bookID: UUID,
        from oldPath: String,
        to newPath: String,
        oldFormats: [BookFormatValue],
        newFormats: [BookFormatValue]
    ) throws {
        guard oldPath != newPath else { return }
        let oldDir = bookDirectoryURL(relativePath: oldPath)
        guard manager.fileExists(atPath: oldDir.path) else { return }
        let newDir = bookDirectoryURL(relativePath: newPath)
        try manager.createDirectory(at: newDir.deletingLastPathComponent(), withIntermediateDirectories: true)

        let journal = try begin(operation: "rename", bookID: bookID, oldPath: oldPath, newPath: newPath)
        defer { try? end(journal) }

        // Move the folder first, then rename format files whose canonical name changed.
        try manager.moveItem(at: oldDir, to: newDir)
        for old in oldFormats {
            guard let new = newFormats.first(where: { $0.kind == old.kind }),
                  new.filename != old.filename else {
                continue
            }
            let oldFile = newDir.appending(path: old.filename)
            let newFile = newDir.appending(path: new.filename)
            if manager.fileExists(atPath: oldFile.path) && !manager.fileExists(atPath: newFile.path) {
                try manager.moveItem(at: oldFile, to: newFile)
            }
        }
    }

    public func formatFileURL(relativePath: String, filename: String) -> URL {
        bookDirectoryURL(relativePath: relativePath).appending(path: filename)
    }

    public func bookDirectoryURL(relativePath: String) -> URL {
        layout.root.appending(path: relativePath, directoryHint: .isDirectory)
    }

    public func trashDirectoryURL(bookID: UUID) -> URL {
        layout.trashRoot.appending(path: bookID.uuidString, directoryHint: .isDirectory)
    }

    private func begin(operation: String, bookID: UUID, oldPath: String?, newPath: String?) throws -> URL {
        try manager.createDirectory(at: layout.transactionsRoot, withIntermediateDirectories: true)
        let entry = JournalEntry(operation: operation, bookID: bookID, oldPath: oldPath, newPath: newPath)
        let url = layout.transactionsRoot.appending(path: "\(UUID().uuidString).json")
        let data = try JSONEncoder().encode(entry)
        try data.write(to: url, options: .atomic)
        return url
    }

    private func end(_ journal: URL) throws {
        try manager.removeItem(at: journal)
    }
}

public enum BookFolderError: Error, Equatable {
    case trashEntryMissing(UUID)
}
```

- [ ] **Step 6: Run the folder tests**

Run the command from Step 2. Expected: all five tests pass. If the SHA-256 expectation differs, update the test to the real 32-hex hash of `"epub-bytes"` (compute with `printf epub-bytes | shasum`).

- [ ] **Step 7: Run the full core suite**

```bash
xcodebuild -project BookManager.xcodeproj -scheme BookManager -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:BookManagerCoreTests test
```

- [ ] **Step 8: Commit**

```bash
git add BookManagerCore/Library BookManagerCoreTests/Library
git commit -m "feat: materialize Calibre-style book folders"
```

### Task 3: Expanded GRDB Catalogue

**Files:**

- Modify: `BookManagerCore/Persistence/IndexedBook.swift`
- Modify: `BookManagerCore/Persistence/LocalCatalog.swift`
- Modify: `BookManagerCoreTests/Persistence/LocalCatalogTests.swift`
- Test: `BookManagerCoreTests/Persistence/LocalCatalogV2Tests.swift`

**Interfaces:**

- Consumes: `BookFormatValue`, `FacetType` (Task 1).
- Produces: `BookFormatRecord {kind, filename, contentHash, size}` (Codable), v2 `IndexedBook` with `init(row:)` decoding, and `LocalCatalog` v2 API:
  - `upsert(_:)` (unchanged name), `allBooks()`, `search(_:)`, `snapshot(bookID:)`, `clear()`
  - `books(facetType:value:)`, `facetCounts(_:) -> [(value: String, count: Int)]`, `deletedBooks()`, `book(id:)`, `bookIDs(byFormatHash:)`

- [ ] **Step 1: Write the v2 catalogue tests**

Create `BookManagerCoreTests/Persistence/LocalCatalogV2Tests.swift`:

```swift
import Foundation
import Testing
@testable import BookManagerCore

@Suite
struct LocalCatalogV2Tests {
    private func catalog() throws -> LocalCatalog {
        let databaseURL = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).sqlite")
        return try LocalCatalog(databaseURL: databaseURL)
    }

    private func book(
        id: UUID = UUID(),
        title: String = "Range",
        authors: [String] = ["David Epstein"],
        series: String? = nil,
        tags: [String] = [],
        formats: [BookFormatRecord] = [],
        deleted: Bool = false
    ) -> IndexedBook {
        IndexedBook(
            id: id, title: title, authors: authors,
            series: series, seriesIndex: series == nil ? nil : 1,
            tags: tags, rating: 4, publisher: "Riverhead",
            publicationMilliseconds: 1_000, addedMilliseconds: 2_000,
            languages: ["eng"], identifiers: ["isbn": "1234"],
            comments: "A great book", formats: formats,
            coverHash: nil, relativePath: "David Epstein/Range (12345678)",
            modifiedMilliseconds: 1_000, isDeleted: deleted,
            snapshot: Data([1, 2, 3])
        )
    }

    @Test
    func facetsCountAndFilter() async throws {
        let catalog = try catalog()
        try await catalog.upsert(book(title: "Range", authors: ["David Epstein"], tags: ["science"], series: "Studies"))
        try await catalog.upsert(book(id: UUID(), title: "Talent", authors: ["Daniel Coyle"], tags: ["science", "sport"], series: "Studies"))
        try await catalog.upsert(book(id: UUID(), title: "Solo", authors: ["Alice"], tags: ["fiction"]))

        let authors = try await catalog.facetCounts(.author)
        #expect(Set(authors.map(\.value)) == ["David Epstein", "Daniel Coyle", "Alice"])
        #expect(authors.allSatisfy { $0.count == 1 })

        let series = try await catalog.facetCounts(.series)
        #expect(series.first { $0.value == "Studies" }?.count == 2)

        let tags = try await catalog.facetCounts(.tag)
        #expect(tags.first { $0.value == "science" }?.count == 2)

        let filtered = try await catalog.books(facetType: .tag, value: "science")
        #expect(filtered.map(\.title).sorted() == ["Range", "Talent"])
    }

    @Test
    func searchCoversSeriesTagsAndIdentifiers() async throws {
        let catalog = try catalog()
        try await catalog.upsert(book(title: "Range", tags: ["biology"], identifiers: ["isbn": "978-0-7352-2129-1"]))
        try await catalog.upsert(book(id: UUID(), title: "Other", authors: ["Someone"]))

        #expect(try await catalog.search("biology").count == 1)
        #expect(try await catalog.search("2129").count == 1)
    }

    @Test
    func deletedBooksAreQueryableButExcludedFromNormalQueries() async throws {
        let catalog = try catalog()
        let deleted = book(title: "Gone", deleted: true)
        try await catalog.upsert(deleted)
        try await catalog.upsert(book(title: "Here"))

        #expect(try await catalog.allBooks().map(\.title) == ["Here"])
        #expect(try await catalog.deletedBooks().map(\.title) == ["Gone"])
        #expect(try await catalog.book(id: deleted.id)?.title == "Gone")
    }

    @Test
    func formatHashLookupFindsDuplicates() async throws {
        let catalog = try catalog()
        let format = BookFormatRecord(kind: "EPUB", filename: "a.epub", contentHash: "deadbeef", size: 10)
        let id = UUID()
        try await catalog.upsert(book(id: id, formats: [format]))

        #expect(try await catalog.bookIDs(byFormatHash: "deadbeef") == [id])
        #expect(try await catalog.bookIDs(byFormatHash: "cafebabe").isEmpty)
    }

    @Test
    func reupsertRefreshesFacetsAndHashes() async throws {
        let catalog = try catalog()
        let id = UUID()
        try await catalog.upsert(book(id: id, title: "Range", tags: ["science"], formats: [
            BookFormatRecord(kind: "EPUB", filename: "a.epub", contentHash: "h1", size: 1)
        ]))
        try await catalog.upsert(book(id: id, title: "Range", tags: ["fiction"], formats: [
            BookFormatRecord(kind: "PDF", filename: "b.pdf", contentHash: "h2", size: 2)
        ]))

        #expect(try await catalog.facetCounts(.tag).map(\.value) == ["fiction"])
        #expect(try await catalog.bookIDs(byFormatHash: "h2") == [id])
        #expect(try await catalog.bookIDs(byFormatHash: "h1").isEmpty)
        #expect(try await catalog.allBooks().first?.formats.first?.kind == "PDF")
    }
}
```

- [ ] **Step 2: Run the v2 catalogue tests to verify they fail**

```bash
xcodegen generate --spec project.yml
xcodebuild -project BookManager.xcodeproj -scheme BookManager -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:BookManagerCoreTests/LocalCatalogV2Tests test
```

Expected: compilation fails (`BookFormatRecord`, v2 `IndexedBook`, v2 `LocalCatalog` undefined).

- [ ] **Step 3: Add JSON coding helpers and replace IndexedBook**

Create `BookManagerCore/Persistence/JSONCoding.swift`:

```swift
import Foundation

enum JSONCoding {
    static func encode<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    static func decode<T: Decodable>(_ type: T.Type, from string: String?) throws -> T? {
        guard let string, !string.isEmpty else { return nil }
        return try JSONDecoder().decode(type, from: Data(string.utf8))
    }
}
```

Replace the contents of `BookManagerCore/Persistence/IndexedBook.swift`:

```swift
import Foundation
import GRDB

public struct BookFormatRecord: Codable, Equatable, Sendable {
    public let kind: String
    public let filename: String
    public let contentHash: String
    public let size: Int64

    public init(kind: String, filename: String, contentHash: String, size: Int64) {
        self.kind = kind
        self.filename = filename
        self.contentHash = contentHash
        self.size = size
    }
}

public struct IndexedBook: Identifiable, Equatable, Sendable {
    // Snapshot bytes are deliberately excluded from equality: two replicas that
    // converged on identical metadata have identical snapshots, but rebuilds from
    // change files may serialize documents under a different actor identity.
    public static func == (lhs: IndexedBook, rhs: IndexedBook) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.authors == rhs.authors
            && lhs.series == rhs.series && lhs.seriesIndex == rhs.seriesIndex
            && lhs.tags == rhs.tags && lhs.rating == rhs.rating && lhs.publisher == rhs.publisher
            && lhs.publicationMilliseconds == rhs.publicationMilliseconds
            && lhs.addedMilliseconds == rhs.addedMilliseconds && lhs.languages == rhs.languages
            && lhs.identifiers == rhs.identifiers && lhs.comments == rhs.comments
            && lhs.formats == rhs.formats && lhs.coverHash == rhs.coverHash
            && lhs.relativePath == rhs.relativePath
            && lhs.modifiedMilliseconds == rhs.modifiedMilliseconds && lhs.isDeleted == rhs.isDeleted
    }
    public let id: UUID
    public let title: String
    public let authors: [String]
    public let series: String?
    public let seriesIndex: Double?
    public let tags: [String]
    public let rating: Int?
    public let publisher: String?
    public let publicationMilliseconds: Int64?
    public let addedMilliseconds: Int64?
    public let languages: [String]
    public let identifiers: [String: String]
    public let comments: String?
    public let formats: [BookFormatRecord]
    public let coverHash: String?
    public let relativePath: String
    public let modifiedMilliseconds: Int64
    public let isDeleted: Bool
    public let snapshot: Data

    public init(
        id: UUID,
        title: String,
        authors: [String],
        series: String? = nil,
        seriesIndex: Double? = nil,
        tags: [String] = [],
        rating: Int? = nil,
        publisher: String? = nil,
        publicationMilliseconds: Int64? = nil,
        addedMilliseconds: Int64? = nil,
        languages: [String] = [],
        identifiers: [String: String] = [:],
        comments: String? = nil,
        formats: [BookFormatRecord] = [],
        coverHash: String? = nil,
        relativePath: String = "",
        modifiedMilliseconds: Int64,
        isDeleted: Bool,
        snapshot: Data
    ) {
        self.id = id
        self.title = title
        self.authors = authors
        self.series = series
        self.seriesIndex = seriesIndex
        self.tags = tags
        self.rating = rating
        self.publisher = publisher
        self.publicationMilliseconds = publicationMilliseconds
        self.addedMilliseconds = addedMilliseconds
        self.languages = languages
        self.identifiers = identifiers
        self.comments = comments
        self.formats = formats
        self.coverHash = coverHash
        self.relativePath = relativePath
        self.modifiedMilliseconds = modifiedMilliseconds
        self.isDeleted = isDeleted
        self.snapshot = snapshot
    }

    public var publicationDate: Date? {
        publicationMilliseconds.map { Date(timeIntervalSince1970: TimeInterval($0) / 1_000) }
    }

    public var addedDate: Date? {
        addedMilliseconds.map { Date(timeIntervalSince1970: TimeInterval($0) / 1_000) }
    }
}

extension IndexedBook: FetchableRecord {
    public init(row: Row) {
        id = UUID(uuidString: row["id"] as String) ?? UUID()
        title = row["title"] as String
        authors = (try? JSONCoding.decode([String].self, from: row["authors"] as String?)) ?? []
        series = row["series"] as String?
        seriesIndex = row["seriesIndex"] as Double?
        tags = (try? JSONCoding.decode([String].self, from: row["tags"] as String?)) ?? []
        rating = row["rating"] as Int?
        publisher = row["publisher"] as String?
        publicationMilliseconds = row["publicationMilliseconds"] as Int64?
        addedMilliseconds = row["addedMilliseconds"] as Int64?
        languages = (try? JSONCoding.decode([String].self, from: row["languages"] as String?)) ?? []
        identifiers = (try? JSONCoding.decode([String: String].self, from: row["identifiers"] as String?)) ?? [:]
        comments = row["comments"] as String?
        formats = (try? JSONCoding.decode([BookFormatRecord].self, from: row["formats"] as String?)) ?? []
        coverHash = row["coverHash"] as String?
        relativePath = row["relativePath"] as String ?? ""
        modifiedMilliseconds = row["modifiedMilliseconds"] as Int64 ?? 0
        isDeleted = row["isDeleted"] as Bool ?? false
        snapshot = row["snapshot"] as Data ?? Data()
    }
}
```

Note: the v1 `LocalCatalogTests` construct `IndexedBook(id:title:authors:modifiedMilliseconds:isDeleted:snapshot:)` — those are now `id`, `title`, `authors`, defaulted fields, `modifiedMilliseconds`, `isDeleted`, `snapshot`, which still compiles unchanged thanks to the defaults above. Verify in Step 8.

- [ ] **Step 4: Replace LocalCatalog with the v2 implementation**

Replace the contents of `BookManagerCore/Persistence/LocalCatalog.swift`:

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
        let authorsJSON = try JSONCoding.encode(book.authors)
        let tagsJSON = try JSONCoding.encode(book.tags)
        let languagesJSON = try JSONCoding.encode(book.languages)
        let identifiersJSON = try JSONCoding.encode(book.identifiers)
        let formatsJSON = try JSONCoding.encode(book.formats)
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO book(id, title, authors, series, seriesIndex, tags, rating, publisher,
                        publicationMilliseconds, addedMilliseconds, languages, identifiers, comments,
                        formats, coverHash, relativePath, modifiedMilliseconds, isDeleted, snapshot)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        title = excluded.title, authors = excluded.authors, series = excluded.series,
                        seriesIndex = excluded.seriesIndex, tags = excluded.tags, rating = excluded.rating,
                        publisher = excluded.publisher,
                        publicationMilliseconds = excluded.publicationMilliseconds,
                        addedMilliseconds = excluded.addedMilliseconds, languages = excluded.languages,
                        identifiers = excluded.identifiers, comments = excluded.comments,
                        formats = excluded.formats, coverHash = excluded.coverHash,
                        relativePath = excluded.relativePath, modifiedMilliseconds = excluded.modifiedMilliseconds,
                        isDeleted = excluded.isDeleted, snapshot = excluded.snapshot
                    """,
                arguments: [
                    book.id.uuidString, book.title, authorsJSON, book.series,
                    book.seriesIndex, book.rating,
                    book.publisher, book.publicationMilliseconds,
                    book.addedMilliseconds, languagesJSON, identifiersJSON,
                    book.comments, formatsJSON, book.coverHash, book.relativePath,
                    book.modifiedMilliseconds, book.isDeleted, book.snapshot
                ]
            )
            try db.execute(sql: "DELETE FROM bookSearch WHERE bookID = ?", arguments: [book.id.uuidString])
            try db.execute(
                sql: "INSERT INTO bookSearch(bookID, title, authors, series, tags, identifiers, comments) VALUES (?, ?, ?, ?, ?, ?, ?)",
                arguments: [
                    book.id.uuidString, book.title, book.authors.joined(separator: " "),
                    book.series ?? "", book.tags.joined(separator: " "),
                    book.identifiers.values.joined(separator: " "), book.comments ?? ""
                ]
            )
            try db.execute(sql: "DELETE FROM bookFacet WHERE bookID = ?", arguments: [book.id.uuidString])
            for author in book.authors {
                try insertFacet(db, type: "author", value: author, bookID: book.id)
            }
            if let series = book.series, !series.isEmpty {
                try insertFacet(db, type: "series", value: series, bookID: book.id)
            }
            for tag in book.tags {
                try insertFacet(db, type: "tag", value: tag, bookID: book.id)
            }
            for format in book.formats {
                try insertFacet(db, type: "format", value: format.kind, bookID: book.id)
            }
            try db.execute(sql: "DELETE FROM bookFormatHash WHERE bookID = ?", arguments: [book.id.uuidString])
            for format in book.formats {
                try db.execute(
                    sql: "INSERT INTO bookFormatHash(bookID, kind, contentHash) VALUES (?, ?, ?)",
                    arguments: [book.id.uuidString, format.kind, format.contentHash]
                )
            }
        }
    }

    public func allBooks() throws -> [IndexedBook] {
        try database.read { db in
            try IndexedBook.fetchAll(
                db,
                sql: "SELECT * FROM book WHERE isDeleted = 0 ORDER BY title COLLATE NOCASE"
            )
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
                    SELECT book.* FROM book
                    JOIN bookSearch ON bookSearch.bookID = book.id
                    WHERE bookSearch MATCH ? AND book.isDeleted = 0
                    ORDER BY book.title COLLATE NOCASE
                    """,
                arguments: [query]
            )
        }
    }

    public func books(facetType: FacetType, value: String) throws -> [IndexedBook] {
        try database.read { db in
            try IndexedBook.fetchAll(
                db,
                sql: """
                    SELECT book.* FROM book
                    JOIN bookFacet ON bookFacet.bookID = book.id
                    WHERE bookFacet.type = ? AND bookFacet.value = ? AND book.isDeleted = 0
                    ORDER BY book.title COLLATE NOCASE
                    """,
                arguments: [facetType.rawValue, value]
            )
        }
    }

    public func facetCounts(_ type: FacetType) throws -> [(value: String, count: Int)] {
        try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT value, COUNT(*) AS count FROM bookFacet
                    WHERE type = ? GROUP BY value ORDER BY value COLLATE NOCASE
                    """,
                arguments: [type.rawValue]
            )
            return rows.map { (value: $0["value"] as String, count: $0["count"] as Int) }
        }
    }

    public func deletedBooks() throws -> [IndexedBook] {
        try database.read { db in
            try IndexedBook.fetchAll(
                db,
                sql: "SELECT * FROM book WHERE isDeleted = 1 ORDER BY title COLLATE NOCASE"
            )
        }
    }

    public func book(id: UUID) throws -> IndexedBook? {
        try database.read { db in
            try IndexedBook.fetchOne(
                db,
                sql: "SELECT * FROM book WHERE id = ?",
                arguments: [id.uuidString]
            )
        }
    }

    public func bookIDs(byFormatHash contentHash: String) throws -> [UUID] {
        try database.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT bookID FROM bookFormatHash WHERE contentHash = ?",
                arguments: [contentHash]
            ).compactMap { UUID(uuidString: $0) }
        }
    }

    public func snapshot(bookID: UUID) throws -> Data? {
        try database.read { db in
            try Data.fetchOne(
                db,
                sql: "SELECT snapshot FROM book WHERE id = ?",
                arguments: [bookID.uuidString]
            )
        }
    }

    public func clear() throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM book")
            try db.execute(sql: "DELETE FROM bookSearch")
            try db.execute(sql: "DELETE FROM bookFacet")
            try db.execute(sql: "DELETE FROM bookFormatHash")
        }
    }

    private func insertFacet(_ db: Database, type: String, value: String, bookID: UUID) throws {
        try db.execute(
            sql: "INSERT INTO bookFacet(type, value, bookID) VALUES (?, ?, ?)",
            arguments: [type, value, bookID.uuidString]
        )
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("createBookIndex") { db in
            try createV1Schema(db)
        }
        migrator.registerMigration("v2ExpandedBook") { db in
            try db.drop(table: "book")
            try db.drop(table: "bookSearch")
            try createV2Schema(db)
        }
        return migrator
    }

    private static func createV1Schema(_ db: Database) throws {
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

    private static func createV2Schema(_ db: Database) throws {
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
    }
}
```

- [ ] **Step 5: Update the v1 catalogue tests for the v2 record**

`BookManagerCoreTests/Persistence/LocalCatalogTests.swift` should still compile (defaulted parameters). Run it to confirm; the only required edit is if GRDB's `Row` subscript needs different casts — fix only what fails.

- [ ] **Step 6: Run the v2 catalogue tests**

Run the command from Step 2. Expected: all five tests pass.

- [ ] **Step 7: Run the full core suite**

```bash
xcodebuild -project BookManager.xcodeproj -scheme BookManager -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:BookManagerCoreTests test
```

Expected: slice-1 tests (including `LocalCatalogTests`) still pass.

- [ ] **Step 8: Commit**

```bash
git add BookManagerCore/Persistence BookManagerCoreTests/Persistence
git commit -m "feat: expand catalogue with facets and format hashes"
```

### Task 4: Metadata Extraction and Staged Import

**Files:**

- Modify: `project.yml` (add ZIPFoundation to Core + test targets)
- Create: `BookManagerCore/Import/MetadataExtractor.swift`
- Create: `BookManagerCore/Import/ImportService.swift`
- Create: `BookManagerCoreTests/Import/Fixtures.swift`
- Create: `BookManagerCoreTests/Import/MetadataExtractorTests.swift`
- Test: `BookManagerCoreTests/Import/ImportServiceTests.swift`

**Interfaces:**

- Consumes: `BookFolder.StagedFile`, `BookFolder` (Task 2), `NewBookMetadata`, `LibraryRepository` (Task 5's `createBook(metadata:staged:cover:)` — implemented in Task 5, used here via protocol-shaped calls; the tests in this task use a thin test double for the repository).
- Produces: `MetadataExtractor` with `kind(for:) -> FormatKind?`, `extract(from:kind:) -> ExtractedMetadata`, `extractCover(from:kind:) -> Data?`; `ImportService` actor with `importFiles(_:into:) -> ImportReport`; `ImportReport` + `ImportItem` with statuses `.imported/.duplicate/.failed`.

- [ ] **Step 1: Add ZIPFoundation to the project**

In `project.yml`:

1. In the `packages:` block, add:

```yaml
  ZIPFoundation:
    url: https://github.com/weichsel/ZIPFoundation.git
    exactVersion: 0.9.19
```

1. In the `BookManagerCore` target's `dependencies:` (currently `- package: Automerge` / `- package: GRDB`), add `- package: ZIPFoundation`.

2. In the `BookManagerCoreTests` target's `dependencies:` (currently `- target: BookManagerCore`), add `- package: ZIPFoundation` so the test fixtures can build EPUB archives.

- [ ] **Step 2: Write the extractor tests and fixtures**

Create `BookManagerCoreTests/Import/Fixtures.swift`:

```swift
import Foundation
import ZIPFoundation

enum Fixtures {
    /// A minimal EPUB 2.0 archive with one book and a cover PNG.
    static func makeEPUB(named name: String = "book.epub") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: name)
        try? FileManager.default.removeItem(at: url)
        let archive = try Archive(url: url, accessMode: .create)
        try archive.addEntry(
            with: "mimetype", type: .file, uncompressedSize: 20,
            compressionMethod: .none,
            provider: { _, _ in Data("application/epub+zip".utf8) }
        )
        let container = """
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """
        try archive.addEntry(
            with: "META-INF/container.xml", type: .file,
            uncompressedSize: UInt32(container.utf8.count),
            provider: { _, _ in Data(container.utf8) }
        )
        let opf = """
        <?xml version="1.0" encoding="utf-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/" version="2.0" unique-identifier="uid">
        <metadata>
          <dc:identifier id="uid" opf:scheme="ISBN">978-0-7352-2129-1</dc:identifier>
          <dc:title>Range: Why Generalists Triumph in a Specialized World</dc:title>
          <dc:creator opf:role="aut">David Epstein</dc:creator>
          <dc:language>eng</dc:language>
          <dc:date>2019-05-28</dc:date>
          <dc:subject>Science</dc:subject>
          <dc:description>Why generalists beat specialists.</dc:description>
          <meta name="calibre:series" content="Studies"/>
          <meta name="calibre:series_index" content="1.5"/>
          <meta name="cover" content="cover-image"/>
        </metadata>
        <manifest>
          <item id="cover-image" href="cover.png" media-type="image/png" properties="cover-image"/>
          <item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>
        </manifest>
        </package>
        """
        try archive.addEntry(
            with: "OEBPS/content.opf", type: .file,
            uncompressedSize: UInt32(opf.utf8.count),
            provider: { _, _ in Data(opf.utf8) }
        )
        let coverPNG = Fixtures.png1x1()
        try archive.addEntry(
            with: "OEBPS/cover.png", type: .file,
            uncompressedSize: UInt32(coverPNG.count),
            provider: { _, _ in coverPNG }
        )
        try archive.addEntry(
            with: "OEBPS/chapter.xhtml", type: .file,
            uncompressedSize: UInt32(Data("<p/>".utf8).count),
            provider: { _, _ in Data("<p/>".utf8) }
        )
        return url
    }

    /// A one-page PDF with no embedded metadata, rendered via a CoreGraphics PDF context.
    static func makePDF(named name: String = "plain.pdf") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: name)
        try? FileManager.default.removeItem(at: url)
        var mediaBox = CGRect(x: 0, y: 0, width: 300, height: 400)
        let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil)!
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(mediaBox)
        context.endPDFPage()
        context.closePDF()
        return url
    }

    static func png1x1() -> Data {
        // 1x1 transparent PNG bytes.
        let base64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
        return Data(base64Encoded: base64)!
    }

    static func jpeg1x1() throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.1, green: 0.4, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        let image = context.makeImage()!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}
```

Create `BookManagerCoreTests/Import/MetadataExtractorTests.swift`:

```swift
import Foundation
import Testing
@testable import BookManagerCore

@Suite
struct MetadataExtractorTests {
    @Test
    func kindIsDetectedFromExtension() {
        #expect(MetadataExtractor.kind(for: URL(fileURLWithPath: "/tmp/x.epub")) == .epub)
        #expect(MetadataExtractor.kind(for: URL(fileURLWithPath: "/tmp/x.pdf")) == .pdf)
        #expect(MetadataExtractor.kind(for: URL(fileURLWithPath: "/tmp/x.djvu")) == .djvu)
        #expect(MetadataExtractor.kind(for: URL(fileURLWithPath: "/tmp/x.txt")) == nil)
    }

    @Test
    func epubExtractsMetadataAndCover() throws {
        let url = try Fixtures.makeEPUB()
        let metadata = try MetadataExtractor.extract(from: url, kind: .epub)

        #expect(metadata.title == "Range: Why Generalists Triumph in a Specialized World")
        #expect(metadata.authors == ["David Epstein"])
        #expect(metadata.series == "Studies")
        #expect(metadata.seriesIndex == 1.5)
        #expect(metadata.tags.contains("Science"))
        #expect(metadata.languages == ["eng"])
        #expect(metadata.identifiers["isbn"] == "978-0-7352-2129-1")
        #expect(metadata.comments == "Why generalists beat specialists.")
        #expect(metadata.publicationDate != nil)

        let cover = try MetadataExtractor.extractCover(from: url, kind: .epub)
        #expect(cover != nil)
    }

    @Test
    func pdfFallsBackToFilenameWhenNoMetadata() throws {
        let url = try Fixtures.makePDF()
        let metadata = try MetadataExtractor.extract(from: url, kind: .pdf)

        #expect(metadata.title == "plain")
        #expect(metadata.authors.isEmpty)

        let cover = try MetadataExtractor.extractCover(from: url, kind: .pdf)
        #expect(cover != nil)
    }

    @Test
    func djvuUsesFilenameMetadata() {
        let url = URL(fileURLWithPath: "/tmp/My Book.djvu")
        let metadata = try? MetadataExtractor.extract(from: url, kind: .djvu)
        #expect(metadata?.title == "My Book")
    }
}
```

- [ ] **Step 3: Run the extractor tests to verify they fail**

```bash
xcodegen generate --spec project.yml
xcodebuild -project BookManager.xcodeproj -scheme BookManager -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:BookManagerCoreTests/MetadataExtractorTests test
```

Expected: compilation fails (`MetadataExtractor` undefined; ZIPFoundation may need to resolve over the network on first run).

- [ ] **Step 4: Implement the metadata extractor**

Create `BookManagerCore/Import/MetadataExtractor.swift`:

```swift
import Foundation
import PDFKit
import UniformTypeIdentifiers
import ZIPFoundation

public enum FormatKind: String, Sendable {
    case epub = "EPUB"
    case pdf = "PDF"
    case djvu = "DJVU"
}

public struct ExtractedMetadata: Equatable, Sendable {
    public var title: String
    public var authors: [String]
    public var series: String?
    public var seriesIndex: Double?
    public var tags: [String]
    public var publisher: String?
    public var publicationDate: Date?
    public var languages: [String]
    public var identifiers: [String: String]
    public var comments: String?

    public init(
        title: String,
        authors: [String] = [],
        series: String? = nil,
        seriesIndex: Double? = nil,
        tags: [String] = [],
        publisher: String? = nil,
        publicationDate: Date? = nil,
        languages: [String] = [],
        identifiers: [String: String] = [:],
        comments: String? = nil
    ) {
        self.title = title
        self.authors = authors
        self.series = series
        self.seriesIndex = seriesIndex
        self.tags = tags
        self.publisher = publisher
        self.publicationDate = publicationDate
        self.languages = languages
        self.identifiers = identifiers
        self.comments = comments
    }
}

public enum MetadataExtractor {
    public static func kind(for url: URL) -> FormatKind? {
        switch url.pathExtension.lowercased() {
        case "epub": return .epub
        case "pdf": return .pdf
        case "djvu", "djv": return .djvu
        default: return nil
        }
    }

    public static func extract(from url: URL, kind: FormatKind) throws -> ExtractedMetadata {
        switch kind {
        case .epub:
            return try extractEPUB(from: url)
        case .pdf:
            return extractPDF(from: url)
        case .djvu:
            return extractFromFilename(url)
        }
    }

    public static func extractCover(from url: URL, kind: FormatKind) throws -> Data? {
        switch kind {
        case .epub:
            return try extractEPUBCover(from: url)
        case .pdf:
            return try renderPDFFirstPage(from: url)
        case .djvu:
            return nil
        }
    }

    // MARK: - EPUB

    private static func extractEPUB(from url: URL) throws -> ExtractedMetadata {
        guard let archive = Archive(url: url, accessMode: .read) else {
            throw ImportError.cannotOpenArchive(url)
        }
        guard let opfPath = try opfPath(in: archive) else {
            return extractFromFilename(url)
        }
        guard let opfData = try entryData(in: archive, path: opfPath) else {
            return extractFromFilename(url)
        }
        let parser = OPFParser()
        parser.parse(data: opfData)
        return parser.metadata ?? extractFromFilename(url)
    }

    private static func extractEPUBCover(from url: URL) throws -> Data? {
        guard let archive = Archive(url: url, accessMode: .read) else { return nil }
        guard let opfPath = try opfPath(in: archive),
              let opfData = try entryData(in: archive, path: opfPath) else {
            return nil
        }
        let parser = OPFParser()
        parser.parse(data: opfData)
        guard let coverPath = parser.coverPath else { return nil }
        let directory = (opfPath as NSString).deletingLastPathComponent
        let resolved = directory.isEmpty ? coverPath : "\(directory)/\(coverPath)"
        guard let data = try entryData(in: archive, path: resolved) else { return nil }
        return normalizeToJPEG(data)
    }

    // MARK: - PDF

    private static func extractPDF(from url: URL) -> ExtractedMetadata {
        guard let document = PDFDocument(url: url) else {
            return extractFromFilename(url)
        }
        let attributes = document.documentAttributes ?? [:]
        let title = (attributes[PDFDocumentAttribute.titleAttribute] as? String)
            .flatMap { $0.isEmpty ? nil : $0 } ?? url.deletingPathExtension().lastPathComponent
        let author = (attributes[PDFDocumentAttribute.authorAttribute] as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
        let keywords = (attributes[PDFDocumentAttribute.keywordsAttribute] as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
        let subject = (attributes[PDFDocumentAttribute.subjectAttribute] as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
        return ExtractedMetadata(
            title: title,
            authors: author.map { [$0] } ?? [],
            tags: keywords.map { [$0] } ?? [],
            publicationDate: nil,
            comments: subject
        )
    }

    private static func renderPDFFirstPage(from url: URL) throws -> Data? {
        guard let document = PDFDocument(url: url),
              let page = document.page(at: 0) else {
            return nil
        }
        let bounds = page.bounds(for: .mediaBox)
        let scale = min(1, 600 / max(bounds.width, bounds.height))
        let width = Int(bounds.width * scale)
        let height = Int(bounds.height * scale)
        guard width > 0, height > 0,
              let context = CGContext(
                  data: nil, width: width, height: height,
                  bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        context.restoreGState()
        guard let image = context.makeImage() else { return nil }
        return normalizeToJPEG(CGImageToData(image))
    }

    // MARK: - DJVU and fallback

    private static func extractFromFilename(_ url: URL) -> ExtractedMetadata {
        ExtractedMetadata(title: url.deletingPathExtension().lastPathComponent)
    }

    // MARK: - helpers

    private static func opfPath(in archive: Archive) throws -> String? {
        guard let containerData = try entryData(in: archive, path: "META-INF/container.xml"),
              let containerString = String(data: containerData, encoding: .utf8) else {
            return nil
        }
        guard let range = containerString.range(of: "full-path=\"") else { return nil }
        let remainder = containerString[range.upperBound...]
        guard let end = remainder.firstIndex(of: "\"") else { return nil }
        return String(remainder[..<end])
    }

    private static func entryData(in archive: Archive, path: String) throws -> Data? {
        guard let entry = archive[path] else { return nil }
        var data = Data()
        _ = try archive.extract(entry) { chunk in
            data.append(chunk)
        }
        return data
    }

    private static func normalizeToJPEG(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        return CGImageToData(image)
    }

    private static func CGImageToData(_ image: CGImage) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}

public enum ImportError: Error, Equatable {
    case cannotOpenArchive(URL)
}

/// Minimal OPF 2.0 metadata parser built on XMLParser.
private final class OPFParser: NSObject, XMLParserDelegate {
    private enum Element: String {
        case title, creator, language, subject, description, identifier, date, meta
    }

    private var currentElement: String?
    private var textBuffer = ""
    private var inMetadata = false
    private var metadataFound = false
    private var opfScheme: String?

    var metadata: ExtractedMetadata?
    var coverPath: String?
    private var manifestItems: [(id: String, href: String, properties: String)] = []

    func parse(data: Data) {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        guard metadataFound else { return }

        let identifiers = resolvedIdentifiers()
        let coverID = resolvedCoverID()
        coverPath = manifestItems.first { $0.id == coverID }?.href

        metadata = ExtractedMetadata(
            title: values[.title].first ?? "",
            authors: values[.creator],
            series: metas["calibre:series"],
            seriesIndex: metas["calibre:series_index"].flatMap(Double.init),
            tags: values[.subject],
            publicationDate: values[.date].first.flatMap { Self.parseDate($0) },
            languages: values[.language],
            identifiers: identifiers,
            comments: values[.description].first
        )
    }

    private var values: [Element: [String]] = [:]
    private var metas: [String: String] = [:]
    private var identifierItems: [(scheme: String?, value: String)] = []

    override func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName
        textBuffer = ""
        if elementName == "metadata" { inMetadata = true }
        if elementName == "meta" {
            if let name = attributeDict["name"], let content = attributeDict["content"] {
                metas[name] = content
            }
        }
        if elementName == "identifier" {
            opfScheme = attributeDict["opf:scheme"] ?? attributeDict["scheme"]
        }
        if elementName == "item" {
            manifestItems.append((
                id: attributeDict["id"] ?? "",
                href: attributeDict["href"] ?? "",
                properties: attributeDict["properties"] ?? ""
            ))
        }
    }

    override func parser(
        _ parser: XMLParser,
        foundCharacters string: String
    ) {
        textBuffer += string
    }

    override func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard inMetadata else { return }
        if elementName == "metadata" {
            inMetadata = false
            metadataFound = true
            return
        }
        let value = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        if let element = Element(rawValue: elementName) {
            if element == .identifier {
                identifierItems.append((scheme: opfScheme, value: value))
            } else {
                values[element, default: []].append(value)
            }
        }
    }

    private func resolvedIdentifiers() -> [String: String] {
        var result: [String: String] = [:]
        for item in identifierItems {
            let scheme = (item.scheme ?? "id").lowercased()
            if result[scheme] == nil {
                result[scheme] = item.value
            }
        }
        return result
    }

    private func resolvedCoverID() -> String {
        if let cover = metas["cover"] { return cover }
        if let item = manifestItems.first(where: { $0.properties.contains("cover-image") }) {
            return item.id
        }
        if let item = manifestItems.first(where: { $0.id.lowercased() == "cover" }) {
            return item.id
        }
        return ""
    }

    private static func parseDate(_ string: String) -> Date? {
        let formatters: [ISO8601DateFormatter] = [.init(), .init()]
        formatters[1].formatOptions = [.withFullDate]
        return formatters.compactMap { $0.date(from: string) }.first
    }
}
```

- [ ] **Step 5: Run the extractor tests**

Run the command from Step 3. Expected: all four tests pass.

- [ ] **Step 6: Write the import pipeline tests**

Create `BookManagerCoreTests/Import/ImportServiceTests.swift`:

```swift
import Foundation
import Testing
@testable import BookManagerCore

@Suite
struct ImportServiceTests {
    private func layout() throws -> LibraryLayout {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let layout = LibraryLayout(root: root)
        try layout.create(manifest: LibraryManifest(id: UUID()))
        return layout
    }

    @Test
    func importsFilesAndReportsDuplicates() async throws {
        let layout = try layout()
        let service = ImportService(layout: layout)
        let repository = MemoryRepository()
        let epub = try Fixtures.makeEPUB(named: "import-1.epub")
        let pdf = try Fixtures.makePDF(named: "import-1.pdf")

        let report = try await service.importFiles([epub, pdf], into: repository)

        #expect(report.imported.count == 2)
        #expect(report.failed.isEmpty)
        #expect(report.duplicates.isEmpty)
        #expect(report.items.count == 2)
    }

    @Test
    func exactDuplicatesAreSkippedNotSilentlyCopied() async throws {
        let layout = try layout()
        let service = ImportService(layout: layout)
        let repository = MemoryRepository()
        let epub = try Fixtures.makeEPUB(named: "import-2.epub")
        let pdf = try Fixtures.makePDF(named: "import-2.pdf")

        _ = try await service.importFiles([epub, pdf], into: repository)
        let second = try await service.importFiles([epub], into: repository)

        #expect(second.duplicates.count == 1)
        #expect(second.imported.isEmpty)
    }
}

/// Thin protocol + eraser so the importer does not depend on the concrete repository actor.
protocol LibraryRepositoryImporting: Sendable {
    func bookIDs(byFormatHash contentHash: String) async throws -> [UUID]
    func createBook(
        metadata: NewBookMetadata,
        staged: [BookFolder.StagedFile],
        cover: Data?
    ) async throws -> IndexedBook
    func allBooksForDuplicateCheck() async throws -> [IndexedBook]
}

actor MemoryRepository: LibraryRepositoryImporting {
    private var hashes: [String: UUID] = [:]

    func bookIDs(byFormatHash contentHash: String) async throws -> [UUID] {
        hashes[contentHash].map { [$0] } ?? []
    }

    func allBooksForDuplicateCheck() async throws -> [IndexedBook] { [] }

    func createBook(
        metadata: NewBookMetadata,
        staged: [BookFolder.StagedFile],
        cover: Data?
    ) async throws -> IndexedBook {
        let id = UUID()
        for file in staged {
            hashes[file.contentHash] = id
        }
        return IndexedBook(
            id: id, title: metadata.title, authors: metadata.authors,
            modifiedMilliseconds: 1, isDeleted: false, snapshot: Data()
        )
    }
}
```

- [ ] **Step 7: Run the import pipeline tests to verify they fail**

```bash
xcodegen generate --spec project.yml
xcodebuild -project BookManager.xcodeproj -scheme BookManager -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:BookManagerCoreTests/ImportServiceTests test
```

Expected: compilation fails (`ImportService` undefined).

- [ ] **Step 8: Implement the import service**

Create `BookManagerCore/Import/ImportService.swift`:

```swift
import Foundation

public protocol LibraryRepositoryImporting: Sendable {
    func bookIDs(byFormatHash contentHash: String) async throws -> [UUID]
    func allBooksForDuplicateCheck() async throws -> [IndexedBook]
    func createBook(
        metadata: NewBookMetadata,
        staged: [BookFolder.StagedFile],
        cover: Data?
    ) async throws -> IndexedBook
}

public struct ImportItem: Sendable {
    public enum Status: Sendable {
        case imported(UUID)
        case duplicate(matchingBookID: UUID)
        case failed(String)
    }

    public let sourceURL: URL
    public let kind: FormatKind
    public let status: Status
    public let likelyDuplicateOf: UUID?

    public init(sourceURL: URL, kind: FormatKind, status: Status, likelyDuplicateOf: UUID? = nil) {
        self.sourceURL = sourceURL
        self.kind = kind
        self.status = status
        self.likelyDuplicateOf = likelyDuplicateOf
    }
}

public struct ImportReport: Sendable {
    public let items: [ImportItem]

    public init(items: [ImportItem]) {
        self.items = items
    }

    public var imported: [ImportItem] {
        items.filter { if case .imported = $0.status { return true }; return false }
    }

    public var duplicates: [ImportItem] {
        items.filter { if case .duplicate = $0.status { return true }; return false }
    }

    public var failed: [ImportItem] {
        items.filter { if case .failed = $0.status { return true }; return false }
    }

    public var summary: String {
        "\(imported.count) imported, \(duplicates.count) duplicates, \(failed.count) failed"
    }
}

public actor ImportService {
    private let folder: BookFolder

    public init(layout: LibraryLayout) {
        folder = BookFolder(layout: layout)
    }

    public func importFiles(
        _ sourceURLs: [URL],
        into repository: LibraryRepositoryImporting
    ) async throws -> ImportReport {
        var items: [ImportItem] = []
        for source in sourceURLs {
            guard let kind = MetadataExtractor.kind(for: source) else {
                items.append(ImportItem(
                    sourceURL: source,
                    kind: .epub,
                    status: .failed("Unsupported file type")
                ))
                continue
            }
            do {
                let metadata = try MetadataExtractor.extract(from: source, kind: kind)
                let cover = try MetadataExtractor.extractCover(from: source, kind: kind)
                let staged = try await folder.stage(from: source)

                let exactMatches = try await repository.bookIDs(byFormatHash: staged.contentHash)
                if let first = exactMatches.first {
                    items.append(ImportItem(
                        sourceURL: source, kind: kind,
                        status: .duplicate(matchingBookID: first)
                    ))
                    continue
                }

                var likelyDuplicate: UUID?
                if metadata.title.isEmpty == false {
                    let candidates = try await repository.allBooksForDuplicateCheck()
                    let normalized = Self.normalized(metadata.title)
                    let firstAuthor = metadata.authors.first.map(Self.normalized) ?? ""
                    likelyDuplicate = candidates.first {
                        Self.normalized($0.title) == normalized
                            && ($0.authors.first.map(Self.normalized) ?? "") == firstAuthor
                    }?.id
                }

                let book = try await repository.createBook(
                    metadata: metadata,
                    staged: [staged],
                    cover: cover
                )
                items.append(ImportItem(
                    sourceURL: source, kind: kind,
                    status: .imported(book.id),
                    likelyDuplicateOf: likelyDuplicate
                ))
            } catch {
                items.append(ImportItem(
                    sourceURL: source, kind: kind,
                    status: .failed(error.localizedDescription)
                ))
            }
        }
        return ImportReport(items: items)
    }

    static func normalized(_ value: String) -> String {
        value.lowercased()
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }
}
```

- [ ] **Step 9: Run the import pipeline tests**

Run the command from Step 7. Expected: both tests pass.

- [ ] **Step 10: Run the full core suite**

```bash
xcodebuild -project BookManager.xcodeproj -scheme BookManager -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:BookManagerCoreTests test
```

- [ ] **Step 11: Commit**

```bash
git add project.yml BookManager.xcodeproj BookManagerCore/Import BookManagerCoreTests/Import
git commit -m "feat: import EPUB, PDF, and DJVU files with metadata extraction"
```

Note: the `ImportService` tests exercise the pipeline through `LibraryRepositoryImporting`; the real `LibraryRepository` conforms to this protocol in Task 5.

### Task 5: Repository Management APIs

**Files:**

- Modify: `BookManagerCore/Library/LibraryRepository.swift`
- Modify: `BookManagerCoreTests/Library/LibraryRepositoryTests.swift`

**Interfaces:**

- Consumes: `BookFolder`, `OpfGenerator`, `CanonicalPathBuilder.formatFileName` (Task 2), v2 `LocalCatalog` (Task 3), `NewBookMetadata`/`BookEdit` (Task 1), `LibraryRepositoryImporting` (Task 4).
- Produces: `LibraryRepository` conforms to `LibraryRepositoryImporting`; new methods:
  - `createBook(metadata: NewBookMetadata, staged: [BookFolder.StagedFile], cover: Data?) async throws -> IndexedBook`
  - `updateBook(id: UUID, edit: BookEdit) async throws -> IndexedBook`
  - `deleteBook(id: UUID) async throws`
  - `restoreBook(id: UUID) async throws -> IndexedBook`
  - `book(id:)`, `deletedBooks()`, `books(facetType:value:)`, `facetCounts(_:)`
  - `formatFileURL(id: UUID) async throws -> URL?`, `bookFolderURL(id: UUID) async throws -> URL?`
  - `missingFormatFiles() async throws -> [(book: IndexedBook, filename: String)]`

- [ ] **Step 1: Write the repository v2 tests**

Append to `BookManagerCoreTests/Library/LibraryRepositoryTests.swift`:

```swift
@Suite
struct LibraryRepositoryV2Tests {
    private func makeRepository() async throws -> LibraryRepository {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let indexes = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        return try await LibraryRepository.create(
            at: root,
            indexesDirectory: indexes,
            deviceID: UUID()
        )
    }

    @Test
    func createsBookWithFormatsCoverAndMetadata() async throws {
        let repository = try await makeRepository()
        let source = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).epub")
        try Data("imported-epub".utf8).write(to: source)
        let staged = try await repository.stageFile(from: source)
        let cover = try Fixtures.jpeg1x1()

        let book = try await repository.createBook(
            metadata: NewBookMetadata(
                title: "Range",
                authors: ["David Epstein"],
                series: "Studies",
                seriesIndex: 1.5,
                tags: ["science", "sport"],
                rating: 4,
                publisher: "Riverhead",
                publicationDate: Date(timeIntervalSince1970: 1_000),
                languages: ["eng"],
                identifiers: ["isbn": "978-0-7352-2129-1"],
                comments: "A great book"
            ),
            staged: [staged],
            cover: cover
        )

        #expect(book.title == "Range")
        #expect(book.tags.sorted() == ["science", "sport"])
        #expect(book.series == "Studies")
        #expect(book.formats.first?.kind == "EPUB")
        #expect(book.coverHash != nil)
        #expect(book.relativePath == "David Epstein/Range (\(String(book.id.uuidString.prefix(8)).lowercased()))")
        #expect(try await repository.books().count == 1)
    }

    @Test
    func updateBookEditsMetadataAndRenamesFolder() async throws {
        let repository = try await makeRepository()
        let book = try await repository.createBook(
            metadata: NewBookMetadata(title: "Range", authors: ["David Epstein"]),
            staged: [],
            cover: nil
        )

        let updated = try await repository.updateBook(
            id: book.id,
            edit: BookEdit(title: "Range: Revised", tags: ["science"])
        )

        #expect(updated.title == "Range: Revised")
        #expect(updated.tags == ["science"])
        #expect(updated.relativePath.contains("Range_ Revised"))
        #expect(try await repository.books().first?.title == "Range: Revised")
        #expect(try await repository.facetCounts(.tag).first?.value == "science")
    }

    @Test
    func deleteAndRestoreRoundTripThroughTrash() async throws {
        let repository = try await makeRepository()
        let source = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).pdf")
        try Data("some-pdf".utf8).write(to: source)
        let book = try await repository.createBook(
            metadata: NewBookMetadata(title: "Range", authors: ["David Epstein"]),
            staged: [try await repository.stageFile(from: source)],
            cover: nil
        )

        try await repository.deleteBook(id: book.id)
        #expect(try await repository.books().isEmpty)
        #expect(try await repository.deletedBooks().map(\.id) == [book.id])
        #expect(try await repository.bookFolderURL(id: book.id) == nil)

        let restored = try await repository.restoreBook(id: book.id)
        #expect(restored.title == "Range")
        #expect(try await repository.books().map(\.id) == [book.id])
        #expect(try await repository.bookFolderURL(id: book.id) != nil)
    }

    @Test
    func missingFormatFilesAreReported() async throws {
        let repository = try await makeRepository()
        let source = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).epub")
        try Data("x".utf8).write(to: source)
        let book = try await repository.createBook(
            metadata: NewBookMetadata(title: "Range", authors: ["David Epstein"]),
            staged: [try await repository.stageFile(from: source)],
            cover: nil
        )
        // Remove the format file behind the repository's back.
        let folderURL = try await repository.bookFolderURL(id: book.id)!
        try FileManager.default.removeItem(at: folderURL.appending(path: book.formats[0].filename))

        let missing = try await repository.missingFormatFiles()
        #expect(missing.count == 1)
        #expect(missing[0].filename == book.formats[0].filename)
    }

    @Test
    func rebuildMaterializesFullMetadataAndFacets() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let firstIndexes = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let secondIndexes = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let repository = try await LibraryRepository.create(at: root, indexesDirectory: firstIndexes, deviceID: UUID())
        _ = try await repository.createBook(
            metadata: NewBookMetadata(title: "Range", authors: ["David Epstein"], series: "Studies", tags: ["science"]),
            staged: [],
            cover: nil
        )

        let rebuilt = try await LibraryRepository.open(at: root, indexesDirectory: secondIndexes, deviceID: UUID())

        let books = try await rebuilt.books()
        #expect(books.count == 1)
        #expect(books[0].series == "Studies")
        #expect(books[0].tags == ["science"])
        #expect(try await rebuilt.facetCounts(.series).first?.value == "Studies")
    }
}
```

Note: `makeStaged()` is intentionally unused — remove it; staging is exercised via `repository.stageFile(from:)`, which the repository must expose (it delegates to its `BookFolder`).

- [ ] **Step 2: Run the v2 repository tests to verify they fail**

```bash
xcodegen generate --spec project.yml
xcodebuild -project BookManager.xcodeproj -scheme BookManager -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:BookManagerCoreTests/LibraryRepositoryV2Tests test
```

Expected: compilation fails (`stageFile`, v2 `createBook`, `updateBook`, `deleteBook`, `restoreBook`, `missingFormatFiles` undefined).

- [ ] **Step 3: Implement the repository v2 surface**

Rewrite `BookManagerCore/Library/LibraryRepository.swift` (keep `create`, `open`, `books`, `search`, `rebuildCatalog`, `makeIndexedBook` where still valid; the full replacement follows):

```swift
import Foundation

public actor LibraryRepository: LibraryRepositoryImporting {
    public nonisolated let manifest: LibraryManifest
    public nonisolated let root: URL

    private let layout: LibraryLayout
    private let changeStore: ChangeStore
    private let catalog: LocalCatalog
    private let folder: BookFolder
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
        folder = BookFolder(layout: layout)
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
        return try LibraryRepository(
            manifest: manifest,
            layout: layout,
            catalog: LocalCatalog(
                databaseURL: indexesDirectory.appending(path: "\(manifest.id.uuidString).sqlite")
            ),
            deviceID: deviceID
        )
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

    // MARK: - Staging

    public func stageFile(from sourceURL: URL) async throws -> BookFolder.StagedFile {
        try await folder.stage(from: sourceURL)
    }

    // MARK: - Creating books

    @discardableResult
    public func createBook(
        metadata: NewBookMetadata,
        staged: [BookFolder.StagedFile],
        cover: Data?
    ) async throws -> IndexedBook {
        let bookID = UUID()
        let document = try AutomergeBookDocument.new(bookID: bookID, deviceID: deviceID)

        try await writeChanges(metadata: metadata, document: document, bookID: bookID, staged: staged, cover: cover)

        let resolved = try document.resolvedBook()
        let materialized = try await folder.materialize(
            bookID: bookID,
            resolved: resolved,
            staged: staged,
            cover: cover
        )
        let indexed = try makeIndexedBook(document, relativePath: materialized.path)
        try await catalog.upsert(indexed)
        return indexed
    }

    /// Slice 1 compatibility: create a book with title and authors only.
    @discardableResult
    public func createBook(
        title: String,
        authors: [String],
        at date: Date = .now
    ) async throws -> IndexedBook {
        try await createBook(
            metadata: NewBookMetadata(title: title, authors: authors),
            staged: [],
            cover: nil
        )
    }

    private func writeChanges(
        metadata: NewBookMetadata,
        document: AutomergeBookDocument,
        bookID: UUID,
        staged: [BookFolder.StagedFile],
        cover: Data?
    ) async throws {
        func write(_ change: Data, clock: HybridLogicalClock) async throws {
            _ = try await changeStore.writeBookChange(
                change, bookID: bookID, deviceID: deviceID, clock: clock
            )
        }
        var current = HybridLogicalClock(nodeID: deviceID)

        try await write(document.setTitle(metadata.title, clock: current.tick()), clock: current)
        if !metadata.authors.isEmpty {
            try await write(document.setAuthors(metadata.authors, clock: current.tick()), clock: current)
        }
        if let series = metadata.series, !series.isEmpty {
            try await write(document.setSeries(series, clock: current.tick()), clock: current)
        }
        if let seriesIndex = metadata.seriesIndex {
            try await write(document.setSeriesIndex(seriesIndex, clock: current.tick()), clock: current)
        }
        if !metadata.tags.isEmpty {
            try await write(document.setTags(metadata.tags, clock: current.tick()), clock: current)
        }
        if let rating = metadata.rating {
            try await write(document.setRating(rating, clock: current.tick()), clock: current)
        }
        if let publisher = metadata.publisher, !publisher.isEmpty {
            try await write(document.setPublisher(publisher, clock: current.tick()), clock: current)
        }
        if let publicationDate = metadata.publicationDate {
            try await write(document.setPublicationDate(publicationDate, clock: current.tick()), clock: current)
        }
        try await write(document.setAddedDate(.now, clock: current.tick()), clock: current)
        if !metadata.languages.isEmpty {
            try await write(document.setLanguages(metadata.languages, clock: current.tick()), clock: current)
        }
        if !metadata.identifiers.isEmpty {
            try await write(document.setIdentifiers(metadata.identifiers, clock: current.tick()), clock: current)
        }
        if let comments = metadata.comments, !comments.isEmpty {
            try await write(document.setComments(comments, clock: current.tick()), clock: current)
        }
        for file in staged {
            let filename = CanonicalPathBuilder.formatFileName(
                title: metadata.title, authors: metadata.authors, kind: file.kind
            )
            let format = BookFormatValue(
                kind: file.kind, filename: filename,
                contentHash: file.contentHash, size: file.size
            )
            try await write(document.setFormat(format, clock: current.tick()), clock: current)
        }
        if let cover {
            let hash = BookFolder.contentHash(cover)
            try await write(
                document.setCover(CoverValue(filename: "cover.jpg", contentHash: hash), clock: current.tick()),
                clock: current
            )
        }
    }

    // MARK: - Editing

    public func updateBook(id: UUID, edit: BookEdit) async throws -> IndexedBook {
        guard let indexed = try await catalog.book(id: id) else {
            throw LibraryRepositoryError.bookNotFound(id)
        }
        let document = try AutomergeBookDocument(snapshot: indexed.snapshot, deviceID: deviceID)
        let changes = try document.apply(edit, clock: HybridLogicalClock(nodeID: deviceID), date: .now)
        for change in changes {
            _ = try await changeStore.writeBookChange(
                change, bookID: id, deviceID: deviceID, clock: HybridLogicalClock(nodeID: deviceID)
            )
        }

        let resolved = try document.resolvedBook()
        let newPath = CanonicalPathBuilder.relativeDirectory(
            bookID: id, title: resolved.title, authors: resolved.authors
        )
        if newPath != indexed.relativePath {
            try await folder.rename(
                bookID: id,
                from: indexed.relativePath,
                to: newPath,
                oldFormats: indexed.formats.map {
                    BookFormatValue(kind: $0.kind, filename: $0.filename, contentHash: $0.contentHash, size: $0.size)
                },
                newFormats: resolved.formats
            )
            let directory = folder.bookDirectoryURL(relativePath: newPath)
            try OpfGenerator.opfData(bookID: id, resolved: resolved)
                .write(to: directory.appending(path: "metadata.opf"), options: .atomic)
        }
        let updated = try makeIndexedBook(document, relativePath: newPath)
        try await catalog.upsert(updated)
        return updated
    }

    // MARK: - Delete and restore

    public func deleteBook(id: UUID) async throws {
        guard let indexed = try await catalog.book(id: id) else {
            throw LibraryRepositoryError.bookNotFound(id)
        }
        let document = try AutomergeBookDocument(snapshot: indexed.snapshot, deviceID: deviceID)
        let change = try document.setDeleted(true, clock: HybridLogicalClock(nodeID: deviceID).tick())
        _ = try await changeStore.writeBookChange(
            change, bookID: id, deviceID: deviceID, clock: HybridLogicalClock(nodeID: deviceID)
        )
        try await folder.trash(bookID: id, relativePath: indexed.relativePath)
        let deleted = try makeIndexedBook(document, relativePath: indexed.relativePath)
        try await catalog.upsert(deleted)
    }

    public func restoreBook(id: UUID) async throws -> IndexedBook {
        guard let indexed = try await catalog.book(id: id) else {
            throw LibraryRepositoryError.bookNotFound(id)
        }
        let document = try AutomergeBookDocument(snapshot: indexed.snapshot, deviceID: deviceID)
        let change = try document.setDeleted(false, clock: HybridLogicalClock(nodeID: deviceID).tick())
        _ = try await changeStore.writeBookChange(
            change, bookID: id, deviceID: deviceID, clock: HybridLogicalClock(nodeID: deviceID)
        )
        let resolved = try document.resolvedBook()
        let path = CanonicalPathBuilder.relativeDirectory(
            bookID: id, title: resolved.title, authors: resolved.authors
        )
        _ = try await folder.restore(bookID: id, relativePath: path)
        let restored = try makeIndexedBook(document, relativePath: path)
        try await catalog.upsert(restored)
        return restored
    }

    // MARK: - Queries

    public func books() async throws -> [IndexedBook] {
        try await catalog.allBooks()
    }

    public func search(_ query: String) async throws -> [IndexedBook] {
        try await catalog.search(query)
    }

    public func deletedBooks() async throws -> [IndexedBook] {
        try await catalog.deletedBooks()
    }

    public func book(id: UUID) async throws -> IndexedBook? {
        try await catalog.book(id: id)
    }

    public func books(facetType: FacetType, value: String) async throws -> [IndexedBook] {
        try await catalog.books(facetType: facetType, value: value)
    }

    public func facetCounts(_ type: FacetType) async throws -> [(value: String, count: Int)] {
        try await catalog.facetCounts(type)
    }

    public func bookIDs(byFormatHash contentHash: String) async throws -> [UUID] {
        try await catalog.bookIDs(byFormatHash: contentHash)
    }

    public func allBooksForDuplicateCheck() async throws -> [IndexedBook] {
        try await catalog.allBooks()
    }

    // MARK: - Files

    public func formatFileURL(id: UUID) async throws -> URL? {
        guard let book = try await catalog.book(id: id),
              let format = book.formats.first else {
            return nil
        }
        let url = folder.formatFileURL(relativePath: book.relativePath, filename: format.filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func bookFolderURL(id: UUID) async throws -> URL? {
        guard let book = try await catalog.book(id: id) else { return nil }
        let url = folder.bookDirectoryURL(relativePath: book.relativePath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func missingFormatFiles() async throws -> [(book: IndexedBook, filename: String)] {
        var missing: [(book: IndexedBook, filename: String)] = []
        for book in try await catalog.allBooks() {
            for format in book.formats {
                let url = folder.formatFileURL(relativePath: book.relativePath, filename: format.filename)
                if !FileManager.default.fileExists(atPath: url.path) {
                    missing.append((book, format.filename))
                }
            }
        }
        return missing
    }

    // MARK: - Rebuild

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
            let resolved = try document.resolvedBook()
            let path = CanonicalPathBuilder.relativeDirectory(
                bookID: bookID, title: resolved.title, authors: resolved.authors
            )
            try await catalog.upsert(makeIndexedBook(document, relativePath: path))
        }
    }

    private func makeIndexedBook(
        _ document: AutomergeBookDocument,
        relativePath: String
    ) throws -> IndexedBook {
        let book = try document.resolvedBook()
        let normalizeEmpty: (String?) -> String? = { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        let normalizeZero: (Double?) -> Double? = { value in
            guard let value, value != 0 else { return nil }
            return value
        }
        let normalizeRating: (Int?) -> Int? = { value in
            guard let value, value != 0 else { return nil }
            return value
        }
        return IndexedBook(
            id: book.id,
            title: book.title,
            authors: book.authors,
            series: normalizeEmpty(book.series),
            seriesIndex: normalizeZero(book.seriesIndex),
            tags: book.tags,
            rating: normalizeRating(book.rating),
            publisher: normalizeEmpty(book.publisher),
            publicationMilliseconds: book.publicationDate.map { Int64($0.timeIntervalSince1970 * 1_000) },
            addedMilliseconds: book.addedDate.map { Int64($0.timeIntervalSince1970 * 1_000) },
            languages: book.languages,
            identifiers: book.identifiers,
            comments: normalizeEmpty(book.comments),
            formats: book.formats.map {
                BookFormatRecord(
                    kind: $0.kind, filename: $0.filename,
                    contentHash: $0.contentHash, size: $0.size
                )
            },
            coverHash: book.cover?.contentHash,
            relativePath: relativePath,
            modifiedMilliseconds: book.modifiedClock.physicalMilliseconds,
            isDeleted: book.isDeleted,
            snapshot: document.snapshot()
        )
    }
}

public enum LibraryRepositoryError: Error, Equatable {
    case unsupportedFormat(Int)
    case missingDependencies(UUID)
    case bookNotFound(UUID)
}
```

- [ ] **Step 4: Run the v2 repository tests**

Run the command from Step 2. Expected: all five tests pass.

- [ ] **Step 5: Run the full core suite**

```bash
xcodebuild -project BookManager.xcodeproj -scheme BookManager -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:BookManagerCoreTests test
```

Expected: slice-1 repository tests (`createsBookChangeAndRebuildsFreshCatalog`, `rejectsUnsupportedLibraryFormat`) still pass — `createBook(title:authors:at:)` kept, `makeIndexedBook` called with new signature only internally.

- [ ] **Step 6: Commit**

```bash
git add BookManagerCore/Library/LibraryRepository.swift BookManagerCoreTests/Library/LibraryRepositoryTests.swift
git commit -m "feat: add book management repository APIs"
```

### Task 6: Observable Session, Sidebar Facets, and Browser Toolbar

**Files:**

- Modify: `BookManager/Stores/LibrarySession.swift`
- Modify: `BookManager/Views/ContentView.swift`
- Create: `BookManager/Views/SidebarView.swift`
- Modify: `BookManager/Views/BookTableView.swift`

**Interfaces:**

- Consumes: all repository v2 APIs (Task 5), `FacetType` (Task 1).
- Produces: session state + actions used by Tasks 7–9 (`importFiles`, `saveEdit`, `delete`, `restore`, `open`, `reveal`, `rebuildIndex`, `reloadDiagnostics`, `selectFacet`, `setViewMode`).

- [ ] **Step 1: Rewrite LibrarySession**

Replace `BookManager/Stores/LibrarySession.swift`:

```swift
import AppKit
import BookManagerCore
import Foundation
import Observation

@MainActor
@Observable
final class LibrarySession {
    enum ViewMode: String, CaseIterable, Identifiable {
        case table, grid
        var id: String { rawValue }
    }

    enum State {
        case welcome
        case loading
        case loaded
        case failed(message: String)
    }

    private(set) var state: State = .welcome
    private(set) var repository: LibraryRepository?
    var searchText = "" { didSet { Task { await refreshBooks() } } }
    var viewMode: ViewMode = .table
    var selection = Set<UUID>()
    var selectedFacet: FacetSelection?

    private(set) var books: [IndexedBook] = []
    private(set) var authors: [(value: String, count: Int)] = []
    private(set) var series: [(value: String, count: Int)] = []
    private(set) var tags: [(value: String, count: Int)] = []
    private(set) var formats: [(value: String, count: Int)] = []
    private(set) var deletedBooks: [IndexedBook] = []
    private(set) var missingFiles: [(book: IndexedBook, filename: String)] = []
    var importReport: ImportReport?
    var inspectorBook: IndexedBook?
    var diagnosticsPresented = false

    private let deviceID: UUID
    private let bookmarks: LibraryBookmarkStore
    private var activeSecurityURL: URL?

    struct FacetSelection: Hashable {
        let type: FacetType
        let value: String
    }

    init(
        deviceID: UUID = UUID(),
        bookmarks: LibraryBookmarkStore = LibraryBookmarkStore()
    ) {
        self.deviceID = deviceID
        self.bookmarks = bookmarks
    }

    func createLibrary(at url: URL) async { await activate(url: url, create: true) }
    func openLibrary(at url: URL) async { await activate(url: url, create: false) }

    func closeLibrary() {
        activeSecurityURL?.stopAccessingSecurityScopedResource()
        activeSecurityURL = nil
        repository = nil
        state = .welcome
        books = []
        deletedBooks = []
        selection = []
        selectedFacet = nil
        importReport = nil
        inspectorBook = nil
    }

    // MARK: - Activation

    private func activate(url: URL, create: Bool) async {
        state = .loading
        let accessed = url.startAccessingSecurityScopedResource()
        do {
            let indexes = try Self.indexDirectory()
            let repository: LibraryRepository
            if create {
                repository = try await .create(at: url, indexesDirectory: indexes, deviceID: deviceID)
            } else {
                repository = try await .open(at: url, indexesDirectory: indexes, deviceID: deviceID)
            }
            try bookmarks.save(url, for: repository.manifest.id)
            activeSecurityURL?.stopAccessingSecurityScopedResource()
            activeSecurityURL = accessed ? url : nil
            self.repository = repository
            state = .loaded
            await refreshAll()
        } catch {
            if accessed { url.stopAccessingSecurityScopedResource() }
            state = .failed(message: error.localizedDescription)
        }
    }

    // MARK: - Loading

    func refreshAll() async {
        await refreshBooks()
        await refreshFacets()
        await refreshDeleted()
    }

    func refreshBooks() async {
        guard let repository else { return }
        do {
            if let facet = selectedFacet {
                books = try await repository.books(facetType: facet.type, value: facet.value)
            } else if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                books = try await repository.books()
            } else {
                books = try await repository.search(searchText)
            }
        } catch {
            state = .failed(message: error.localizedDescription)
        }
    }

    func refreshFacets() async {
        guard let repository else { return }
        authors = (try? await repository.facetCounts(.author)) ?? []
        series = (try? await repository.facetCounts(.series)) ?? []
        tags = (try? await repository.facetCounts(.tag)) ?? []
        formats = (try? await repository.facetCounts(.format)) ?? []
    }

    func refreshDeleted() async {
        deletedBooks = (try? await repository?.deletedBooks()) ?? []
    }

    // MARK: - Facets and search

    func selectFacet(_ facet: FacetSelection?) {
        selectedFacet = (facet == selectedFacet) ? nil : facet
        Task { await refreshBooks() }
    }

    // MARK: - Import

    func importFiles(urls: [URL]) async {
        guard let repository else { return }
        let service = ImportService(layout: .init(root: repository.root))
        do {
            importReport = try await service.importFiles(urls, into: repository)
        } catch {
            importReport = ImportReport(items: [
                ImportItem(sourceURL: urls.first ?? URL(fileURLWithPath: "/"), kind: .epub, status: .failed(error.localizedDescription))
            ])
        }
        await refreshAll()
    }

    // MARK: - Editing

    func saveEdit(_ edit: BookEdit, for id: UUID) async {
        guard let repository else { return }
        do {
            let updated = try await repository.updateBook(id: id, edit: edit)
            inspectorBook = updated
            await refreshAll()
        } catch {
            state = .failed(message: error.localizedDescription)
        }
    }

    // MARK: - Delete / restore

    func delete(ids: Set<UUID>) async {
        guard let repository else { return }
        for id in ids {
            try? await repository.deleteBook(id: id)
        }
        selection.removeAll()
        await refreshAll()
    }

    func restore(id: UUID) async {
        guard let repository else { return }
        try? await repository.restoreBook(id: id)
        await refreshAll()
    }

    // MARK: - Open / reveal

    func open(id: UUID) async {
        guard let repository, let url = try? await repository.formatFileURL(id: id) else { return }
        NSWorkspace.shared.open(url)
    }

    func reveal(id: UUID) async {
        guard let repository, let url = try? await repository.bookFolderURL(id: id) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Diagnostics

    func rebuildIndex() async {
        guard let repository else { return }
        try? await repository.rebuildCatalog()
        await refreshAll()
    }

    func reloadDiagnostics() async {
        guard let repository else { return }
        missingFiles = (try? await repository.missingFormatFiles()) ?? []
        await refreshDeleted()
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

- [ ] **Step 2: Write the sidebar view**

Create `BookManager/Views/SidebarView.swift`:

```swift
import BookManagerCore
import SwiftUI

struct SidebarView: View {
    @Bindable var session: LibrarySession

    var body: some View {
        List(selection: $session.selectedFacet) {
            Section {
                Label("All Books", systemImage: "books.vertical")
                    .tag(nil as LibrarySession.FacetSelection?)
            }
            Section("Authors") {
                ForEach(session.authors, id: \.value) { item in
                    FacetRow(title: item.value, count: item.count, type: .author)
                }
            }
            Section("Series") {
                ForEach(session.series, id: \.value) { item in
                    FacetRow(title: item.value, count: item.count, type: .series)
                }
            }
            Section("Tags") {
                ForEach(session.tags, id: \.value) { item in
                    FacetRow(title: item.value, count: item.count, type: .tag)
                }
            }
            Section("Formats") {
                ForEach(session.formats, id: \.value) { item in
                    FacetRow(title: item.value, count: item.count, type: .format)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private struct FacetRow: View {
        let title: String
        let count: Int
        let type: FacetType

        @Environment(\.librarySession) private var session

        var body: some View {
            HStack {
                Text(title)
                Spacer()
                Text("\(count)")
                    .foregroundStyle(.secondary)
            }
            .tag(LibrarySession.FacetSelection(type: type, value: title))
        }
    }
}

private struct LibrarySessionKey: EnvironmentKey {
    static let defaultValue: LibrarySession? = nil
}

extension EnvironmentValues {
    var librarySession: LibrarySession? {
        get { self[LibrarySessionKey.self] }
        set { self[LibrarySessionKey.self] = newValue }
    }
}
```

- [ ] **Step 3: Rewrite ContentView with toolbar, drop target, and sheets**

Replace `BookManager/Views/ContentView.swift`:

```swift
import AppKit
import BookManagerCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var session: LibrarySession
    @State private var pickerPurpose: PickerPurpose?
    @State private var importURLs: [URL] = []
    @State private var showImportReport = false
    @State private var showDiagnostics = false

    private enum PickerPurpose: Identifiable {
        case create, open, addBooks
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
                ProgressView("Opening Library…").controlSize(.large)
            case .loaded:
                loadedBody
            case let .failed(message):
                ContentUnavailableView {
                    Label("Couldn’t Open Library", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Choose Another Library") { session.closeLibrary() }
                }
            }
        }
        .frame(minWidth: 900, minHeight: 560)
        .fileImporter(
            isPresented: Binding(
                get: { pickerPurpose != nil },
                set: { if !$0 { pickerPurpose = nil } }
            ),
            allowedContentTypes: pickerPurpose == .addBooks
                ? [.epub, .pdf, .data]
                : [.folder],
            allowsMultipleSelection: true
        ) { result in
            let purpose = pickerPurpose
            pickerPurpose = nil
            guard case let .success(urls) = result else { return }
            switch purpose {
            case .create:
                Task { await session.createLibrary(at: urls[0]) }
            case .open:
                Task { await session.openLibrary(at: urls[0]) }
            case .addBooks:
                Task {
                    await session.importFiles(urls: urls)
                    showImportReport = session.importReport != nil
                }
            case nil:
                break
            }
        }
        .sheet(isPresented: $showImportReport) {
            if let report = session.importReport {
                ImportReportView(report: report) { showImportReport = false }
            }
        }
        .sheet(item: $session.inspectorBook) { book in
            MetadataEditorView(book: book, onSave: { edit in
                Task { await session.saveEdit(edit, for: book.id) }
                session.inspectorBook = nil
            }, onCancel: {
                session.inspectorBook = nil
            })
        }
        .sheet(isPresented: $showDiagnostics) {
            DiagnosticsView()
        }
        .onChange(of: showDiagnostics) { _, presented in
            if presented { Task { await session.reloadDiagnostics() } }
        }
        .environment(\.librarySession, session)
    }

    private var loadedBody: some View {
        NavigationSplitView {
            SidebarView(session: session)
                .navigationTitle(session.repository?.root.lastPathComponent ?? "Library")
        } detail: {
            browser
                .navigationTitle(session.selectedFacet?.value ?? "All Books")
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    pickerPurpose = .addBooks
                } label: {
                    Label("Add Books", systemImage: "plus")
                }
                Button {
                    openSelection()
                } label: {
                    Label("Open", systemImage: "book")
                }
                .disabled(session.selection.isEmpty)
                Button {
                    revealSelection()
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                .disabled(session.selection.isEmpty)
                Button {
                    editSelection()
                } label: {
                    Label("Edit Metadata", systemImage: "pencil")
                }
                .disabled(session.selection.count != 1)
                Picker("View", selection: $session.viewMode) {
                    Image(systemName: "list.bullet").tag(LibrarySession.ViewMode.table)
                    Image(systemName: "square.grid.2x2").tag(LibrarySession.ViewMode.grid)
                }
                .pickerStyle(.segmented)
                .help("Table or cover grid")
                Button {
                    showDiagnostics = true
                } label: {
                    Label("Diagnostics", systemImage: "wrench.and.screwdriver")
                }
            }
        }
    }

    private var browser: some View {
        Group {
            switch session.viewMode {
            case .table:
                BookTableView(session: session)
            case .grid:
                CoverGridView(session: session)
            }
        }
        .searchable(text: $session.searchText, prompt: "Search books")
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var urls: [URL] = []
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { urls.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            guard !urls.isEmpty else { return }
            Task {
                await session.importFiles(urls: urls)
                showImportReport = session.importReport != nil
            }
        }
        return true
    }

    private func openSelection() {
        if let id = session.selection.first {
            Task { await session.open(id: id) }
        }
    }

    private func revealSelection() {
        if let id = session.selection.first {
            Task { await session.reveal(id: id) }
        }
    }

    private func editSelection() {
        if let id = session.selection.first,
           let book = session.books.first(where: { $0.id == id }) {
            session.inspectorBook = book
        }
    }
}
```

- [ ] **Step 4: Update BookTableView**

Replace `BookManager/Views/BookTableView.swift`:

```swift
import BookManagerCore
import SwiftUI

struct BookTableView: View {
    @Bindable var session: LibrarySession

    var body: some View {
        Table(session.books, selection: $session.selection) {
            TableColumn("Title", value: \.title)
            TableColumn("Authors") { book in
                Text(book.authors.joined(separator: ", ")).foregroundStyle(.secondary)
            }
            TableColumn("Series") { book in
                Text(book.series ?? "")
            }
            TableColumn("Formats") { book in
                Text(book.formats.map(\.kind).joined(separator: ", "))
            }
            TableColumn("Tags") { book in
                Text(book.tags.joined(separator: ", "))
            }
            TableColumn("Rating") { book in
                if let rating = book.rating {
                    Text(String(repeating: "★", count: rating)).foregroundStyle(.orange)
                }
            }
        }
        .contextMenu(forSelectionType: IndexedBook.ID.self) { ids in
            Button("Open") {
                if let id = ids.first { Task { await session.open(id: id) } }
            }
            Button("Reveal in Finder") {
                if let id = ids.first { Task { await session.reveal(id: id) } }
            }
            Button("Edit Metadata…") {
                if let id = ids.first, let book = session.books.first(where: { $0.id == id }) {
                    session.inspectorBook = book
                }
            }
            Divider()
            Button("Move to Trash", role: .destructive) {
                Task { await session.delete(ids: ids) }
            }
        } primaryAction: { ids in
            if let id = ids.first { Task { await session.open(id: id) } }
        }
        .overlay {
            if session.books.isEmpty {
                ContentUnavailableView(
                    "No Books",
                    systemImage: "books.vertical",
                    description: Text("Drag ebook files here or use Add Books to import.")
                )
            }
        }
    }
}
```

- [ ] **Step 5: Build and smoke-check the app**

```bash
xcodegen generate --spec project.yml
xcodebuild -project BookManager.xcodeproj -scheme BookManager -destination 'platform=macOS' -derivedDataPath .build/DerivedData build
```

Fix any compile errors (expected drift points: `List(selection:)` Hashable conformance, `UTType(filenameExtension:)` optional handling, AppKit import). The app should launch with the new toolbar.

- [ ] **Step 6: Run the full test suite**

```bash
xcodebuild -project BookManager.xcodeproj -scheme BookManager -destination 'platform=macOS' -derivedDataPath .build/DerivedData test
```

Expected: all core tests plus the existing UI test pass.

- [ ] **Step 7: Commit**

```bash
git add BookManager
git commit -m "feat: add facet sidebar and browser toolbar"
```

### Task 7: Cover Grid, Thumbnails, and External Open

**Files:**

- Create: `BookManager/Stores/ThumbnailCache.swift`
- Create: `BookManager/Views/CoverGridView.swift`
- Modify: `BookManager/Stores/LibrarySession.swift` (thumbnail accessor)

**Interfaces:**

- Consumes: `IndexedBook` v2 (`coverHash`, `relativePath`, `formats`), session `repository`, `open(id:)` (Task 6).
- Produces: `CoverGridView` (grid with selection + double-click open), `ThumbnailCache.thumbnail(for:book:) -> NSImage?`.

- [ ] **Step 1: Implement the thumbnail cache**

Create `BookManager/Stores/ThumbnailCache.swift`:

```swift
import AppKit
import BookManagerCore
import Foundation
import QuickLookThumbnailing

@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private var memory: [UUID: NSImage] = [:]

    func thumbnail(for book: IndexedBook, repository: LibraryRepository?) async -> NSImage? {
        if let cached = memory[book.id] { return cached }

        // Prefer the materialized cover file.
        if let repository, !book.relativePath.isEmpty, book.coverHash != nil {
            let coverURL = repository.root
                .appending(path: book.relativePath, directoryHint: .isDirectory)
                .appending(path: "cover.jpg")
            if let image = NSImage(contentsOf: coverURL) {
                memory[book.id] = image
                return image
            }
        }

        // Fall back to a QuickLook thumbnail of the first format file.
        guard let repository, let url = try? await repository.formatFileURL(id: book.id) else {
            return nil
        }
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 240, height: 340),
            scale: 1,
            representationTypes: .thumbnail
        )
        let image = await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                continuation.resume(returning: representation?.nsImage)
            }
        }
        if let image {
            memory[book.id] = image
        }
        return image
    }

    func remove(_ id: UUID) {
        memory.removeValue(forKey: id)
    }
}
```

- [ ] **Step 2: Write the cover grid view**

Create `BookManager/Views/CoverGridView.swift`:

```swift
import AppKit
import BookManagerCore
import SwiftUI

struct CoverGridView: View {
    @Bindable var session: LibrarySession

    private let columns = [
        GridItem(.adaptive(minimum: 120, maximum: 180), spacing: 16)
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(session.books) { book in
                    CoverTile(book: book)
                        .environment(\.librarySession, session)
                }
            }
            .padding(16)
        }
        .overlay {
            if session.books.isEmpty {
                ContentUnavailableView(
                    "No Books",
                    systemImage: "books.vertical",
                    description: Text("Drag ebook files here or use Add Books to import.")
                )
            }
        }
    }
}

private struct CoverTile: View {
    let book: IndexedBook
    @Environment(\.librarySession) private var session
    @State private var image: NSImage?
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            cover
                .frame(height: 160)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.quaternary.opacity(0.4))
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(
                            session.selection.contains(book.id) ? Color.accentColor : .clear,
                            lineWidth: 3
                        )
                )
                .onTapGesture(count: 2) {
                    Task { await session?.open(id: book.id) }
                }
                .onTapGesture {
                    toggleSelection()
                }
                .onHover { hovering in
                    isHovering = hovering
                }
            Text(book.title)
                .font(.caption)
                .lineLimit(2)
                .foregroundStyle(.primary)
            Text(book.authors.joined(separator: ", "))
                .font(.caption2)
                .lineLimit(1)
                .foregroundStyle(.secondary)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isHovering ? Color.accentColor.opacity(0.08) : .clear)
        )
        .task {
            image = await ThumbnailCache.shared.thumbnail(for: book, repository: session?.repository)
        }
    }

    @ViewBuilder
    private var cover: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "book.closed")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
        }
    }

    private func toggleSelection() {
        guard let session else { return }
        if session.selection.contains(book.id) {
            session.selection.remove(book.id)
        } else {
            session.selection.insert(book.id)
        }
    }
}
```

- [ ] **Step 3: Add the session thumbnail accessor**

In `BookManager/Stores/LibrarySession.swift`, add:

```swift
    var libraryRoot: URL? {
        repository?.root
    }
```

- [ ] **Step 4: Build and verify**

```bash
xcodegen generate --spec project.yml
xcodebuild -project BookManager.xcodeproj -scheme BookManager -destination 'platform=macOS' -derivedDataPath .build/DerivedData build
./script/build_and_run.sh --verify
```

Manually verify: switching to grid view shows covers/thumbnails; double-click opens the book in the default app; the sidebar facets filter both views.

- [ ] **Step 5: Commit**

```bash
git add BookManager
git commit -m "feat: add cover grid with thumbnails"
```

### Task 8: Metadata Editor, Import Report, and Trash UI

**Files:**

- Create: `BookManager/Views/MetadataEditorView.swift`
- Create: `BookManager/Views/ImportReportView.swift`
- Create: `BookManager/Views/DiagnosticsView.swift`

**Interfaces:**

- Consumes: `BookEdit`/`FieldEdit` (Task 1), `ImportReport` (Task 4), session `delete/restore/rebuildIndex/reloadDiagnostics` (Task 6), repository `missingFormatFiles` (Task 5).

- [ ] **Step 1: Write the metadata editor sheet**

Create `BookManager/Views/MetadataEditorView.swift`:

```swift
import BookManagerCore
import SwiftUI

struct MetadataEditorView: View {
    let book: IndexedBook
    let onSave: (BookEdit) -> Void
    let onCancel: () -> Void

    @State private var title = ""
    @State private var authorsText = ""
    @State private var series = ""
    @State private var seriesIndex = ""
    @State private var tagsText = ""
    @State private var rating = 0
    @State private var publisher = ""
    @State private var publicationDate: Date?
    @State private var hasPublicationDate = false
    @State private var languagesText = ""
    @State private var identifiersText = ""
    @State private var comments = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Edit Metadata")
                .font(.headline)
                .padding()
            Form {
                TextField("Title", text: $title)
                TextField("Authors (comma separated)", text: $authorsText)
                TextField("Series", text: $series)
                TextField("Series index", text: $seriesIndex)
                TextField("Tags (comma separated)", text: $tagsText)
                Stepper(value: $rating, in: 0...5) {
                    Text("Rating: \(rating == 0 ? "None" : String(repeating: "★", count: rating))")
                }
                TextField("Publisher", text: $publisher)
                Toggle("Publication date", isOn: $hasPublicationDate)
                if hasPublicationDate {
                    DatePicker("Date", selection: Binding(
                        get: { publicationDate ?? .now },
                        set: { publicationDate = $0 }
                    ), displayedComponents: .date)
                }
                TextField("Languages (comma separated)", text: $languagesText)
                TextField("Identifiers (type=value, one per line)", text: $identifiersText, axis: .vertical)
                TextField("Comments", text: $comments, axis: .vertical)
            }
            .formStyle(.grouped)
            .padding()
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                Button("Save") {
                    onSave(collectEdit())
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(minWidth: 420, minHeight: 480)
        .onAppear(perform: populate)
    }

    private func populate() {
        title = book.title
        authorsText = book.authors.joined(separator: ", ")
        series = book.series ?? ""
        seriesIndex = book.seriesIndex.map { String($0) } ?? ""
        tagsText = book.tags.joined(separator: ", ")
        rating = book.rating ?? 0
        publisher = book.publisher ?? ""
        if let date = book.publicationDate {
            hasPublicationDate = true
            publicationDate = date
        }
        languagesText = book.languages.joined(separator: ", ")
        identifiersText = book.identifiers.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "\n")
        comments = book.comments ?? ""
    }

    private func collectEdit() -> BookEdit {
        let splitList = { (value: String) -> [String] in
            value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        var identifiers: [String: String] = [:]
        for line in identifiersText.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if parts.count == 2 { identifiers[parts[0]] = parts[1] }
        }
        let newSeries = series.trimmingCharacters(in: .whitespacesAndNewlines)
        let seriesEdit: FieldEdit<String> = newSeries.isEmpty ? .clear : .set(newSeries)
        let newIndex = seriesIndex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil : Double(seriesIndex)
        let indexEdit: FieldEdit<Double> = newSeries.isEmpty ? .keep : (newIndex.map { .set($0) } ?? .clear)
        let ratingEdit: FieldEdit<Int> = rating == 0 ? .clear : .set(rating)
        let publisherEdit: FieldEdit<String> = {
            let value = publisher.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? .clear : .set(value)
        }()
        let dateEdit: FieldEdit<Date> = hasPublicationDate
            ? (publicationDate.map { .set($0) } ?? .clear)
            : .clear
        let commentsEdit: FieldEdit<String> = {
            let value = comments.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? .clear : .set(value)
        }()
        return BookEdit(
            title: title == book.title ? nil : title,
            authors: splitList(authorsText) == book.authors ? nil : splitList(authorsText),
            series: seriesEdit,
            seriesIndex: indexEdit,
            tags: splitList(tagsText) == book.tags ? nil : splitList(tagsText),
            rating: ratingEdit,
            publisher: publisherEdit,
            publicationDate: dateEdit,
            languages: splitList(languagesText) == book.languages ? nil : splitList(languagesText),
            identifiers: identifiers == book.identifiers ? nil : identifiers,
            comments: commentsEdit
        )
    }
}
```

- [ ] **Step 2: Write the import report sheet**

Create `BookManager/Views/ImportReportView.swift`:

```swift
import BookManagerCore
import SwiftUI

struct ImportReportView: View {
    let report: ImportReport
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Import Complete")
                .font(.headline)
                .padding()
            Text(report.summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding([.horizontal, .bottom])
            List {
                Section("Imported") {
                    ForEach(report.imported, id: \.sourceURL) { item in
                        row(item, icon: "checkmark.circle", color: .green)
                    }
                }
                if !report.duplicates.isEmpty {
                    Section("Duplicates (not copied)") {
                        ForEach(report.duplicates, id: \.sourceURL) { item in
                            row(item, icon: "exclamationmark.circle", color: .orange)
                        }
                    }
                }
                if !report.failed.isEmpty {
                    Section("Failed") {
                        ForEach(report.failed, id: \.sourceURL) { item in
                            row(item, icon: "xmark.circle", color: .red)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Done") { onClose() }
                    .buttonStyle(.borderedProminent)
                    .padding()
            }
        }
        .frame(minWidth: 480, minHeight: 360)
    }

    private func row(_ item: ImportItem, icon: String, color: Color) -> some View {
        HStack {
            Image(systemName: icon).foregroundStyle(color)
            Text(item.sourceURL.lastPathComponent)
            Spacer()
            if case .duplicate = item.status {
                Text("Already in library").font(.caption).foregroundStyle(.secondary)
            } else if case let .failed(message) = item.status {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
```

- [ ] **Step 3: Write the diagnostics sheet**

Create `BookManager/Views/DiagnosticsView.swift`:

```swift
import AppKit
import BookManagerCore
import SwiftUI

struct DiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.librarySession) private var session

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Diagnostics")
                .font(.headline)
                .padding()
            List {
                Section("Library") {
                    LabeledContent("Library", value: session?.repository?.root.lastPathComponent ?? "—")
                    LabeledContent("Books", value: "\(session?.books.count ?? 0)")
                    Button("Rebuild Local Index") {
                        Task { await session?.rebuildIndex() }
                    }
                }
                Section("Missing Format Files") {
                    if let session, session.missingFiles.isEmpty {
                        Text("None").foregroundStyle(.secondary)
                    } else {
                        ForEach(session?.missingFiles ?? [], id: \.book.id) { entry in
                            HStack {
                                Text(entry.book.title)
                                Spacer()
                                Text(entry.filename).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("Trash") {
                    if let session, session.deletedBooks.isEmpty {
                        Text("Empty").foregroundStyle(.secondary)
                    } else {
                        ForEach(session?.deletedBooks ?? [], id: \.id) { book in
                            HStack {
                                Text(book.title)
                                Spacer()
                                Button("Restore") {
                                    Task { await session?.restore(id: book.id) }
                                }
                            }
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .padding()
            }
        }
        .frame(minWidth: 520, minHeight: 420)
        .task { await session?.reloadDiagnostics() }
    }
}
```

- [ ] **Step 4: Build and smoke-check**

```bash
xcodegen generate --spec project.yml
xcodebuild -project BookManager.xcodeproj -scheme BookManager -destination 'platform=macOS' -derivedDataPath .build/DerivedData build
```

Manually verify: Add Books imports the fixture EPUBs; the import report shows imported/duplicate rows; double-click a row opens the inspector; saving renames the folder in Finder; Delete moves the book to trash; Restore brings it back; Diagnostics lists a missing file after deleting it in Finder; Rebuild Local Index restores facets.

- [ ] **Step 5: Run the full test suite**

```bash
xcodebuild -project BookManager.xcodeproj -scheme BookManager -destination 'platform=macOS' -derivedDataPath .build/DerivedData test
```

- [ ] **Step 6: Commit**

```bash
git add BookManager
git commit -m "feat: add metadata editor, import report, and diagnostics"
```

### Task 9: Slice Verification and Documentation

**Files:**

- Modify: `README.md`
- Modify: `docs/superpowers/specs/2026-07-29-book-manager-design.md`

- [ ] **Step 1: Update the README**

Replace `README.md`:

````markdown
# Book Manager

Book Manager is a native macOS ebook-library manager. It creates and opens portable libraries, persists metadata as immutable Automerge changes, rebuilds a local GRDB catalogue, imports EPUB/PDF/DJVU files with embedded metadata, browses with facets and a cover grid, opens books externally, and moves books to/from trash.

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
3. **Calibre migration** — not started
4. **Multi-Mac hardening** — not started
````

- [ ] **Step 2: Update the design document status**

In `docs/superpowers/specs/2026-07-29-book-manager-design.md`, change the Implementation Status block to:

```markdown
### Implementation Status

- Slice 1 — Library foundation: implemented and verified
- Slice 2 — Management workflows: implemented and verified
- Slice 3 — Calibre migration: not started
- Slice 4 — Multi-Mac hardening: not started
```

- [ ] **Step 3: Static checks**

```bash
xcodegen generate --spec project.yml
git diff --check
xcodebuild -project BookManager.xcodeproj -scheme BookManager -destination 'platform=macOS' -derivedDataPath .build/DerivedData analyze
```

Expected: no whitespace errors and `** ANALYZE SUCCEEDED **`.

- [ ] **Step 4: Clean build + full suite**

```bash
xcodebuild -project BookManager.xcodeproj -scheme BookManager clean
xcodebuild -project BookManager.xcodeproj -scheme BookManager -destination 'platform=macOS' -derivedDataPath .build/DerivedData test
```

Expected: `** CLEAN SUCCEEDED **` then `** TEST SUCCEEDED **` with all core suites plus the UI test.

- [ ] **Step 5: Verify the run entrypoint**

```bash
./script/build_and_run.sh --verify
```

Expected: builds, launches, `pgrep -x BookManager` succeeds.

- [ ] **Step 6: Inspect the final change set**

```bash
git status --short
git log --oneline --decorate -12
```

- [ ] **Step 7: Commit documentation**

```bash
git add README.md docs/superpowers/specs/2026-07-29-book-manager-design.md
git commit -m "docs: document management workflows"
```

- [ ] **Step 8: Confirm the repository is clean**

```bash
git status --short --branch
```

Expected: branch header only.

---

## Slice 2 Completion Notes (merged to main 2026-08-01)

Implemented via subagent-driven development in `.worktrees/management-workflows` (branch `feature/management-workflows`, merged as a fast-forward to `main` at `7107523` + a follow-up signing-config commit). 14 commits; 58 core tests (12 suites) + 1 UI test green on the merged tree.

### Human decisions recorded during the slice

1. **Cover/format/identifier removal semantics** — `setCover(nil)` clears the whole `covers` map (matching `removeFormat`'s whole-key deletion) + removal-convergence tests added (Task 1 fix round).
2. **Import staging semantics** — `stage()` keeps `copyItem` (user files are never consumed); Task 2's source-deletion assertion changed to assert the staged copy is consumed; ImportService removes staged files on duplicates and on failure (Task 4).
3. **UI-layer coverage waiver** — automated app-target (BookManager) coverage waived for Tasks 6-8 UI behavior; all behavior lives in BookManagerCore (fully tested); app layer covered by build + UI launch smoke test + manual verification.
4. **Sidebar facet selection** routed through `LibrarySession.selectFacet` via a custom Binding (fixes the plan's inert-selection defect; Task 6).
5. **Final review fixes** — ImportService staging cleanup on failure (defer), `Double(trimmedIndex)` parse + trimmed title compare in MetadataEditorView, search-error isolation in `refreshBooks` (state stays `.loaded`), and `likelyDuplicateOf` surfaced in ImportReportView + tested.

### Deferred items (candidates for Slice 3/4)

- **Slice 4 (multi-device):** whole-key deletion leaves no tombstones — a stale replica re-adding its cover/format/identifier entry can resurrect the field on merge; Swift Dictionary encodes through Automerge Codable as an alternating key/value list, so concurrent multi-key identifier writes don't deterministically resolve newest-per-type (both replicas always converge).
- **Slice 4:** `.amchange` filenames for update/delete/restore use a fresh 0-0 clock (digest-sorted filenames) — benign (Automerge applies in any order; LWW clocks live in change payloads), but align with createBook's ticked clocks for consistency.
- **Hardening:** IndexedBook `init(row:)` fabricates a random UUID for a corrupt row id (plan-mandated) — throw/trap instead; `search()` passes the raw query to FTS5 MATCH (operator chars can throw — session now isolates the error to empty results); `bookIDs(byFormatHash:)` arbitrary order (callers compare as sets).
- **Coverage gaps:** no test for the v1→v2 catalogue migration path; format facet type untested; update/delete changes never exercised through `rebuildCatalog`; rename()'s per-kind format-file branch untested; `BookFolderError.trashEntryMissing` untested; journal failure path untested.
- **Known plan-verbatim warts:** OPF staleness on edits that don't change the canonical path (OPF is derived; change store is the source of truth); `closeLibrary()` doesn't reset searchText/missingFiles/viewMode; `try?`-swallowed failures in delete/restore/rebuildIndex give no user feedback; Open/Reveal act on arbitrary `selection.first` for multi-selection; `state = .loaded` precedes `refreshAll()` (empty-state flashes on open); `createBook(title:authors:at:)` ignores `at:`; unsupported-file ImportItem fabricates `.epub` kind; ThumbnailCache keyed by book.id only (stale after cover rewrite); double-tap also toggles selection (single-tap fires first).
- **UX:** searchText didSet has no debounce/cancellation; MetadataEditorView's cleared-series leaves a stale seriesIndex (`.keep` when series empty); `DiagnosticsView` reloads twice on presentation (harmless); `importURLs`/`diagnosticsPresented` dead state.
