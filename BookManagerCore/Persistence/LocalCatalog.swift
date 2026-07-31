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
        // GRDB stores UUID values as 16-byte blobs, which can never equal the
        // text bookID kept in the FTS5 table, so ids are written explicitly as
        // their canonical uuidString form on both sides of the join.
        let authorsJSON = String(decoding: try JSONEncoder().encode(book.authors), as: UTF8.self)
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO book(id, title, authors, modifiedMilliseconds, isDeleted, snapshot)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        title = excluded.title,
                        authors = excluded.authors,
                        modifiedMilliseconds = excluded.modifiedMilliseconds,
                        isDeleted = excluded.isDeleted,
                        snapshot = excluded.snapshot
                    """,
                arguments: [
                    book.id.uuidString,
                    book.title,
                    authorsJSON,
                    book.modifiedMilliseconds,
                    book.isDeleted,
                    book.snapshot
                ]
            )
            try db.execute(sql: "DELETE FROM bookSearch WHERE bookID = ?", arguments: [book.id.uuidString])
            try db.execute(
                sql: "INSERT INTO bookSearch(bookID, title, authors) VALUES (?, ?, ?)",
                arguments: [book.id.uuidString, book.title, book.authors.joined(separator: " ")]
            )
        }
    }

    public func allBooks() throws -> [IndexedBook] {
        try database.read { db in
            try IndexedBook
                .filter(IndexedBook.Columns.isDeleted == false)
                .order(IndexedBook.Columns.title.collating(.localizedCaseInsensitiveCompare))
                .fetchAll(db)
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
                    SELECT book.*
                    FROM book
                    JOIN bookSearch ON bookSearch.bookID = book.id
                    WHERE bookSearch MATCH ? AND book.isDeleted = 0
                    ORDER BY book.title COLLATE NOCASE
                    """,
                arguments: [query]
            )
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
        }
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("createBookIndex") { db in
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
        return migrator
    }
}
