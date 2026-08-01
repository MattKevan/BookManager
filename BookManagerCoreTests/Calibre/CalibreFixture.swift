import Foundation
import GRDB
@testable import BookManagerCore

/// Builds a faithful Calibre `user_version`-26 library for reader tests.
///
/// The DDL is a subset of Calibre's authoritative `resources/metadata_sqlite.sql`
/// (kovidgoyal/calibre, commit aabd29c571f8 — `pragma user_version=26`),
/// covering every table the reader queries. The 13 books exercise the mapping
/// matrix: multi-author ordering, multi-format, series+index, tags,
/// rating+publisher, julian dates, languages, identifiers, comments, covers
/// (file and — in the variant — BLOB), scalar and multiple custom columns,
/// unsupported columns (lccn/pages), annotations, last-read positions, a
/// missing format file, and an OPF cross-check fallback.
enum CalibreFixture {
    static let expectedBookCount = 13
    static let expectedFormatCount = 10

    static func makeLibrary(named name: String = "fixture-library") throws -> URL {
        try makeLibrary(named: name, userVersion: 26, extraColumns: false, textDates: false)
    }

    /// Variant builder: optionally adds `pages`/`cover BLOB` columns to `books`
    /// (schema drift the reader must handle defensively) and sets an arbitrary
    /// `user_version`.
    static func makeVariantLibrary(
        named name: String = "variant-library",
        userVersion: Int,
        extraColumns: Bool
    ) throws -> URL {
        try makeLibrary(named: name, userVersion: userVersion, extraColumns: extraColumns, textDates: false)
    }

    /// Variant builder: stores `pubdate`/`timestamp` as ISO-8601 TEXT
    /// ("2019-05-28 00:00:00+00:00") instead of Julian REALs — the shape some
    /// tools (e.g. calibre-web) write into the `TIMESTAMP` columns.
    static func makeTextDateLibrary(named name: String = "text-dates-library") throws -> URL {
        try makeLibrary(named: name, userVersion: 26, extraColumns: false, textDates: true)
    }

