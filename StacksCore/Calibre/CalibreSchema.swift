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
    func fetchFormats(_ db: Database) throws -> [CalibreFormatRow]
    func customColumns(_ db: Database) throws -> [CalibreCustomColumn]
    func fetchCustomValues(_ db: Database, column: CalibreCustomColumn) throws -> [CalibreCustomValueRow]
    func fetchAnnotations(_ db: Database) throws -> [(book: Int, payload: String)]
    func fetchLastReadPositions(_ db: Database) throws -> [(book: Int, payload: String)]
    func fetchPageCounts(_ db: Database) throws -> [CalibrePageCountRow]
    func fetchConversionOptions(_ db: Database) throws -> [(book: Int, format: String, data: Data)]
    func columns(in table: String, _ db: Database) throws -> Set<String>
}

/// A `data` row — one of a book's format files plus its book id.
struct CalibreFormatRow: Sendable, Equatable {
    let book: Int
    let format: String
    let name: String
    let size: Int64
    let path: String?
}

/// A `books_pages_link` row — a book's page count plus its book id.
struct CalibrePageCountRow: Sendable, Equatable {
    let book: Int
    let pages: Int
    let algorithm: Int
    let format: String
    let formatSize: Int64
}

/// A custom-column value row — the value (and multi-value `.extra`) for one
/// book, plus the book id.
struct CalibreCustomValueRow: Sendable, Equatable {
    let book: Int
    let value: String?
    let extra: String?
}

/// A custom column definition read from `custom_columns`.
struct CalibreCustomColumn: Sendable, Equatable {
    let id: Int
    let label: String
    let name: String
    let datatype: String
    let display: String
    let isMultiple: Bool
    let editable: Bool
    let normalized: Bool
    let markForDelete: Bool
}

