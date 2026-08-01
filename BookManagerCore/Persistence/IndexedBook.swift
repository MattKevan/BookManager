import Foundation
import GRDB

public struct BookFormatRecord: Codable, Equatable, Sendable {
    public let kind: String
    public let filename: String
    public let contentHash: String
    public let size: Int64

    public init(kind: String, filename: String, contentHash: String, size: Int64) {
        self.kind = kind
        self.filename = filename
        self.contentHash = contentHash
        self.size = size
    }
}

public struct IndexedBook: Identifiable, Equatable, Sendable {
    // Snapshot bytes are deliberately excluded from equality: two replicas that
    // converged on identical metadata have identical snapshots, but rebuilds from
    // change files may serialize documents under a different actor identity.
    public static func == (lhs: IndexedBook, rhs: IndexedBook) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.authors == rhs.authors
            && lhs.series == rhs.series && lhs.seriesIndex == rhs.seriesIndex
            && lhs.tags == rhs.tags && lhs.rating == rhs.rating && lhs.publisher == rhs.publisher
            && lhs.publicationMilliseconds == rhs.publicationMilliseconds
            && lhs.addedMilliseconds == rhs.addedMilliseconds && lhs.languages == rhs.languages
            && lhs.identifiers == rhs.identifiers && lhs.comments == rhs.comments
            && lhs.rawMetadata == rhs.rawMetadata
            && lhs.formats == rhs.formats && lhs.coverHash == rhs.coverHash
            && lhs.relativePath == rhs.relativePath
            && lhs.modifiedMilliseconds == rhs.modifiedMilliseconds && lhs.isDeleted == rhs.isDeleted
    }
    public let id: UUID
    public let title: String
    public let authors: [String]
    public let series: String?
    public let seriesIndex: Double?
    public let tags: [String]
    public let rating: Int?
    public let publisher: String?
    public let publicationMilliseconds: Int64?
    public let addedMilliseconds: Int64?
    public let languages: [String]
    public let identifiers: [String: String]
    public let comments: String?
    /// Preserved Calibre payload (namespaced keys, JSON-encoded values). Opaque
    /// to the catalogue — stored and returned verbatim; nil when absent.
    public let rawMetadata: [String: String]?
    public let formats: [BookFormatRecord]
    public let coverHash: String?
    public let relativePath: String
    public let modifiedMilliseconds: Int64
    public let isDeleted: Bool
    public let snapshot: Data

    public init(
        id: UUID,
        title: String,
        authors: [String],
        series: String? = nil,
        seriesIndex: Double? = nil,
        tags: [String] = [],
        rating: Int? = nil,
        publisher: String? = nil,
        publicationMilliseconds: Int64? = nil,
        addedMilliseconds: Int64? = nil,
        languages: [String] = [],
        identifiers: [String: String] = [:],
        comments: String? = nil,
        rawMetadata: [String: String]? = nil,
        formats: [BookFormatRecord] = [],
        coverHash: String? = nil,
        relativePath: String = "",
        modifiedMilliseconds: Int64,
        isDeleted: Bool,
        snapshot: Data
    ) {
        self.id = id
        self.title = title
        self.authors = authors
        self.series = series
        self.seriesIndex = seriesIndex
        self.tags = tags
        self.rating = rating
        self.publisher = publisher
        self.publicationMilliseconds = publicationMilliseconds
        self.addedMilliseconds = addedMilliseconds
        self.languages = languages
        self.identifiers = identifiers
        self.comments = comments
        self.rawMetadata = rawMetadata
        self.formats = formats
        self.coverHash = coverHash
        self.relativePath = relativePath
        self.modifiedMilliseconds = modifiedMilliseconds
        self.isDeleted = isDeleted
        self.snapshot = snapshot
    }

    public var publicationDate: Date? {
        publicationMilliseconds.map { Date(timeIntervalSince1970: TimeInterval($0) / 1_000) }
    }

    public var addedDate: Date? {
        addedMilliseconds.map { Date(timeIntervalSince1970: TimeInterval($0) / 1_000) }
    }
}

extension IndexedBook: FetchableRecord {
    public init(row: Row) {
        // The catalogue is disposable and rebuildable from the change store, so a
        // corrupt row id is a broken build, not a recoverable condition. Fail
        // loudly rather than silently fabricating a random identity (which would
        // corrupt lookups and updates for the book).
        guard let id = UUID(uuidString: row["id"] as String) else {
            fatalError("Corrupt catalogue row: unparseable book id '\(row["id"] as String)'")
        }
        self.id = id
        title = row["title"] as String
        authors = (try? JSONCoding.decode([String].self, from: row["authors"] as String?)) ?? []
        series = row["series"] as String?
        seriesIndex = row["seriesIndex"] as Double?
        tags = (try? JSONCoding.decode([String].self, from: row["tags"] as String?)) ?? []
        rating = row["rating"] as Int?
        publisher = row["publisher"] as String?
        publicationMilliseconds = row["publicationMilliseconds"] as Int64?
        addedMilliseconds = row["addedMilliseconds"] as Int64?
        languages = (try? JSONCoding.decode([String].self, from: row["languages"] as String?)) ?? []
        identifiers = (try? JSONCoding.decode([String: String].self, from: row["identifiers"] as String?)) ?? [:]
        comments = row["comments"] as String?
        rawMetadata = (try? JSONCoding.decode([String: String].self, from: row["rawMetadata"] as String?))
        formats = (try? JSONCoding.decode([BookFormatRecord].self, from: row["formats"] as String?)) ?? []
        coverHash = row["coverHash"] as String?
        relativePath = row["relativePath"] as String
        modifiedMilliseconds = row["modifiedMilliseconds"] as Int64
        isDeleted = row["isDeleted"] as Bool
        snapshot = row["snapshot"] as Data
    }
}
