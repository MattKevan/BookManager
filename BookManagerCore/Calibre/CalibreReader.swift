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
    var pageCounts: [Int: CalibrePageCount] = [:]
    var conversionOptions: [Int: [CalibreConversionOption]] = [:]
    var extraIdentifiers: [Int: [String: [String]]] = [:]
    var columnDefinitions: [String: CalibreColumnDefinition] = [:]
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

        // Pick the schema adapter by the database's own version stamp: the
        // reader supports user_version 26 and 27, nothing else.
        let schema: any CalibreSchemaAdapting
        do {
            let version = try queue.read { db in
                try CalibreSchemaBase().userVersion(db)
            }
            switch version {
            case CalibreSchema26.supportedUserVersion:
                schema = CalibreSchema26()
            case CalibreSchema27.supportedUserVersion:
                schema = CalibreSchema27()
            default:
                throw CalibreReaderError.unsupportedSchemaVersion(version)
            }
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
            } else {
                // Calibre's identifiers table UNIQUEs (book, type), so a second
                // value per type is a defensive edge, not the norm.
                lookups.extraIdentifiers[entry.book, default: [:]][type, default: []].append(entry.value)
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
        for entry in try schema.fetchPageCounts(db) {
            lookups.pageCounts[entry.book] = CalibrePageCount(
                pages: entry.pages,
                algorithm: entry.algorithm,
                format: entry.format,
                formatSize: entry.formatSize
            )
        }
        for entry in try schema.fetchConversionOptions(db) {
            lookups.conversionOptions[entry.book, default: []].append(
                CalibreConversionOption(format: entry.format, data: entry.data)
            )
        }
        let customColumns = try schema.customColumns(db)
        for column in customColumns {
            lookups.columnDefinitions[column.label] = CalibreColumnDefinition(
                name: column.name,
                datatype: column.datatype,
                display: column.display,
                isMultiple: column.isMultiple,
                editable: column.editable,
                normalized: column.normalized
            )
            let values = try schema.fetchCustomValues(db, column: column)
            if column.isMultiple {
                var grouped: [Int: [String]] = [:]
                var extras: [Int: [String]] = [:]
                for entry in values {
                    if let value = entry.value {
                        grouped[entry.book, default: []].append(value)
                    }
                    if let extra = entry.extra, !extra.isEmpty {
                        extras[entry.book, default: []].append(extra)
                    }
                }
                let encoder = JSONEncoder()
                for (book, items) in grouped {
                    lookups.raw[book, default: [:]][column.key] =
                        String(decoding: try encoder.encode(items), as: UTF8.self)
                }
                if !extras.isEmpty {
                    for (book, items) in extras {
                        lookups.raw[book, default: [:]][column.key + ".extra"] =
                            String(decoding: try encoder.encode(items), as: UTF8.self)
                    }
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
        let sourcePath = bookPath.isEmpty ? nil : bookPath
        let sourceUUID = (row["uuid"] as String?).flatMap { $0.isEmpty ? nil : $0 }
        let titleSort = (row["sort"] as String?).flatMap { $0.isEmpty ? nil : $0 }
        let authorSort = (row["author_sort"] as String?).flatMap { $0.isEmpty ? nil : $0 }
        let lastModified = Self.date(fromDatabaseValue: row["last_modified"]?.databaseValue)
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
        if let pageCount = lookups.pageCounts[id] {
            raw["calibre.pages"] = "\(pageCount.pages)"
        } else if bookColumns.contains("pages"), let pages = row["pages"] as Int? {
            raw["calibre.pages"] = "\(pages)"
        }
        if let annotations = lookups.annotations[id] {
            raw["calibre.annotations"] = annotations
        }
        if let lastRead = lookups.lastRead[id] {
            raw["calibre.lastReadPositions"] = lastRead
        }

        // Custom-column definitions, but only for columns this book references.
        var customColumnDefinitions: [String: CalibreColumnDefinition] = [:]
        for key in raw.keys where key.hasPrefix("calibre.custom.") && !key.hasSuffix(".extra") {
            let label = String(key.dropFirst("calibre.custom.".count))
            if let definition = lookups.columnDefinitions[label] {
                customColumnDefinitions[label] = definition
            }
        }

        let originalFormats: [CalibreOriginalFormat] = (lookups.formats[id] ?? []).map {
            CalibreOriginalFormat(format: $0.format, name: $0.name, path: $0.path)
        }
        let conversionOptions = lookups.conversionOptions[id] ?? []
        let extraIdentifiers = lookups.extraIdentifiers[id] ?? [:]

        if let sourceUUID { raw["calibre.uuid"] = sourceUUID }
        if let titleSort { raw["calibre.titleSort"] = titleSort }
        if let authorSort { raw["calibre.authorSort"] = authorSort }
        if let lastModified { raw["calibre.lastModified"] = Self.isoString(from: lastModified) }
        if let sourcePath { raw["calibre.sourcePath"] = sourcePath }
        if !conversionOptions.isEmpty, let json = Self.jsonString(conversionOptions) {
            raw["calibre.conversionOptions"] = json
        }
        if !originalFormats.isEmpty, let json = Self.jsonString(originalFormats) {
            raw["calibre.originalFormats"] = json
        }
        if !extraIdentifiers.isEmpty, let json = Self.jsonString(extraIdentifiers) {
            raw["calibre.extraIdentifiers"] = json
        }
        if !customColumnDefinitions.isEmpty, let json = Self.jsonString(customColumnDefinitions) {
            raw["calibre.customColumns"] = json
        }

        let seriesIndexValue: Double?
        if lookups.series[id] != nil,
           let index = Self.double(fromDatabaseValue: row["series_index"]?.databaseValue),
           index != 0 {
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
            publicationDate: Self.date(fromDatabaseValue: row["pubdate"]?.databaseValue),
            addedDate: Self.date(fromDatabaseValue: row["timestamp"]?.databaseValue),
            languages: lookups.languages[id] ?? [],
            identifiers: lookups.identifiers[id] ?? [:],
            comments: lookups.comments[id],
            formats: formats,
            cover: cover,
            pages: lookups.pageCounts[id],
            sourceUUID: sourceUUID,
            titleSort: titleSort,
            authorSort: authorSort,
            lastModified: lastModified,
            sourcePath: sourcePath,
            originalFormats: originalFormats,
            conversionOptions: conversionOptions,
            extraIdentifiers: extraIdentifiers,
            customColumnDefinitions: customColumnDefinitions,
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

    /// Decodes `pubdate`/`timestamp` in whichever storage class the database
    /// uses. Calibre's own books table stores Julian day numbers (REAL), but
    /// some tools (e.g. calibre-web) write ISO-8601 text
    /// ("2019-05-28 00:00:00+00:00") into the same `TIMESTAMP` columns. GRDB's
    /// typed `as Double?` cast is strict and traps on TEXT storage, so the raw
    /// storage class must be read and dispatched (see `CalibreSchema`'s
    /// `valueString` for the same rule).
    static func date(fromDatabaseValue value: DatabaseValue?) -> Date? {
        guard let value else { return nil }
        switch value.storage {
        case .double(let julian):
            return date(fromJulian: julian)
        case .int64(let int):
            return date(fromJulian: Double(int))
        case .string(let string):
            return date(fromText: string)
        case .blob, .null:
            return nil
        }
    }

    /// Parses ISO-8601 date text in the shape tools like calibre-web write — a
    /// space separator instead of the ISO 'T' ("2019-05-28 00:00:00+00:00"),
    /// with or without fractional seconds, `Z` or `+00:00` offsets — and, as a
    /// fallback, naive UTC "yyyy-MM-dd HH:mm:ss" with no timezone.
    private static func date(fromText text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var normalized = trimmed
        if let space = trimmed.firstIndex(of: " "), !trimmed.contains("T") {
            normalized = trimmed.replacingCharacters(in: space...space, with: "T")
        }
        if let date = isoDate(from: normalized, fractionalSeconds: true)
            ?? isoDate(from: normalized, fractionalSeconds: false) {
            return Self.validDate(date)
        }
        // Naive "2019-05-28T00:00:00" without a timezone, treated as UTC.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return Self.validDate(formatter.date(from: normalized))
    }

    private static func isoDate(from string: String, fractionalSeconds: Bool) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = fractionalSeconds
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter.date(from: string)
    }

    /// calibre-web writes a year-101 sentinel ("0101-01-01 00:00:00+00:00")
    /// for missing pubdates; a date before year 1000 is a sentinel, not a
    /// real date, and must decode to nil.
    private static func validDate(_ date: Date?) -> Date? {
        guard let date else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let year = calendar.dateComponents([.year], from: date).year ?? 0
        return year >= 1000 ? date : nil
    }

    /// Decodes a numeric column in whichever storage class the database uses
    /// (calibre-web can create TEXT-affinity `series_index` tables); GRDB's
    /// typed `as Double?` cast is strict and traps on TEXT storage.
    static func double(fromDatabaseValue value: DatabaseValue?) -> Double? {
        guard let value else { return nil }
        switch value.storage {
        case .double(let double):
            return double
        case .int64(let int):
            return Double(int)
        case .string(let string):
            return Double(string)
        case .blob, .null:
            return nil
        }
    }

    /// ISO-8601 string for the preserved `calibre.lastModified` payload value.
    static func isoString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// JSON-encodes a structured payload (custom columns, original formats,
    /// conversion options, extra identifiers) into the flat raw string it is
    /// stored as. Nil on encode failure — the caller skips the key.
    private static func jsonString<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) }
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
