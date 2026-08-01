import Foundation
import GRDB

/// The SQL surface a Calibre library database must expose. Versioned adapters
/// isolate schema drift so the reader never spreads table knowledge around.
protocol CalibreSchemaAdapting: Sendable {
    /// The `PRAGMA user_version` value this adapter understands.
    static var supportedUserVersion: Int { get }

    /// Validates the database: readable version + books table present.
    /// Throws `CalibreReaderError.unsupportedSchemaVersion` or
    /// `CalibreReaderError.notACalibreLibrary` on failure.
    func validate(_ db: Database, libraryURL: URL) throws

    func userVersion(_ db: Database) throws -> Int
    func libraryID(_ db: Database) throws -> String
    func bookCount(_ db: Database) throws -> Int
    func formatCount(_ db: Database) throws -> Int
    func fetchBooks(_ db: Database) throws -> [Row]
    func fetchAuthors(_ db: Database) throws -> [(book: Int, name: String, sort: String)]
    func fetchSeries(_ db: Database) throws -> [(book: Int, name: String)]
    func fetchTags(_ db: Database) throws -> [(book: Int, name: String)]
    func fetchRatings(_ db: Database) throws -> [(book: Int, rating: Int)]
    func fetchPublishers(_ db: Database) throws -> [(book: Int, name: String)]
    func fetchLanguages(_ db: Database) throws -> [(book: Int, code: String)]
    func fetchIdentifiers(_ db: Database) throws -> [(book: Int, type: String, value: String)]
    func fetchComments(_ db: Database) throws -> [(book: Int, text: String)]
    func fetchFormats(_ db: Database) throws -> [(book: Int, format: String, name: String, size: Int64, path: String?)]
    func customColumns(_ db: Database) throws -> [CalibreCustomColumn]
    func fetchCustomValues(_ db: Database, column: CalibreCustomColumn) throws -> [(book: Int, value: String?)]
    func fetchAnnotations(_ db: Database) throws -> [(book: Int, payload: String)]
    func fetchLastReadPositions(_ db: Database) throws -> [(book: Int, payload: String)]
    func columns(in table: String, _ db: Database) throws -> Set<String>
}

/// A custom column definition read from `custom_columns`.
struct CalibreCustomColumn: Sendable, Equatable {
    let id: Int
    let label: String
    let name: String
    let datatype: String
    let isMultiple: Bool
}

/// Adapter for Calibre database schema `user_version` 26
/// (the schema shipped with Calibre ~6.x-7.x; authoritative DDL from
/// kovidgoyal/calibre `resources/metadata_sqlite.sql` at commit aabd29c571f8).
struct CalibreSchema26: CalibreSchemaAdapting {
    static let supportedUserVersion = 26

    func validate(_ db: Database, libraryURL: URL) throws {
        let version = try userVersion(db)
        guard version == Self.supportedUserVersion else {
            throw CalibreReaderError.unsupportedSchemaVersion(version)
        }
        let tableNames = try String.fetchAll(
            db,
            sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'books'"
        )
        guard !tableNames.isEmpty else {
            throw CalibreReaderError.notACalibreLibrary(libraryURL)
        }
    }

    func userVersion(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
    }

    func libraryID(_ db: Database) throws -> String {
        try String.fetchOne(db, sql: "SELECT uuid FROM library_id LIMIT 1") ?? ""
    }

    func bookCount(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM books") ?? 0
    }

    func formatCount(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM data") ?? 0
    }

    func fetchBooks(_ db: Database) throws -> [Row] {
        try Row.fetchAll(db, sql: "SELECT * FROM books ORDER BY id")
    }

    func fetchAuthors(_ db: Database) throws -> [(book: Int, name: String, sort: String)] {
        // Author order is the books_authors_link row order (Calibre's
        // `sortconcat(bal.id, ...)` in the meta view).
        try Row.fetchAll(
            db,
            sql: """
                SELECT bal.book AS book, a.name AS name, a.sort AS sort
                FROM books_authors_link bal
                JOIN authors a ON a.id = bal.author
                ORDER BY bal.book, bal.id
                """
        ).map {
            (book: $0["book"] as Int, name: $0["name"] as String, sort: $0["sort"] as String? ?? "")
        }
    }

