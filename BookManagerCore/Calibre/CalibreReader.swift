import Foundation
import GRDB

/// Per-book lookup tables shared across one `books()` pass.
private struct BookLookups {
    var authors: [Int: [CalibreAuthor]] = [:]
    var series: [Int: String] = [:]
    var tags: [Int: [String]] = [:]
    var ratings: [Int: Int] = [:]
    var publishers: [Int: String] = [:]
    var languages: [Int: [String]] = [:]
    var identifiers: [Int: [String: String]] = [:]
    var comments: [Int: String] = [:]
    var formats: [Int: [CalibreFormatEntry]] = [:]
    var annotations: [Int: String] = [:]
    var lastRead: [Int: String] = [:]
    var raw: [Int: [String: String]] = [:]
}

/// A raw `data`-table format row before URL resolution.
private struct CalibreFormatEntry {
    var format: String
    var name: String
    var size: Int64
    var path: String?
}

/// Read-only access to a Calibre library (`metadata.db`, schema user_version 26).
/// The source library is never modified — the database is never even opened
/// with SQLite in place: `open` snapshots `metadata.db` (and its `-wal` sidecar
/// when present) into a disposable directory under the app's own temp space and
/// opens the copy. This sidesteps the SQLite rule that read-only WAL opens need
/// a writable `-shm`/directory (Calibre's `metadata.db` is WAL journal mode),
/// which macOS 26+ TCC additionally denies on foreign databases as
/// SQLITE_AUTH ("SQLite error 23: authorization denied"). All file access to
/// the source library beyond the snapshot is plain reads.
public final class CalibreReader: Sendable {
    /// The library folder root (the directory containing `metadata.db`).
    public let libraryURL: URL
    private let database: DatabaseQueue
    private let snapshotDirectory: URL?
    private let schema: any CalibreSchemaAdapting

    private init(
        libraryURL: URL,
        database: DatabaseQueue,
        snapshotDirectory: URL?,
        schema: any CalibreSchemaAdapting
    ) {
        self.libraryURL = libraryURL
        self.database = database
        self.snapshotDirectory = snapshotDirectory
        self.schema = schema
    }

    /// Opens the Calibre library at `libraryURL` (either the library folder
    /// containing `metadata.db`, or the `metadata.db` file itself), validates
    /// the schema version, and returns a reader. Throws
    /// `CalibreReaderError.missingMetadataDatabase` when no database is found,
    /// `unsupportedSchemaVersion` for an unknown version, and
    /// `notACalibreLibrary` when the database has no books table.
    public static func open(libraryURL: URL) throws -> CalibreReader {
        let databaseURL: URL
        if libraryURL.lastPathComponent == "metadata.db" {
            databaseURL = libraryURL
        } else {
            databaseURL = libraryURL.appending(path: "metadata.db")
        }
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw CalibreReaderError.missingMetadataDatabase(databaseURL)
        }

