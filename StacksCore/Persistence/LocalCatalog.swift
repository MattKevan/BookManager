import Foundation
import GRDB

public actor LocalCatalog {
    private let database: DatabaseQueue

    public init(databaseURL: URL) throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // WAL + synchronous=NORMAL: per-write-transaction commits (the rebuild
        // replays every journal command as its own upsert) skip the
        // fsync-per-commit cost. The catalog is disposable — WAL durability
        // tradeoffs are acceptable, and a rebuild recreates it from the journal.
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode=WAL")
            try db.execute(sql: "PRAGMA synchronous=NORMAL")
        }
        database = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
        try Self.migrator.migrate(database)
    }

    public func upsert(_ book: IndexedBook) throws {
        try database.write { db in
            try upsert(book, db: db)
        }
    }

    /// Upserts many books in ONE transaction (rebuild/ingest hot path — 10k
    /// per-book transactions become one).
    public func upsertBatch(_ books: [IndexedBook]) throws {
        try database.write { db in
            for book in books {
                try upsert(book, db: db)
            }
        }
    }

    private func upsert(_ book: IndexedBook, db: Database) throws {
        let authorsJSON = try JSONCoding.encode(book.authors)
        let tagsJSON = try JSONCoding.encode(book.tags)
        let languagesJSON = try JSONCoding.encode(book.languages)
        let identifiersJSON = try JSONCoding.encode(book.identifiers)
        let rawMetadataJSON = try book.rawMetadata.map(JSONCoding.encode)
        let formatsJSON = try JSONCoding.encode(book.formats)
        try db.execute(
                sql: """
                    INSERT INTO book(id, title, authors, series, seriesIndex, tags, rating, publisher,
                        publicationMilliseconds, addedMilliseconds, languages, identifiers, comments,
                        rawMetadata, formats, coverHash, relativePath, modifiedMilliseconds, isDeleted)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        title = excluded.title, authors = excluded.authors, series = excluded.series,
                        seriesIndex = excluded.seriesIndex, tags = excluded.tags, rating = excluded.rating,
                        publisher = excluded.publisher,
                        publicationMilliseconds = excluded.publicationMilliseconds,
                        addedMilliseconds = excluded.addedMilliseconds, languages = excluded.languages,
                        identifiers = excluded.identifiers, comments = excluded.comments,
                        rawMetadata = excluded.rawMetadata,
                        formats = excluded.formats, coverHash = excluded.coverHash,
                        relativePath = excluded.relativePath, modifiedMilliseconds = excluded.modifiedMilliseconds,
                        isDeleted = excluded.isDeleted
                    """,
                arguments: [
                    book.id.uuidString, book.title, authorsJSON, book.series,
                    book.seriesIndex, tagsJSON, book.rating,
                    book.publisher, book.publicationMilliseconds,
                    book.addedMilliseconds, languagesJSON, identifiersJSON,
                    book.comments, rawMetadataJSON, formatsJSON, book.coverHash, book.relativePath,
                    book.modifiedMilliseconds, book.isDeleted
                ]
            )
            // FTS5 upsert by a stable integer rowid: `DELETE FROM bookSearch
            // WHERE bookID = ?` would scan the whole inverted index (bookID is
            // a notIndexed column) — quadratic on rebuilds. A replace by rowid
            // is O(1) and re-inserts the fresh searchable text.
            try db.execute(
                sql: "INSERT OR REPLACE INTO bookSearch(rowid, bookID, title, authors, series, tags, identifiers, comments) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                arguments: [
                    Self.searchRowID(book.id), book.id.uuidString, book.title,
                    book.authors.joined(separator: " "),
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

    public func allBooks() throws -> [IndexedBook] {
        try database.read { db in
            try IndexedBook.fetchAll(
                db,
                sql: "SELECT * FROM book WHERE isDeleted = 0 ORDER BY title COLLATE NOCASE"
            )
        }
    }

    public func search(_ query: String) throws -> [IndexedBook] {
        // FTS5's MATCH syntax rejects unbalanced quotes and bare operators
        // (unclosed `"`, stray `-`/`*`, bare `OR`) with a syntax error that
        // the caller surfaces as an empty search. Quote every token so user
        // input is treated as literal text; tokens that collapse to nothing
        // are dropped. A query of only dropped tokens behaves like no search.
        let sanitized = Self.ftsQuery(from: query)
        guard !sanitized.isEmpty else {
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
                arguments: [sanitized]
            )
        }
    }

    /// Wraps every whitespace-separated token of a user search in double
    /// quotes (with embedded quotes stripped) so FTS5 treats it as literal
    /// text instead of query syntax.
    private static func ftsQuery(from raw: String) -> String {
        raw.split(whereSeparator: \.isWhitespace).compactMap { token in
            let escaped = token.replacingOccurrences(of: "\"", with: "")
            guard !escaped.isEmpty else { return nil }
            return "\"\(escaped)\""
        }.joined(separator: " ")
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
            // Deleted books keep their facet rows until the book row is gone
            // (deleteBook/restoreBook upsert without touching facets) — the
            // counts must join on the live book, or every deleted book's
            // authors/tags/series would inflate the sidebar counts forever.
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT bf.value, COUNT(*) AS count FROM bookFacet bf
                    JOIN book b ON b.id = bf.bookID
                    WHERE bf.type = ? AND b.isDeleted = 0
                    GROUP BY bf.value ORDER BY bf.value COLLATE NOCASE
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
                sql: "SELECT bookID FROM bookFormatHash WHERE contentHash = ? ORDER BY bookID",
                arguments: [contentHash]
            ).compactMap { UUID(uuidString: $0) }
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

    /// A stable, collision-negligible integer rowid for a book's FTS5 search
    /// row — lets the upsert REPLACE instead of DELETE (the delete path
    /// scanned the whole inverted index, quadratic on rebuilds).
    private static func searchRowID(_ bookID: UUID) -> Int64 {
        withUnsafeBytes(of: bookID.uuid) { raw in
            Int64(bitPattern: raw.load(as: UInt64.self))
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
        migrator.registerMigration("v3RawMetadata") { db in
            try db.drop(table: "book")
            try createBookTable(db, rawMetadata: true)
        }
        // v4 (journal era): the catalog no longer stores the CRDT snapshot
        // blob — the journal is authoritative and the catalog is rebuilt from
        // it. The disposable table is recreated.
        migrator.registerMigration("v4Journal") { db in
            try db.drop(table: "book")
            try createBookTable(db, rawMetadata: true)
        }
        // v5: index the facet table's bookID so per-book deletes (upsert)
        // don't scan the whole table — the facet PK is (type, value, bookID),
        // so a bookID-only delete is quadratic without this.
        migrator.registerMigration("v5FacetBookIDIndex") { db in
            try db.create(index: "bookFacet_bookID", on: "bookFacet", columns: ["bookID"])
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
        try createBookTable(db, rawMetadata: false)
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
            if rawMetadata {
                table.column("rawMetadata", .text)
            }
            table.column("formats", .text).notNull()
            table.column("coverHash", .text)
            table.column("relativePath", .text).notNull()
            table.column("modifiedMilliseconds", .integer).notNull()
            table.column("isDeleted", .boolean).notNull()
        }
    }
}