    func fetchSeries(_ db: Database) throws -> [(book: Int, name: String)] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT bsl.book AS book, s.name AS name
                FROM books_series_link bsl
                JOIN series s ON s.id = bsl.series
                ORDER BY bsl.book
                """
        ).map { (book: $0["book"] as Int, name: $0["name"] as String) }
    }

    func fetchTags(_ db: Database) throws -> [(book: Int, name: String)] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT btl.book AS book, t.name AS name
                FROM books_tags_link btl
                JOIN tags t ON t.id = btl.tag
                ORDER BY btl.book, btl.id
                """
        ).map { (book: $0["book"] as Int, name: $0["name"] as String) }
    }

    func fetchRatings(_ db: Database) throws -> [(book: Int, rating: Int)] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT brl.book AS book, r.rating AS rating
                FROM books_ratings_link brl
                JOIN ratings r ON r.id = brl.rating
                ORDER BY brl.book, brl.id
                """
        ).map { (book: $0["book"] as Int, rating: $0["rating"] as Int) }
    }

    func fetchPublishers(_ db: Database) throws -> [(book: Int, name: String)] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT bpl.book AS book, p.name AS name
                FROM books_publishers_link bpl
                JOIN publishers p ON p.id = bpl.publisher
                ORDER BY bpl.book
                """
        ).map { (book: $0["book"] as Int, name: $0["name"] as String) }
    }

    func fetchLanguages(_ db: Database) throws -> [(book: Int, code: String)] {
        let linkColumns = try columns(in: "books_languages_link", db)
        if linkColumns.contains("lang") {
            // Legacy shape: `lang` is the language code directly.
            return try Row.fetchAll(
                db,
                sql: "SELECT book AS book, lang AS code FROM books_languages_link ORDER BY book, item_order"
            ).map { (book: $0["book"] as Int, code: $0["code"] as String) }
        }
        // v26 shape: lang_code is an INTEGER foreign key to languages.id.
        return try Row.fetchAll(
            db,
            sql: """
                SELECT bll.book AS book, l.lang_code AS code
                FROM books_languages_link bll
                JOIN languages l ON l.id = bll.lang_code
                ORDER BY bll.book, bll.item_order
                """
        ).map { (book: $0["book"] as Int, code: $0["code"] as String) }
    }

    func fetchIdentifiers(_ db: Database) throws -> [(book: Int, type: String, value: String)] {
        try Row.fetchAll(
            db,
            sql: "SELECT book AS book, type AS type, val AS value FROM identifiers ORDER BY book, id"
        ).map {
            (book: $0["book"] as Int, type: $0["type"] as String, value: $0["value"] as String)
        }
    }

    func fetchComments(_ db: Database) throws -> [(book: Int, text: String)] {
        try Row.fetchAll(
            db,
            sql: "SELECT book AS book, text AS text FROM comments ORDER BY book"
        ).map { (book: $0["book"] as Int, text: $0["text"] as String) }
    }

    func fetchFormats(_ db: Database) throws -> [(book: Int, format: String, name: String, size: Int64, path: String?)] {
        let dataColumns = try columns(in: "data", db)
        if dataColumns.contains("path") {
            return try Row.fetchAll(
                db,
                sql: """
                    SELECT book AS book, format AS format, name AS name,
                           uncompressed_size AS size, path AS path
                    FROM data ORDER BY book, id
                    """
            ).map {
                (
                    book: $0["book"] as Int,
                    format: $0["format"] as String,
                    name: $0["name"] as String,
                    size: $0["size"] as Int64,
                    path: $0["path"] as String?
                )
            }
        }
        return try Row.fetchAll(
            db,
            sql: """
                SELECT book AS book, format AS format, name AS name, uncompressed_size AS size
                FROM data ORDER BY book, id
                """
        ).map {
            (
                book: $0["book"] as Int,
                format: $0["format"] as String,
                name: $0["name"] as String,
                size: $0["size"] as Int64,
                path: nil
            )
        }
    }

    func customColumns(_ db: Database) throws -> [CalibreCustomColumn] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT id AS id, label AS label, name AS name, datatype AS datatype,
                       is_multiple AS is_multiple
                FROM custom_columns ORDER BY id
                """
        ).map {
            CalibreCustomColumn(
                id: $0["id"] as Int,
                label: $0["label"] as String,
                name: $0["name"] as String,
                datatype: $0["datatype"] as String,
                isMultiple: ($0["is_multiple"] as Int? ?? 0) != 0
            )
        }
    }

    func fetchCustomValues(_ db: Database, column: CalibreCustomColumn) throws -> [(book: Int, value: String?)] {
        if column.isMultiple {
            let table = "books_custom_column_\(column.id)_link"
            guard try !columns(in: table, db).isEmpty else { return [] }
            return try Row.fetchAll(
                db,
                sql: "SELECT book AS book, value AS value FROM \(table) ORDER BY book, id"
            ).map { (book: $0["book"] as Int, value: $0["value"] as String?) }
        }
        let table = "custom_column_\(column.id)"
        guard try !columns(in: table, db).isEmpty else { return [] }
        return try Row.fetchAll(
            db,
            sql: "SELECT book AS book, value AS value FROM \(table) ORDER BY book"
        ).map { (book: $0["book"] as Int, value: $0["value"] as String?) }
    }

    func fetchAnnotations(_ db: Database) throws -> [(book: Int, payload: String)] {
        let tables = try String.fetchAll(
            db,
            sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'annotations'"
        )
        guard !tables.isEmpty else { return [] }
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT book AS book, format AS format, user_type AS user_type,
                       user AS user, annot_id AS annot_id, annot_type AS annot_type,
                       annot_data AS annot_data
                FROM annotations ORDER BY book, id
                """
        )
        return try Self.groupJSON(rows: rows, keys: ["format", "user_type", "user", "annot_id", "annot_type", "annot_data"])
    }

    func fetchLastReadPositions(_ db: Database) throws -> [(book: Int, payload: String)] {
        let tables = try String.fetchAll(
            db,
            sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'last_read_positions'"
        )
        guard !tables.isEmpty else { return [] }
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT book AS book, format AS format, user AS user, device AS device,
                       cfi AS cfi, epoch AS epoch, pos_frac AS pos_frac
                FROM last_read_positions ORDER BY book, id
                """
        )
        return try Self.groupJSON(rows: rows, keys: ["format", "user", "device", "cfi", "epoch", "pos_frac"])
    }

    func columns(in table: String, _ db: Database) throws -> Set<String> {
        let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
        return Set(rows.compactMap { $0["name"] as String })
    }

    /// Groups rows by `book` and encodes each group as a JSON array of
    /// dictionaries containing only the listed keys. Values are read by
    /// storage class (GRDB's typed `as` cast is strict and cannot be used
    /// across storage classes).
    private static func groupJSON(rows: [Row], keys: [String]) throws -> [(book: Int, payload: String)] {
        var grouped: [Int: [[String: String]]] = [:]
        for row in rows {
            let book = row["book"] as Int
            var dict: [String: String] = [:]
            for key in keys {
                guard let value = row[key] else { continue }
                switch value.databaseValue.storage {
                case .string(let string):
                    dict[key] = string
                case .int64(let int):
                    dict[key] = String(int)
                case .double(let double):
                    dict[key] = String(double)
                case .blob, .null:
                    break
                }
            }
            grouped[book, default: []].append(dict)
        }
        let encoder = JSONEncoder()
        return try grouped.sorted { $0.key < $1.key }.map { book, entries in
            (book: book, payload: String(decoding: try encoder.encode(entries), as: UTF8.self))
        }
    }
}