        // Snapshot the source into our own writable temp directory (see the
        // type doc comment). The copy includes the -wal sidecar so committed
        // but uncheckpointed rows are not lost.
        let snapshotDirectory = FileManager.default.temporaryDirectory
            .appending(path: "calibre-snapshot-\(UUID().uuidString)", directoryHint: .isDirectory)
        let snapshotURL = snapshotDirectory.appending(path: "metadata.db")
        do {
            try FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: databaseURL, to: snapshotURL)
            let sourceWAL = URL(fileURLWithPath: databaseURL.path + "-wal")
            if FileManager.default.fileExists(atPath: sourceWAL.path) {
                try FileManager.default.copyItem(
                    at: sourceWAL,
                    to: URL(fileURLWithPath: snapshotURL.path + "-wal")
                )
            }
        } catch {
            try? FileManager.default.removeItem(at: snapshotDirectory)
            throw error
        }

        // Open the copy read-write so SQLite can build/recover the WAL index
        // inside our own directory. The copy is disposable; the source is
        // never opened by SQLite at all.
        let queue: DatabaseQueue
        do {
            queue = try DatabaseQueue(path: snapshotURL.path)
        } catch {
            try? FileManager.default.removeItem(at: snapshotDirectory)
            throw error
        }

        let schema = CalibreSchema26()
        do {
            try queue.read { db in
                try schema.validate(db, libraryURL: databaseURL.deletingLastPathComponent())
            }
        } catch {
            try? queue.close()
            try? FileManager.default.removeItem(at: snapshotDirectory)
            throw error
        }
        return CalibreReader(
            libraryURL: databaseURL.deletingLastPathComponent(),
            database: queue,
            snapshotDirectory: snapshotDirectory,
            schema: schema
        )
    }

    public func close() throws {
        defer {
            if let snapshotDirectory {
                try? FileManager.default.removeItem(at: snapshotDirectory)
            }
        }
        try database.close()
    }

    public func summary() throws -> CalibreLibrarySummary {
        try database.read { db in
            let books = try schema.fetchBooks(db)
            return CalibreLibrarySummary(
                userVersion: try schema.userVersion(db),
                libraryID: try schema.libraryID(db),
                bookCount: books.count,
                formatCount: try schema.formatCount(db),
                titles: books.map { $0["title"] as String? ?? "" }
            )
        }
    }

    public func books() throws -> [CalibreBookRecord] {
        try database.read { db in
            let bookRows = try schema.fetchBooks(db)
            let lookups = try makeLookups(db: db)
            let bookColumns = try schema.columns(in: "books", db)
            let dataColumns = try schema.columns(in: "data", db)
            return try bookRows.map { row in
                try record(from: row, lookups: lookups, bookColumns: bookColumns, dataColumns: dataColumns)
            }
        }
    }

    /// All per-book lookup tables needed to assemble records, fetched once per
    /// `books()` call (batched, not N+1 per book).
    private func makeLookups(db: Database) throws -> BookLookups {
        var lookups = BookLookups()
        for entry in try schema.fetchAuthors(db) {
            lookups.authors[entry.book, default: []].append(
                CalibreAuthor(name: entry.name, sort: entry.sort)
            )
        }
        for entry in try schema.fetchSeries(db) {
            lookups.series[entry.book] = entry.name
        }
        for entry in try schema.fetchTags(db) {
            lookups.tags[entry.book, default: []].append(entry.name)
        }
        for entry in try schema.fetchRatings(db) {
            lookups.ratings[entry.book] = entry.rating
        }
        for entry in try schema.fetchPublishers(db) {
            lookups.publishers[entry.book] = entry.name
        }
        for entry in try schema.fetchLanguages(db) {
            lookups.languages[entry.book, default: []].append(entry.code)
        }
        for entry in try schema.fetchIdentifiers(db) {
            let type = entry.type.lowercased()
            if lookups.identifiers[entry.book]?[type] == nil {
                lookups.identifiers[entry.book, default: [:]][type] = entry.value
            }
        }
        for entry in try schema.fetchComments(db) {
            lookups.comments[entry.book] = entry.text
        }
        for entry in try schema.fetchFormats(db) {
            lookups.formats[entry.book, default: []].append(
                CalibreFormatEntry(format: entry.format, name: entry.name, size: entry.size, path: entry.path)
            )
        }
        for entry in try schema.fetchAnnotations(db) {
            lookups.annotations[entry.book] = entry.payload
        }
        for entry in try schema.fetchLastReadPositions(db) {
            lookups.lastRead[entry.book] = entry.payload
        }
        let customColumns = try schema.customColumns(db)
        for column in customColumns {
            let values = try schema.fetchCustomValues(db, column: column)
            if column.isMultiple {
                var grouped: [Int: [String]] = [:]
                for entry in values where entry.value != nil {
                    grouped[entry.book, default: []].append(entry.value!)
                }
                let encoder = JSONEncoder()
                for (book, items) in grouped {
                    lookups.raw[book, default: [:]][column.key] =
                        String(decoding: try encoder.encode(items), as: UTF8.self)
                }
            } else {
                for entry in values {
                    guard let value = entry.value, !value.isEmpty else { continue }
                    lookups.raw[entry.book, default: [:]][column.key] = value
                }
            }
        }
        return lookups
    }

    /// Assembles one `CalibreBookRecord` from a `books` row plus the shared
    /// lookup tables. OPF cross-check fills empty title/authors only; the DB
    /// stays authoritative.
    private func record(
        from row: Row,
        lookups: BookLookups,
        bookColumns: Set<String>,
        dataColumns: Set<String>
    ) throws -> CalibreBookRecord {
        let id = row["id"] as Int
        let bookPath = row["path"] as String? ?? ""
        var title = row["title"] as String? ?? ""
        var authors = lookups.authors[id] ?? []

        var opfPath: String?
        let opfURL = bookFolderURL(bookPath: bookPath).appending(path: "metadata.opf")
        if FileManager.default.fileExists(atPath: opfURL.path) {
            opfPath = "metadata.opf"
            if title.isEmpty || authors.isEmpty,
               let opf = try? CalibreOPFParser.parse(fileURL: opfURL) {
                if title.isEmpty, let opfTitle = opf.title, !opfTitle.isEmpty {
                    title = opfTitle
                }
                if authors.isEmpty {
                    authors = opf.creators.map { CalibreAuthor(name: $0, sort: $0) }
                }
            }
        }

        let formats: [CalibreFormatRecord] = (lookups.formats[id] ?? []).map { entry in
            let folder: String
            if dataColumns.contains("path"), let override = entry.path, !override.isEmpty {
                folder = override
            } else {
                folder = bookPath
            }
            let filename = "\(entry.name).\(entry.format.lowercased())"
            let url = bookFolderURL(bookPath: folder).appending(path: filename)
            return CalibreFormatRecord(
                format: entry.format,
                name: entry.name,
                sourceURL: url,
                size: entry.size
            )
        }

        var cover: CalibreCover?
        if bookColumns.contains("cover"),
           let blob = row["cover"] as Data?, !blob.isEmpty {
            cover = .blob(blob)
        } else if (row["has_cover"] as Bool? ?? false) {
            let coverURL = bookFolderURL(bookPath: bookPath).appending(path: "cover.jpg")
            if FileManager.default.fileExists(atPath: coverURL.path) {
                cover = .file(coverURL)
            }
        }

        var raw = lookups.raw[id] ?? [:]
        if bookColumns.contains("lccn"), let lccn = row["lccn"] as String?, !lccn.isEmpty {
            raw["calibre.lccn"] = lccn
        }
        if bookColumns.contains("pages"), let pages = row["pages"] as Int? {
            raw["calibre.pages"] = "\(pages)"
        }
        if let annotations = lookups.annotations[id] {
            raw["calibre.annotations"] = annotations
        }
        if let lastRead = lookups.lastRead[id] {
            raw["calibre.lastReadPositions"] = lastRead
        }

        let seriesIndexValue: Double?
        if lookups.series[id] != nil, let index = row["series_index"] as Double?, index != 0 {
            seriesIndexValue = index
        } else {
            seriesIndexValue = nil
        }
        let rating = lookups.ratings[id].flatMap { $0 > 0 ? $0 / 2 : nil }

        return CalibreBookRecord(
            calibreID: id,
            title: title,
            authors: authors,
            series: lookups.series[id],
            seriesIndex: seriesIndexValue,
            tags: lookups.tags[id] ?? [],
            rating: rating,
            publisher: lookups.publishers[id],
            publicationDate: Self.date(fromJulian: row["pubdate"] as Double?),
            addedDate: Self.date(fromJulian: row["timestamp"] as Double?),
            languages: lookups.languages[id] ?? [],
            identifiers: lookups.identifiers[id] ?? [:],
            comments: lookups.comments[id],
            formats: formats,
            cover: cover,
            rawMetadata: raw,
            opfPath: opfPath
        )
    }

    private func bookFolderURL(bookPath: String) -> URL {
        if bookPath.isEmpty {
            return libraryURL
        }
        return libraryURL.appending(path: bookPath, directoryHint: .isDirectory)
    }

    /// Calibre stores dates as Julian day numbers.
    static func date(fromJulian julian: Double?) -> Date? {
        guard let julian, julian > 0 else { return nil }
        return Date(timeIntervalSince1970: (julian - 2_440_587.5) * 86_400)
    }
}

