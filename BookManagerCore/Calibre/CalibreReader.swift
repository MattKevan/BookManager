import Foundation
import GRDB

/// Read-only access to a Calibre library (`metadata.db`, schema user_version 26).
/// The source library is never modified: the database is opened with
/// `Configuration.readonly = true` and all file access is plain reads.
public final class CalibreReader: Sendable {
    /// The library folder root (the directory containing `metadata.db`).
    public let libraryURL: URL
    private let database: DatabaseQueue
    private let schema: any CalibreSchemaAdapting

    private init(libraryURL: URL, database: DatabaseQueue, schema: any CalibreSchemaAdapting) {
        self.libraryURL = libraryURL
        self.database = database
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

        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: databaseURL.path, configuration: configuration)

        let schema = CalibreSchema26()
        do {
            try queue.read { db in
                try schema.validate(db, libraryURL: databaseURL.deletingLastPathComponent())
            }
        } catch {
            try? queue.close()
            throw error
        }
        return CalibreReader(
            libraryURL: databaseURL.deletingLastPathComponent(),
            database: queue,
            schema: schema
        )
    }

    public func close() throws {
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

            var authorsByBook: [Int: [CalibreAuthor]] = [:]
            for entry in try schema.fetchAuthors(db) {
                authorsByBook[entry.book, default: []].append(
                    CalibreAuthor(name: entry.name, sort: entry.sort)
                )
            }
            var seriesByBook: [Int: String] = [:]
            for entry in try schema.fetchSeries(db) {
                seriesByBook[entry.book] = entry.name
            }
            var tagsByBook: [Int: [String]] = [:]
            for entry in try schema.fetchTags(db) {
                tagsByBook[entry.book, default: []].append(entry.name)
            }
            var ratingsByBook: [Int: Int] = [:]
            for entry in try schema.fetchRatings(db) {
                ratingsByBook[entry.book] = entry.rating
            }
            var publisherByBook: [Int: String] = [:]
            for entry in try schema.fetchPublishers(db) {
                publisherByBook[entry.book] = entry.name
            }
            var languagesByBook: [Int: [String]] = [:]
            for entry in try schema.fetchLanguages(db) {
                languagesByBook[entry.book, default: []].append(entry.code)
            }
            var identifiersByBook: [Int: [String: String]] = [:]
            for entry in try schema.fetchIdentifiers(db) {
                let type = entry.type.lowercased()
                if identifiersByBook[entry.book]?[type] == nil {
                    identifiersByBook[entry.book, default: [:]][type] = entry.value
                }
            }
            var commentsByBook: [Int: String] = [:]
            for entry in try schema.fetchComments(db) {
                commentsByBook[entry.book] = entry.text
            }
            var formatsByBook: [Int: [(format: String, name: String, size: Int64, path: String?)]] = [:]
            for entry in try schema.fetchFormats(db) {
                formatsByBook[entry.book, default: []].append(
                    (format: entry.format, name: entry.name, size: entry.size, path: entry.path)
                )
            }
            var annotationsByBook: [Int: String] = [:]
            for entry in try schema.fetchAnnotations(db) {
                annotationsByBook[entry.book] = entry.payload
            }
            var lastReadByBook: [Int: String] = [:]
            for entry in try schema.fetchLastReadPositions(db) {
                lastReadByBook[entry.book] = entry.payload
            }

            var rawByBook: [Int: [String: String]] = [:]
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
                        rawByBook[book, default: [:]][column.key] =
                            String(decoding: try encoder.encode(items), as: UTF8.self)
                    }
                } else {
                    for entry in values {
                        guard let value = entry.value, !value.isEmpty else { continue }
                        rawByBook[entry.book, default: [:]][column.key] = value
                    }
                }
            }

            let bookColumns = try schema.columns(in: "books", db)
            let dataColumns = try schema.columns(in: "data", db)

            return try bookRows.map { row in
                let id = row["id"] as Int
                let bookPath = row["path"] as String? ?? ""
                var title = row["title"] as String? ?? ""
                var authors = authorsByBook[id] ?? []

                // OPF cross-check: the DB is authoritative; OPF fills empty
                // title/authors only (recoverable database inconsistency).
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

                let formats: [CalibreFormatRecord] = (formatsByBook[id] ?? []).map { entry in
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

                var raw = rawByBook[id] ?? [:]
                if bookColumns.contains("lccn"), let lccn = row["lccn"] as String?, !lccn.isEmpty {
                    raw["calibre.lccn"] = lccn
                }
                if bookColumns.contains("pages"), let pages = row["pages"] as Int? {
                    raw["calibre.pages"] = "\(pages)"
                }
                if let annotations = annotationsByBook[id] {
                    raw["calibre.annotations"] = annotations
                }
                if let lastRead = lastReadByBook[id] {
                    raw["calibre.lastReadPositions"] = lastRead
                }

                let seriesIndexValue: Double?
                if seriesByBook[id] != nil, let index = row["series_index"] as Double?, index != 0 {
                    seriesIndexValue = index
                } else {
                    seriesIndexValue = nil
                }
                let rating = ratingsByBook[id].flatMap { $0 > 0 ? $0 / 2 : nil }

                return CalibreBookRecord(
                    calibreID: id,
                    title: title,
                    authors: authors,
                    series: seriesByBook[id],
                    seriesIndex: seriesIndexValue,
                    tags: tagsByBook[id] ?? [],
                    rating: rating,
                    publisher: publisherByBook[id],
                    publicationDate: Self.date(fromJulian: row["pubdate"] as Double?),
                    addedDate: Self.date(fromJulian: row["timestamp"] as Double?),
                    languages: languagesByBook[id] ?? [],
                    identifiers: identifiersByBook[id] ?? [:],
                    comments: commentsByBook[id],
                    formats: formats,
                    cover: cover,
                    rawMetadata: raw,
                    opfPath: opfPath
                )
            }
        }
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