/// Adapter base for Calibre database schemas. Query logic is shared across
/// supported `user_version`s; each subclass pins the version it accepts
/// (authoritative DDL: kovidgoyal/calibre `resources/metadata_sqlite.sql`).
class CalibreSchemaBase: CalibreSchemaAdapting, @unchecked Sendable {
    /// Overridden by each version subclass; `class` (not `static`) so the
    /// protocol's static requirement is satisfied with dynamic dispatch.
    class var supportedUserVersion: Int { 26 }

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
        // PRAGMA user_version is INTEGER, but a corrupted value must degrade
        // to "unsupported" rather than trap in GRDB's typed fetch.
        guard let row = try Row.fetchOne(db, sql: "PRAGMA user_version") else { return 0 }
        return Self.int(row["user_version"]?.databaseValue) ?? 0
    }

    func libraryID(_ db: Database) throws -> String {
        guard let row = try Row.fetchOne(db, sql: "SELECT uuid FROM library_id LIMIT 1") else {
            return ""
        }
        return Self.valueString(row["uuid"]?.databaseValue) ?? ""
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
        ).compactMap { row in
            guard let book = Self.int(row["book"]?.databaseValue),
                  let name = Self.valueString(row["name"]?.databaseValue) else {
                return nil
            }
            return (book: book, name: name, sort: Self.valueString(row["sort"]?.databaseValue) ?? "")
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
        ).compactMap { row in
            guard let book = Self.int(row["book"]?.databaseValue),
                  let name = Self.valueString(row["name"]?.databaseValue) else {
                return nil
            }
            return (book: book, name: name)
        }
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
        ).compactMap { row in
            guard let book = Self.int(row["book"]?.databaseValue),
                  let name = Self.valueString(row["name"]?.databaseValue) else {
                return nil
            }
            return (book: book, name: name)
        }
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
        ).compactMap { row in
            guard let book = Self.int(row["book"]?.databaseValue),
                  let rating = Self.int(row["rating"]?.databaseValue) else {
                return nil
            }
            return (book: book, rating: rating)
        }
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
        ).compactMap { row in
            guard let book = Self.int(row["book"]?.databaseValue),
                  let name = Self.valueString(row["name"]?.databaseValue) else {
                return nil
            }
            return (book: book, name: name)
        }
    }

    func fetchLanguages(_ db: Database) throws -> [(book: Int, code: String)] {
        let linkColumns = try columns(in: "books_languages_link", db)
        if linkColumns.contains("lang") {
            // Legacy shape: `lang` is the language code directly.
            return try Row.fetchAll(
                db,
                sql: "SELECT book AS book, lang AS code FROM books_languages_link ORDER BY book, item_order"
            ).compactMap { row in
                guard let book = Self.int(row["book"]?.databaseValue),
                      let code = Self.valueString(row["code"]?.databaseValue) else {
                    return nil
                }
                return (book: book, code: code)
            }
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
        ).compactMap { row in
            guard let book = Self.int(row["book"]?.databaseValue),
                  let code = Self.valueString(row["code"]?.databaseValue) else {
                return nil
            }
            return (book: book, code: code)
        }
    }

    func fetchIdentifiers(_ db: Database) throws -> [(book: Int, type: String, value: String)] {
        try Row.fetchAll(
            db,
            sql: "SELECT book AS book, type AS type, val AS value FROM identifiers ORDER BY book, id"
        ).compactMap { row in
            guard let book = Self.int(row["book"]?.databaseValue),
                  let type = Self.valueString(row["type"]?.databaseValue),
                  let value = Self.valueString(row["value"]?.databaseValue) else {
                return nil
            }
            return (book: book, type: type, value: value)
        }
    }

    func fetchComments(_ db: Database) throws -> [(book: Int, text: String)] {
        try Row.fetchAll(
            db,
            sql: "SELECT book AS book, text AS text FROM comments ORDER BY book"
        ).compactMap { row in
            guard let book = Self.int(row["book"]?.databaseValue),
                  let text = Self.valueString(row["text"]?.databaseValue) else {
                return nil
            }
            return (book: book, text: text)
        }
    }

    func fetchFormats(_ db: Database) throws -> [CalibreFormatRow] {
        let dataColumns = try columns(in: "data", db)
        if dataColumns.contains("path") {
            return try Row.fetchAll(
                db,
                sql: """
                    SELECT book AS book, format AS format, name AS name,
                           uncompressed_size AS size, path AS path
                    FROM data ORDER BY book, id
                    """
            ).compactMap { row in
                guard let book = Self.int(row["book"]?.databaseValue),
                      let format = Self.valueString(row["format"]?.databaseValue),
                      let name = Self.valueString(row["name"]?.databaseValue),
                      let size = Self.int64(row["size"]?.databaseValue) else {
                    return nil
                }
                return CalibreFormatRow(
                    book: book,
                    format: format,
                    name: name,
                    size: size,
                    path: Self.valueString(row["path"]?.databaseValue)
                )
            }
        }
        return try Row.fetchAll(
            db,
            sql: """
                SELECT book AS book, format AS format, name AS name, uncompressed_size AS size
                FROM data ORDER BY book, id
                """
        ).compactMap { row in
            guard let book = Self.int(row["book"]?.databaseValue),
                  let format = Self.valueString(row["format"]?.databaseValue),
                  let name = Self.valueString(row["name"]?.databaseValue),
                  let size = Self.int64(row["size"]?.databaseValue) else {
                return nil
            }
            return CalibreFormatRow(
                book: book,
                format: format,
                name: name,
                size: size,
                path: nil
            )
        }
    }

    func customColumns(_ db: Database) throws -> [CalibreCustomColumn] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT id AS id, label AS label, name AS name, datatype AS datatype,
                       display AS display, is_multiple AS is_multiple,
                       editable AS editable, normalized AS normalized,
                       mark_for_delete AS mark_for_delete
                FROM custom_columns ORDER BY id
                """
        ).compactMap { row in
            guard let id = Self.int(row["id"]?.databaseValue),
                  let label = Self.valueString(row["label"]?.databaseValue),
                  let name = Self.valueString(row["name"]?.databaseValue),
                  let datatype = Self.valueString(row["datatype"]?.databaseValue) else {
                return nil
            }
            return CalibreCustomColumn(
                id: id,
                label: label,
                name: name,
                datatype: datatype,
                display: Self.valueString(row["display"]?.databaseValue) ?? "{}",
                isMultiple: Self.bool(row["is_multiple"]?.databaseValue) ?? false,
                editable: Self.bool(row["editable"]?.databaseValue) ?? true,
                normalized: Self.bool(row["normalized"]?.databaseValue) ?? false,
                markForDelete: Self.bool(row["mark_for_delete"]?.databaseValue) ?? false
            )
        }
    }

    func fetchCustomValues(_ db: Database, column: CalibreCustomColumn) throws -> [CalibreCustomValueRow] {
        if column.isMultiple {
            let table = "books_custom_column_\(column.id)_link"
            guard try !columns(in: table, db).isEmpty else { return [] }
            return try Row.fetchAll(
                db,
                sql: "SELECT book AS book, value AS value, extra AS extra FROM \(table) ORDER BY book, id"
            ).compactMap { row in
                guard let book = Self.int(row["book"]?.databaseValue) else { return nil }
                return CalibreCustomValueRow(
                    book: book,
                    value: Self.valueString(row["value"]?.databaseValue),
                    extra: Self.valueString(row["extra"]?.databaseValue)
                )
            }
        }
        let table = "custom_column_\(column.id)"
        guard try !columns(in: table, db).isEmpty else { return [] }
        return try Row.fetchAll(
            db,
            sql: "SELECT book AS book, value AS value FROM \(table) ORDER BY book"
        ).compactMap { row in
            guard let book = Self.int(row["book"]?.databaseValue) else { return nil }
            return CalibreCustomValueRow(
                book: book,
                value: Self.valueString(row["value"]?.databaseValue),
                extra: nil
            )
        }
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
                       annot_data AS annot_data, searchable_text AS searchable_text,
                       timestamp AS timestamp
                FROM annotations ORDER BY book, id
                """
        )
        return try Self.groupJSON(
            rows: rows,
            keys: ["format", "user_type", "user", "annot_id", "annot_type", "annot_data", "searchable_text", "timestamp"]
        )
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

    func fetchPageCounts(_ db: Database) throws -> [CalibrePageCountRow] {
        guard try !columns(in: "books_pages_link", db).isEmpty else { return [] }
        return try Row.fetchAll(db, sql: """
            SELECT book AS book, pages AS pages, algorithm AS algorithm,
                   format AS format, format_size AS format_size
            FROM books_pages_link
            """).compactMap { row in
                guard let book = Self.int(row["book"]?.databaseValue),
                      let pages = Self.int(row["pages"]?.databaseValue),
                      let algorithm = Self.int(row["algorithm"]?.databaseValue),
                      let format = Self.valueString(row["format"]?.databaseValue),
                      let formatSize = Self.int64(row["format_size"]?.databaseValue) else {
                    return nil
                }
                return CalibrePageCountRow(
                    book: book,
                    pages: pages,
                    algorithm: algorithm,
                    format: format,
                    formatSize: formatSize
                )
            }
    }

    func fetchConversionOptions(_ db: Database) throws -> [(book: Int, format: String, data: Data)] {
        guard try !columns(in: "conversion_options", db).isEmpty else { return [] }
        return try Row.fetchAll(db, sql: """
            SELECT book AS book, format AS format, data AS data
            FROM conversion_options
            """).compactMap { row in
                guard let book = Self.int(row["book"]?.databaseValue),
                      let format = Self.valueString(row["format"]?.databaseValue),
                      let data = Self.data(row["data"]?.databaseValue) else {
                    return nil
                }
                return (book: book, format: format, data: data)
            }
    }

    func columns(in table: String, _ db: Database) throws -> Set<String> {
        let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
        return Set(rows.compactMap { Self.valueString($0["name"]?.databaseValue) })
    }

    private static func valueString(_ value: DatabaseValue?) -> String? {
        guard let value else { return nil }
        switch value.storage {
        case .string(let string):
            return string
        case .int64(let int):
            return String(int)
        case .double(let double):
            return String(double)
        case .blob(let data):
            return String(decoding: data, as: UTF8.self)
        case .null:
            return nil
        }
    }

    /// Storage-class-tolerant integer read. GRDB's typed `as Int` cast traps
    /// across storage classes (a hostile or corrupted database must degrade —
    /// the row is skipped by the caller — never crash the whole scan).
    static func int(_ value: DatabaseValue?) -> Int? {
        guard let value else { return nil }
        switch value.storage {
        case .int64(let int): return Int(int)
        case .double(let double): return Int(double)
        case .string(let string): return Int(string)
        case .blob, .null: return nil
        }
    }

    /// Storage-class-tolerant 64-bit integer read (see `int(_:)`).
    static func int64(_ value: DatabaseValue?) -> Int64? {
        guard let value else { return nil }
        switch value.storage {
        case .int64(let int): return int
        case .double(let double): return Int64(double)
        case .string(let string): return Int64(string)
        case .blob, .null: return nil
        }
    }

    /// Storage-class-tolerant BLOB read: `conversion_options.data` is a BLOB
    /// in real Calibre; a hostile TEXT value degrades to its UTF-8 bytes.
    static func data(_ value: DatabaseValue?) -> Data? {
        guard let value else { return nil }
        switch value.storage {
        case .blob(let data): return data
        case .string(let string): return Data(string.utf8)
        case .int64, .double, .null: return nil
        }
    }

    /// Storage-class-tolerant boolean read for the custom-column flag columns
    /// (0/1 INTEGER in real Calibre; some tools write TEXT "1"/"true").
    static func bool(_ value: DatabaseValue?) -> Bool? {
        guard let value else { return nil }
        switch value.storage {
        case .int64(let int): return int != 0
        case .double(let double): return double != 0
        case .string(let string):
            return string == "1" || string.caseInsensitiveCompare("true") == .orderedSame
        case .blob, .null: return nil
        }
    }

    /// Groups rows by `book` and encodes each group as a JSON array of
    /// dictionaries containing only the listed keys. Values are read by
    /// storage class (GRDB's typed `as` cast is strict and cannot be used
    /// across storage classes).
    private static func groupJSON(rows: [Row], keys: [String]) throws -> [(book: Int, payload: String)] {
        var grouped: [Int: [[String: String]]] = [:]
        for row in rows {
            // A row without a decodable book id is corrupt — skip it rather
            // than trap in a typed cast.
            guard let book = Self.int(row["book"]?.databaseValue) else { continue }
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
        // Sorted keys: these payloads are preserved verbatim in rawMetadata,
        // and deterministic encoding keeps identical reads byte-identical
        // (unsorted dictionary output varies per process).
        encoder.outputFormatting = [.sortedKeys]
        return try grouped.sorted { $0.key < $1.key }.map { book, entries in
            (book: book, payload: String(decoding: try encoder.encode(entries), as: UTF8.self))
        }
    }
}

/// Adapter for Calibre database schema `user_version` 26
/// (the schema shipped with Calibre ~6.x).
final class CalibreSchema26: CalibreSchemaBase {
    override class var supportedUserVersion: Int { 26 }
}

/// Adapter for Calibre database schema `user_version` 27 (current Calibre):
/// v26 plus the `books_pages_link` table (+ insert trigger/index) and minus
/// the `isbn`/`lccn`/`flags` books columns. Query logic is identical; the
/// new tables are read defensively when present.
final class CalibreSchema27: CalibreSchemaBase {
    override class var supportedUserVersion: Int { 27 }
}
