import Foundation

/// A book author read from a Calibre library, in Calibre's own order
/// (the `books_authors_link` row order).
public struct CalibreAuthor: Sendable, Equatable {
    public let name: String
    public let sort: String

    public init(name: String, sort: String) {
        self.name = name
        self.sort = sort
    }
}

/// One format file of a Calibre book, with the resolved on-disk location.
/// The file may be missing from disk (e.g. a stale `data` row) — the reader
/// reports it; the import service decides how to fail.
public struct CalibreFormatRecord: Sendable, Equatable {
    public let format: String
    public let name: String
    public let sourceURL: URL
    public let size: Int64

    public init(format: String, name: String, sourceURL: URL, size: Int64) {
        self.format = format
        self.name = name
        self.sourceURL = sourceURL
        self.size = size
    }

    /// True when the format file does not exist on disk.
    public var isMissing: Bool {
        !FileManager.default.fileExists(atPath: sourceURL.path)
    }
}

/// A book cover: embedded BLOB (only in schema variants that carry one) or
/// the conventional `cover.jpg` file in the book folder.
public enum CalibreCover: Sendable, Equatable {
    case blob(Data)
    case file(URL)
}

/// A fully mapped book read from a Calibre library.
public struct CalibreBookRecord: Sendable, Equatable {
    public let calibreID: Int
    public let title: String
    public let authors: [CalibreAuthor]
    public let series: String?
    public let seriesIndex: Double?
    public let tags: [String]
    /// 1...5 scale (Calibre's 2...10 halved).
    public let rating: Int?
    public let publisher: String?
    public let publicationDate: Date?
    public let addedDate: Date?
    public let languages: [String]
    public let identifiers: [String: String]
    public let comments: String?
    public let formats: [CalibreFormatRecord]
    public let cover: CalibreCover?
    /// Namespaced preservation payload: custom columns (`calibre.custom.<label>`),
    /// unsupported book columns (`calibre.pages`, `calibre.lccn`), annotations
    /// and last-read positions. Values are JSON-encoded strings.
    public let rawMetadata: [String: String]
    /// `"metadata.opf"` relative to the book folder when present, else nil.
    public let opfPath: String?

    public init(
        calibreID: Int,
        title: String,
        authors: [CalibreAuthor],
        series: String?,
        seriesIndex: Double?,
        tags: [String],
        rating: Int?,
        publisher: String?,
        publicationDate: Date?,
        addedDate: Date?,
        languages: [String],
        identifiers: [String: String],
        comments: String?,
        formats: [CalibreFormatRecord],
        cover: CalibreCover?,
        rawMetadata: [String: String],
        opfPath: String?
    ) {
        self.calibreID = calibreID
        self.title = title
        self.authors = authors
        self.series = series
        self.seriesIndex = seriesIndex
        self.tags = tags
        self.rating = rating
        self.publisher = publisher
        self.publicationDate = publicationDate
        self.addedDate = addedDate
        self.languages = languages
        self.identifiers = identifiers
        self.comments = comments
        self.formats = formats
        self.cover = cover
        self.rawMetadata = rawMetadata
        self.opfPath = opfPath
    }
}

/// High-level counts shown by the import wizard before copying.
public struct CalibreLibrarySummary: Sendable, Equatable {
    public let userVersion: Int
    public let libraryID: String
    public let bookCount: Int
    public let formatCount: Int
    public let titles: [String]

    public init(userVersion: Int, libraryID: String, bookCount: Int, formatCount: Int, titles: [String]) {
        self.userVersion = userVersion
        self.libraryID = libraryID
        self.bookCount = bookCount
        self.formatCount = formatCount
        self.titles = titles
    }
}

public enum CalibreReaderError: Error, Equatable {
    case missingMetadataDatabase(URL)
    case unsupportedSchemaVersion(Int)
    case notACalibreLibrary(URL)
}