/// Minimal OPF metadata parser used for the cross-check fallback (title and
/// creators only). Mirrors the pattern in `MetadataExtractor.OPFParser`.
final class CalibreOPFParser: NSObject, XMLParserDelegate {
    private var textBuffer = ""
    private var inMetadata = false
    private var currentElement: String?

    private(set) var title: String?
    private(set) var creators: [String] = []

    static func parse(fileURL: URL) throws -> CalibreOPFParser? {
        let data = try Data(contentsOf: fileURL)
        let parser = CalibreOPFParser()
        parser.parse(data: data)
        return (parser.title != nil || !parser.creators.isEmpty) ? parser : nil
    }

    func parse(data: Data) {
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = self
        xmlParser.shouldProcessNamespaces = true
        xmlParser.parse()
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName
        textBuffer = ""
        if elementName == "metadata" { inMetadata = true }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        textBuffer += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard inMetadata else { return }
        if elementName == "metadata" {
            inMetadata = false
            return
        }
        let value = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        switch elementName {
        case "title":
            if title == nil { title = value }
        case "creator":
            creators.append(value)
        default:
            break
        }
    }
}

extension CalibreCustomColumn {
    /// `calibre.custom.<label>` — the namespaced raw-payload key.
    var key: String { "calibre.custom.\(label)" }
}
