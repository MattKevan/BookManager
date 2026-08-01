import Foundation
import GRDB
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
        tags: [String] = [],
        series: String? = nil,
        identifiers: [String: String] = [:],
        formats: [BookFormatRecord] = [],
        deleted: Bool = false
    ) -> IndexedBook {
        IndexedBook(
            id: id, title: title, authors: authors,
            series: series, seriesIndex: series == nil ? nil : 1,
            tags: tags, rating: 4, publisher: "Riverhead",
            publicationMilliseconds: 1_000, addedMilliseconds: 2_000,
            languages: ["eng"], identifiers: identifiers,
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
        // Build a genuine slice-1 database exactly as createV1Schema did — book
        // table + FTS5 bookSearch + the migrator's bookkeeping row — insert a
        // v1-shaped row, then reopen through LocalCatalog. The v2 migration must
        // run cleanly. The v1 row itself is deliberately dropped by that
        // migration: the catalogue is disposable and is rebuilt from the change
        // store, so the assertion is that the upgrade runs and the v2 schema is
        // live, not that v1 data survives.
        let databaseURL = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).sqlite")
        let v1 = try DatabaseQueue(path: databaseURL.path)
        try await v1.write { db in
            try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
            try db.execute(sql: "INSERT INTO grdb_migrations(identifier) VALUES ('createBookIndex')")
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
            try db.execute(
                sql: "INSERT INTO book(id, title, authors, modifiedMilliseconds, isDeleted, snapshot) VALUES (?, ?, ?, ?, ?, ?)",
                arguments: [UUID().uuidString, "Old", "[\"A\"]", 1_000, false, Data([9])]
            )
        }
        try v1.close()

        let catalog = try LocalCatalog(databaseURL: databaseURL)
        #expect(try await catalog.allBooks().isEmpty)

        // The v2 schema is live: upsert and read back a v2 book.
        try await catalog.upsert(book(title: "New"))
        let after = try await catalog.allBooks()
        #expect(after.count == 1)
        #expect(after[0].title == "New")
        #expect(after[0].tags.isEmpty)
        #expect(after[0].formats.isEmpty)
    }
}
