import Foundation
import GRDB
import Testing
@testable import StacksCore

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