    private static func makeLibrary(named name: String, userVersion: Int, extraColumns: Bool, textDates: Bool) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: name, directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try buildDatabase(
            at: root.appending(path: "metadata.db"),
            userVersion: userVersion,
            extraColumns: extraColumns,
            textDates: textDates
        )
        try writeBookFolders(at: root, extraColumns: extraColumns)
        return root
    }

    // MARK: - Database

    private static func buildDatabase(at url: URL, userVersion: Int, extraColumns: Bool, textDates: Bool) throws {
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            let booksExtra = extraColumns
                ? "pages INTEGER,\n                    cover BLOB,"
                : ""
            try db.execute(sql: """
                CREATE TABLE books ( id INTEGER PRIMARY KEY AUTOINCREMENT,
                    title TEXT NOT NULL DEFAULT 'Unknown' COLLATE NOCASE,
                    sort TEXT COLLATE NOCASE,
                    timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                    pubdate TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                    series_index REAL NOT NULL DEFAULT 1.0,
                    author_sort TEXT COLLATE NOCASE,
                    isbn TEXT DEFAULT '' COLLATE NOCASE,
                    lccn TEXT DEFAULT '' COLLATE NOCASE,
                    path TEXT NOT NULL DEFAULT '',
                    flags INTEGER NOT NULL DEFAULT 1,
                    uuid TEXT,
                    has_cover BOOL DEFAULT 0,
                    \(booksExtra)
                    last_modified TIMESTAMP NOT NULL DEFAULT '2000-01-01 00:00:00+00:00');
                CREATE TABLE authors ( id INTEGER PRIMARY KEY AUTOINCREMENT,
                    name TEXT NOT NULL COLLATE NOCASE, sort TEXT COLLATE NOCASE,
                    link TEXT NOT NULL DEFAULT '', UNIQUE(name));
                CREATE TABLE books_authors_link ( id INTEGER PRIMARY KEY,
                    book INTEGER NOT NULL, author INTEGER NOT NULL, UNIQUE(book, author));
                CREATE TABLE series ( id INTEGER PRIMARY KEY AUTOINCREMENT,
                    name TEXT NOT NULL COLLATE NOCASE, sort TEXT COLLATE NOCASE, UNIQUE(name));
                CREATE TABLE books_series_link ( id INTEGER PRIMARY KEY,
                    book INTEGER NOT NULL, series INTEGER NOT NULL, UNIQUE(book));
                CREATE TABLE tags ( id INTEGER PRIMARY KEY AUTOINCREMENT,
                    name TEXT NOT NULL COLLATE NOCASE, UNIQUE(name));
                CREATE TABLE books_tags_link ( id INTEGER PRIMARY KEY,
                    book INTEGER NOT NULL, tag INTEGER NOT NULL, UNIQUE(book, tag));
                CREATE TABLE ratings ( id INTEGER PRIMARY KEY AUTOINCREMENT,
                    rating INTEGER CHECK(rating > -1 AND rating < 11), UNIQUE(rating));
                CREATE TABLE books_ratings_link ( id INTEGER PRIMARY KEY,
                    book INTEGER NOT NULL, rating INTEGER NOT NULL, UNIQUE(book, rating));
                CREATE TABLE publishers ( id INTEGER PRIMARY KEY AUTOINCREMENT,
                    name TEXT NOT NULL COLLATE NOCASE, sort TEXT COLLATE NOCASE, UNIQUE(name));
                CREATE TABLE books_publishers_link ( id INTEGER PRIMARY KEY,
                    book INTEGER NOT NULL, publisher INTEGER NOT NULL, UNIQUE(book));
                CREATE TABLE data ( id INTEGER PRIMARY KEY,
                    book INTEGER NOT NULL, format TEXT NOT NULL COLLATE NOCASE,
                    uncompressed_size INTEGER NOT NULL, name TEXT NOT NULL, UNIQUE(book, format));
                CREATE TABLE comments ( id INTEGER PRIMARY KEY,
                    book INTEGER NOT NULL, text TEXT NOT NULL COLLATE NOCASE, UNIQUE(book));
                CREATE TABLE identifiers ( id INTEGER PRIMARY KEY,
                    book INTEGER NOT NULL, type TEXT NOT NULL DEFAULT 'isbn' COLLATE NOCASE,
                    val TEXT NOT NULL COLLATE NOCASE, UNIQUE(book, type));
                CREATE TABLE languages ( id INTEGER PRIMARY KEY AUTOINCREMENT,
                    lang_code TEXT NOT NULL COLLATE NOCASE, UNIQUE(lang_code));
                CREATE TABLE books_languages_link ( id INTEGER PRIMARY KEY,
                    book INTEGER NOT NULL, lang_code INTEGER NOT NULL,
                    item_order INTEGER NOT NULL DEFAULT 0, UNIQUE(book, lang_code));
                CREATE TABLE custom_columns (
                    id INTEGER PRIMARY KEY AUTOINCREMENT, label TEXT NOT NULL,
                    name TEXT NOT NULL, datatype TEXT NOT NULL,
                    mark_for_delete BOOL DEFAULT 0 NOT NULL, editable BOOL DEFAULT 1 NOT NULL,
                    display TEXT DEFAULT '{}' NOT NULL, is_multiple BOOL DEFAULT 0 NOT NULL,
                    normalized BOOL NOT NULL, UNIQUE(label));
                CREATE TABLE custom_column_1 ( id INTEGER PRIMARY KEY,
                    book INTEGER NOT NULL, value TEXT);
                CREATE TABLE custom_column_3 ( id INTEGER PRIMARY KEY,
                    book INTEGER NOT NULL, value INTEGER);
                CREATE TABLE books_custom_column_2_link ( id INTEGER PRIMARY KEY,
                    book INTEGER NOT NULL, value TEXT, extra TEXT);
                CREATE TABLE library_id ( id INTEGER PRIMARY KEY, uuid TEXT NOT NULL, UNIQUE(uuid));
                CREATE TABLE annotations ( id INTEGER PRIMARY KEY,
                    book INTEGER NOT NULL, format TEXT NOT NULL COLLATE NOCASE,
                    user_type TEXT NOT NULL, user TEXT NOT NULL, timestamp REAL NOT NULL,
                    annot_id TEXT NOT NULL, annot_type TEXT NOT NULL, annot_data TEXT NOT NULL,
                    searchable_text TEXT NOT NULL DEFAULT '');
                CREATE TABLE last_read_positions ( id INTEGER PRIMARY KEY,
                    book INTEGER NOT NULL, format TEXT NOT NULL COLLATE NOCASE,
                    user TEXT NOT NULL, device TEXT NOT NULL, cfi TEXT NOT NULL,
                    epoch REAL NOT NULL, pos_frac REAL NOT NULL DEFAULT 0);
                """)

            try db.execute(sql: "PRAGMA user_version = \(userVersion)")
            try db.execute(sql: "INSERT INTO library_id(uuid) VALUES (?)", arguments: ["acceptance-fixture-uuid"])

            // Custom column definitions (the value tables are populated per book).
            try db.execute(
                sql: """
                    INSERT INTO custom_columns(id, label, name, datatype, mark_for_delete,
                        editable, display, is_multiple, normalized)
                    VALUES
                        (1, 'genre', 'Genre', 'text', 0, 1, '{}', 0, 0),
                        (2, 'shelves', 'Shelves', 'text', 0, 1, '{}', 1, 0),
                        (3, 'priority', 'Priority', 'int', 0, 1, '{}', 0, 0)
                    """
            )

            for spec in specs(extraColumns: extraColumns) {
                try insert(spec, db: db, textDates: textDates)
            }
        }
        try queue.close()
    }

    private static func insert(_ spec: BookSpec, db: Database, textDates: Bool) throws {
        let pubdate = spec.pubdate.map { textDates ? isoText($0, fractional: false) : "\(julian($0))" } ?? "0"
        let timestamp = spec.addedDate.map { textDates ? isoText($0, fractional: true) : "\(julian($0))" } ?? "0"
        try db.execute(
            sql: """
                INSERT INTO books(id, title, sort, timestamp, pubdate, series_index,
                    author_sort, lccn, path, uuid, has_cover, last_modified)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                spec.id, spec.title, spec.sort, timestamp, pubdate, spec.series?.index ?? 1.0,
                spec.authorSort, spec.lccn ?? "", spec.path, "uuid-\(spec.id)",
                spec.hasCoverFile ? 1 : 0, "2000-01-01 00:00:00+00:00",
            ]
        )
        // Schema-variant columns live only in the extra-columns DDL.
        if let blob = spec.coverBlob {
            try db.execute(
                sql: "UPDATE books SET cover = ? WHERE id = ?",
                arguments: [blob, spec.id]
            )
        }
        if let pages = spec.pages {
            try db.execute(
                sql: "UPDATE books SET pages = ? WHERE id = ?",
                arguments: [pages, spec.id]
            )
        }

        for author in spec.authors {
            try db.execute(
                sql: "INSERT OR IGNORE INTO authors(name, sort) VALUES (?, ?)",
                arguments: [author.name, author.sort]
            )
            let authorID = try Int.fetchOne(
                db, sql: "SELECT id FROM authors WHERE name = ?", arguments: [author.name]
            )!
            try db.execute(
                sql: "INSERT INTO books_authors_link(book, author) VALUES (?, ?)",
                arguments: [spec.id, authorID]
            )
        }

        if let series = spec.series {
            try db.execute(sql: "INSERT OR IGNORE INTO series(name) VALUES (?)", arguments: [series.name])
            let seriesID = try Int.fetchOne(
                db, sql: "SELECT id FROM series WHERE name = ?", arguments: [series.name]
            )!
            try db.execute(
                sql: "INSERT INTO books_series_link(book, series) VALUES (?, ?)",
                arguments: [spec.id, seriesID]
            )
        }
        for tag in spec.tags {
            try db.execute(sql: "INSERT OR IGNORE INTO tags(name) VALUES (?)", arguments: [tag])
            let tagID = try Int.fetchOne(
                db, sql: "SELECT id FROM tags WHERE name = ?", arguments: [tag]
            )!
            try db.execute(
                sql: "INSERT INTO books_tags_link(book, tag) VALUES (?, ?)",
                arguments: [spec.id, tagID]
            )
        }
        if let rating = spec.rating {
            try db.execute(sql: "INSERT OR IGNORE INTO ratings(rating) VALUES (?)", arguments: [rating])
            let ratingID = try Int.fetchOne(
                db, sql: "SELECT id FROM ratings WHERE rating = ?", arguments: [rating]
            )!
            try db.execute(
                sql: "INSERT INTO books_ratings_link(book, rating) VALUES (?, ?)",
                arguments: [spec.id, ratingID]
            )
        }
        if let publisher = spec.publisher {
            try db.execute(sql: "INSERT OR IGNORE INTO publishers(name) VALUES (?)", arguments: [publisher])
            let publisherID = try Int.fetchOne(
                db, sql: "SELECT id FROM publishers WHERE name = ?", arguments: [publisher]
            )!
            try db.execute(
                sql: "INSERT INTO books_publishers_link(book, publisher) VALUES (?, ?)",
                arguments: [spec.id, publisherID]
            )
        }
        for (index, code) in spec.languages.enumerated() {
            try db.execute(sql: "INSERT OR IGNORE INTO languages(lang_code) VALUES (?)", arguments: [code])
            let langID = try Int.fetchOne(
                db, sql: "SELECT id FROM languages WHERE lang_code = ?", arguments: [code]
            )!
            try db.execute(
                sql: "INSERT INTO books_languages_link(book, lang_code, item_order) VALUES (?, ?, ?)",
                arguments: [spec.id, langID, index]
            )
        }
        for (type, value) in spec.identifiers {
            try db.execute(
                sql: "INSERT INTO identifiers(book, type, val) VALUES (?, ?, ?)",
                arguments: [spec.id, type, value]
            )
        }
        if let comments = spec.comments {
            try db.execute(
                sql: "INSERT INTO comments(book, text) VALUES (?, ?)",
                arguments: [spec.id, comments]
            )
        }
        for format in spec.formats {
            try db.execute(
                sql: """
                    INSERT INTO data(book, format, uncompressed_size, name) VALUES (?, ?, ?, ?)
                    """,
                arguments: [spec.id, format.format, format.size, format.name]
            )
        }
        if let genre = spec.genre {
            try db.execute(
                sql: "INSERT INTO custom_column_1(book, value) VALUES (?, ?)",
                arguments: [spec.id, genre]
            )
        }
        if let shelves = spec.shelves {
            for shelf in shelves {
                try db.execute(
                    sql: "INSERT INTO books_custom_column_2_link(book, value, extra) VALUES (?, ?, ?)",
                    arguments: [spec.id, shelf, ""]
                )
            }
        }
        if let priority = spec.priority {
            if priority == priority.rounded() {
                try db.execute(
                    sql: "INSERT INTO custom_column_3(book, value) VALUES (?, ?)",
                    arguments: [spec.id, Int64(priority)]
                )
            } else {
                try db.execute(
                    sql: "INSERT INTO custom_column_3(book, value) VALUES (?, ?)",
                    arguments: [spec.id, priority]
                )
            }
        }
        if spec.annotations {
            try db.execute(
                sql: """
                    INSERT INTO annotations(book, format, user_type, user, timestamp,
                        annot_id, annot_type, annot_data, searchable_text)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    spec.id, "EPUB", "highlight", "reader@example.com", julian(.now),
                    "ann-\(spec.id)", "highlight", #"{"type":"text","value":"important"}"#,
                    "important passage",
                ]
            )
        }
        if spec.lastRead {
            try db.execute(
                sql: """
                    INSERT INTO last_read_positions(book, format, user, device, cfi, epoch, pos_frac)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    spec.id, "EPUB", "reader@example.com", "kindle",
                    "/6/2[chap]!/4/2", 1_700_000_000.0, 0.5,
                ]
            )
        }
    }

    // MARK: - Book folders

    private static func writeBookFolders(at root: URL, extraColumns: Bool) throws {
        for spec in specs(extraColumns: extraColumns) {
            let folder = root.appending(path: spec.path, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

            for format in spec.formats where format.writeFile {
                let bytes = Data(repeating: 0xAB, count: Int(format.size))
                try bytes.write(to: folder.appending(path: "\(format.name).\(format.format.lowercased())"))
            }
            if spec.hasCoverFile {
                try coverBytes.write(to: folder.appending(path: "cover.jpg"))
            }
            let opf = opfXML(spec: spec)
            try opf.write(to: folder.appending(path: "metadata.opf"), options: .atomic)
        }
    }

    private static func opfXML(spec: BookSpec) -> Data {
        let title = spec.opfTitle ?? spec.title
        let creators = spec.opfCreators ?? spec.authors.map(\.name)
        let creatorTags = creators
            .map { "<dc:creator opf:role=\"aut\">\($0)</dc:creator>" }
            .joined(separator: "\n")
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/" version="2.0" unique-identifier="uid">
        <metadata>
        <dc:title>\(title)</dc:title>
        \(creatorTags)
        </metadata>
        </package>
        """
        return Data(xml.utf8)
    }

    // MARK: - Book specs

    private struct BookSpec {
        let id: Int
        let title: String
        let sort: String
        let authorSort: String
        let path: String
        let authors: [(name: String, sort: String)]
        let series: (name: String, index: Double)?
        let tags: [String]
        let rating: Int?
        let publisher: String?
        let pubdate: Date?
        let addedDate: Date?
        let languages: [String]
        let identifiers: [String: String]
        let comments: String?
        let formats: [(format: String, name: String, size: Int64, writeFile: Bool)]
        let hasCoverFile: Bool
        let coverBlob: Data?
        let pages: Int?
        let lccn: String?
        let genre: String?
        let shelves: [String]?
        let priority: Double?
        let annotations: Bool
        let lastRead: Bool
        let opfTitle: String?
        let opfCreators: [String]?
    }

    private static func specs(extraColumns: Bool) -> [BookSpec] {
        let base: [BookSpec] = [
            BookSpec(
                id: 1,
                title: "Range: Why Generalists Triumph in a Specialized World",
                sort: "Range: Why Generalists Triumph in a Specialized World",
                authorSort: "Epstein, David",
                path: "David Epstein/Range (1)",
                authors: [
                    (name: "David Epstein", sort: "Epstein, David"),
                    (name: "Peter Brown", sort: "Brown, Peter"),
                ],
                series: (name: "Studies", index: 1.5),
                tags: ["Science", "Sport"],
                rating: 8,
                publisher: "Riverhead",
                pubdate: Date(timeIntervalSince1970: 1_559_001_600), // 2019-05-28 00:00 UTC
                addedDate: Date(timeIntervalSince1970: 1_705_276_800), // 2024-01-15 00:00 UTC
                languages: ["eng", "fra"],
                identifiers: ["isbn": "978-0-7352-2129-1", "google": "abcd1234", "asin": "B07VWM1Z2B"],
                comments: "<p>Great book</p>",
                formats: [
                    (format: "EPUB", name: "Range - David Epstein", size: 1_000, writeFile: true),
                    (format: "PDF", name: "Range - David Epstein", size: 2_000, writeFile: true),
                ],
                hasCoverFile: !extraColumns,
                coverBlob: extraColumns ? Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]) : nil,
                pages: extraColumns ? 320 : nil,
                lccn: "2018049465",
                genre: "science",
                shelves: ["read", "favorites"],
                priority: 3,
                annotations: true,
                lastRead: true,
                opfTitle: nil,
                opfCreators: nil
            ),
            BookSpec(
                id: 2,
                title: "Talent",
                sort: "Talent",
                authorSort: "Coyle, Daniel",
                path: "Daniel Coyle/Talent (2)",
                authors: [(name: "Daniel Coyle", sort: "Coyle, Daniel")],
                series: (name: "Studies", index: 2.0),
                tags: ["Sport"],
                rating: 10,
                publisher: "Bantam",
                pubdate: date(2009, 4, 16),
                addedDate: date(2024, 2, 1),
                languages: ["eng"],
                identifiers: ["isbn": "9780553806849"],
                comments: "Second book.",
                formats: [(format: "EPUB", name: "Talent", size: 1_500, writeFile: true)],
                hasCoverFile: true,
                coverBlob: nil,
                pages: nil,
                lccn: nil,
                genre: nil,
                shelves: nil,
                priority: nil,
                annotations: false,
                lastRead: false,
                opfTitle: nil,
                opfCreators: nil
            ),
            BookSpec(
                id: 3,
                title: "Deep Work",
                sort: "Deep Work",
                authorSort: "Newport, Cal",
                path: "Cal Newport/Deep Work (3)",
                authors: [(name: "Cal Newport", sort: "Newport, Cal")],
                series: nil,
                tags: [],
                rating: nil,
                publisher: "Grand Central",
                pubdate: date(2016, 1, 5),
                addedDate: date(2024, 3, 10),
                languages: ["eng"],
                identifiers: [:],
                comments: "",
                formats: [(format: "PDF", name: "Deep Work", size: 3_000, writeFile: true)],
                hasCoverFile: false,
                coverBlob: nil,
                pages: nil,
                lccn: nil,
                genre: nil,
                shelves: nil,
                priority: 2.5,
                annotations: false,
                lastRead: false,
                opfTitle: nil,
                opfCreators: nil
            ),
            BookSpec(
                id: 4,
                title: "Solo",
                sort: "Solo",
                authorSort: "Walker, Alice",
                path: "Alice Walker/Solo (4)",
                authors: [(name: "Alice Walker", sort: "Walker, Alice")],
                series: nil,
                tags: ["Fiction"],
                rating: 4,
                publisher: nil,
                pubdate: nil,
                addedDate: date(2024, 4, 1),
                languages: [],
                identifiers: [:],
                comments: nil,
                formats: [(format: "EPUB", name: "Solo", size: 800, writeFile: true)],
                hasCoverFile: false,
                coverBlob: nil,
                pages: nil,
                lccn: nil,
                genre: nil,
                shelves: nil,
                priority: nil,
                annotations: false,
                lastRead: false,
                opfTitle: nil,
                opfCreators: nil
            ),
            // OPF cross-check fallback: empty DB title/authors, OPF carries them.
            BookSpec(
                id: 5,
                title: "",
                sort: "",
                authorSort: "",
                path: "Unknown Author/Unknown (5)",
                authors: [],
                series: nil,
                tags: [],
                rating: nil,
                publisher: nil,
                pubdate: nil,
                addedDate: date(2024, 5, 5),
                languages: [],
                identifiers: [:],
                comments: nil,
                formats: [],
                hasCoverFile: false,
                coverBlob: nil,
                pages: nil,
                lccn: nil,
                genre: nil,
                shelves: nil,
                priority: nil,
                annotations: false,
                lastRead: false,
                opfTitle: "Fallback Title",
                opfCreators: ["Fallback Author"]
            ),
            // Missing format file: the data row exists, the file does not.
            BookSpec(
                id: 6,
                title: "Ghost Format",
                sort: "Ghost Format",
                authorSort: "Writer, Ghost",
                path: "Ghost Writer/Ghost (6)",
                authors: [(name: "Ghost Writer", sort: "Writer, Ghost")],
                series: nil,
                tags: [],
                rating: nil,
                publisher: nil,
                pubdate: nil,
                addedDate: date(2024, 6, 6),
                languages: [],
                identifiers: [:],
                comments: nil,
                formats: [(format: "EPUB", name: "Ghost", size: 999, writeFile: false)],
                hasCoverFile: false,
                coverBlob: nil,
                pages: nil,
                lccn: nil,
                genre: nil,
                shelves: nil,
                priority: nil,
                annotations: false,
                lastRead: false,
                opfTitle: nil,
                opfCreators: nil
            ),
            BookSpec(
                id: 7,
                title: "Empty Shelf",
                sort: "Empty Shelf",
                authorSort: "Seven, Author",
                path: "Author Seven/Empty Shelf (7)",
                authors: [(name: "Author Seven", sort: "Seven, Author")],
                series: nil,
                tags: [],
                rating: nil,
                publisher: nil,
                pubdate: nil,
                addedDate: date(2024, 7, 7),
                languages: [],
                identifiers: [:],
                comments: nil,
                formats: [],
                hasCoverFile: false,
                coverBlob: nil,
                pages: nil,
                lccn: nil,
                genre: nil,
                shelves: nil,
                priority: nil,
                annotations: false,
                lastRead: false,
                opfTitle: nil,
                opfCreators: nil
            ),
            BookSpec(
                id: 8,
                title: "Cover File Book",
                sort: "Cover File Book",
                authorSort: "Eight, Author",
                path: "Author Eight/Cover File Book (8)",
                authors: [(name: "Author Eight", sort: "Eight, Author")],
                series: nil,
                tags: [],
                rating: nil,
                publisher: nil,
                pubdate: nil,
                addedDate: date(2024, 8, 8),
                languages: [],
                identifiers: [:],
                comments: nil,
                formats: [(format: "EPUB", name: "Covered", size: 700, writeFile: true)],
                hasCoverFile: true,
                coverBlob: nil,
                pages: nil,
                lccn: nil,
                genre: nil,
                shelves: nil,
                priority: nil,
                annotations: false,
                lastRead: false,
                opfTitle: nil,
                opfCreators: nil
            ),
            BookSpec(
                id: 9,
                title: "Ninth",
                sort: "Ninth",
                authorSort: "Author, Ninth",
                path: "Ninth Author/Ninth (9)",
                authors: [(name: "Ninth Author", sort: "Author, Ninth")],
                series: nil,
                tags: [],
                rating: nil,
                publisher: nil,
                pubdate: nil,
                addedDate: date(2024, 9, 9),
                languages: [],
                identifiers: [:],
                comments: nil,
                formats: [(format: "EPUB", name: "Ninth", size: 600, writeFile: true)],
                hasCoverFile: false,
                coverBlob: nil,
                pages: nil,
                lccn: nil,
                genre: "mystery",
                shelves: nil,
                priority: nil,
                annotations: false,
                lastRead: false,
                opfTitle: nil,
                opfCreators: nil
            ),
            BookSpec(
                id: 10,
                title: "Tenth",
                sort: "Tenth",
                authorSort: "Author, Tenth",
                path: "Tenth Author/Tenth (10)",
                authors: [(name: "Tenth Author", sort: "Author, Tenth")],
                series: nil,
                tags: [],
                rating: nil,
                publisher: nil,
                pubdate: nil,
                addedDate: date(2024, 10, 10),
                languages: [],
                identifiers: [:],
                comments: nil,
                formats: [(format: "EPUB", name: "Tenth", size: 500, writeFile: true)],
                hasCoverFile: false,
                coverBlob: nil,
                pages: nil,
                lccn: nil,
                genre: nil,
                shelves: nil,
                priority: nil,
                annotations: false,
                lastRead: false,
                opfTitle: nil,
                opfCreators: nil
            ),
            BookSpec(
                id: 11,
                title: "Eleventh",
                sort: "Eleventh",
                authorSort: "Author, Eleventh",
                path: "Eleventh Author/Eleventh (11)",
                authors: [(name: "Eleventh Author", sort: "Author, Eleventh")],
                series: nil,
                tags: [],
                rating: nil,
                publisher: nil,
                pubdate: nil,
                addedDate: date(2024, 11, 11),
                languages: [],
                identifiers: [:],
                comments: nil,
                formats: [(format: "EPUB", name: "Eleventh", size: 400, writeFile: true)],
                hasCoverFile: false,
                coverBlob: nil,
                pages: nil,
                lccn: nil,
                genre: nil,
                shelves: nil,
                priority: nil,
                annotations: false,
                lastRead: false,
                opfTitle: nil,
                opfCreators: nil
            ),
            BookSpec(
                id: 12,
                title: "Twelfth",
                sort: "Twelfth",
                authorSort: "Author, Twelfth",
                path: "Twelfth Author/Twelfth (12)",
                authors: [(name: "Twelfth Author", sort: "Author, Twelfth")],
                series: nil,
                tags: [],
                rating: nil,
                publisher: nil,
                pubdate: nil,
                addedDate: date(2024, 12, 12),
                languages: [],
                identifiers: [:],
                comments: nil,
                formats: [],
                hasCoverFile: false,
                coverBlob: nil,
                pages: nil,
                lccn: nil,
                genre: nil,
                shelves: nil,
                priority: nil,
                annotations: false,
                lastRead: false,
                opfTitle: nil,
                opfCreators: nil
            ),
            BookSpec(
                id: 13,
                title: "Thirteenth",
                sort: "Thirteenth",
                authorSort: "Author, Thirteenth",
                path: "Thirteenth Author/Thirteenth (13)",
                authors: [(name: "Thirteenth Author", sort: "Author, Thirteenth")],
                series: nil,
                tags: [],
                rating: nil,
                publisher: nil,
                pubdate: nil,
                addedDate: date(2024, 12, 31),
                languages: [],
                identifiers: [:],
                comments: nil,
                formats: [],
                hasCoverFile: false,
                coverBlob: nil,
                pages: nil,
                lccn: nil,
                genre: nil,
                shelves: nil,
                priority: nil,
                annotations: false,
                lastRead: false,
                opfTitle: nil,
                opfCreators: nil
            ),
        ]
        return base
    }

    // MARK: - Helpers

    static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(identifier: "UTC")
        components.year = year
        components.month = month
        components.day = day
        return components.date!
    }

    static func julian(_ date: Date) -> Double {
        date.timeIntervalSince1970 / 86_400 + 2_440_587.5
    }

    /// Calibre-Web-style ISO-8601 text dates ("2019-05-28 00:00:00+00:00",
    /// optionally with a 6-digit fractional second), UTC. The `TIMESTAMP`
    /// columns' NUMERIC affinity leaves these as TEXT (they do not look
    /// numeric), which is exactly the shape that crashed the reader.
    private static func isoText(_ date: Date, fractional: Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = fractional
            ? "yyyy-MM-dd HH:mm:ss.SSSSSSZZZZZ"
            : "yyyy-MM-dd HH:mm:ssZZZZZ"
        return formatter.string(from: date)
    }

    private static let coverBytes = Data([
        0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01,
    ])
}
