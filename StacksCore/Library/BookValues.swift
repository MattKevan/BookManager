import Foundation

public struct BookFormatValue: Codable, Equatable, Sendable {
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

public struct CoverValue: Codable, Equatable, Sendable {
    public let filename: String
    public let contentHash: String

    public init(filename: String, contentHash: String) {
        self.filename = filename
        self.contentHash = contentHash
    }
}

public enum FacetType: String, Codable, Sendable {
    case author
    case series
    case tag
    case format
}

public struct NewBookMetadata: Sendable {
    public var title: String
    public var authors: [String]
    public var series: String?
    public var seriesIndex: Double?
    public var tags: [String]
    public var rating: Int?
    public var publisher: String?
    public var publicationDate: Date?
    public var addedDate: Date?
    public var languages: [String]
    public var identifiers: [String: String]
    public var comments: String?
    public var rawMetadata: [String: String]?

    public init(
        title: String,
        authors: [String] = [],
        series: String? = nil,
        seriesIndex: Double? = nil,
        tags: [String] = [],
        rating: Int? = nil,
        publisher: String? = nil,
        publicationDate: Date? = nil,
        addedDate: Date? = nil,
        languages: [String] = [],
        identifiers: [String: String] = [:],
        comments: String? = nil,
        rawMetadata: [String: String]? = nil
    ) {
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
        self.rawMetadata = rawMetadata
    }
}

