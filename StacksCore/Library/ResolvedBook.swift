import Foundation

/// The resolved metadata state of one book — the shape the journal commands
/// and `BookFolder` operate on. Journal-era: no CRDT clocks; `modified`
/// timestamps are the owning server's command timestamps.
public struct ResolvedBook: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let title: String
    public let authors: [String]
    public let series: String?
    public let seriesIndex: Double?
    public let tags: [String]
    public let rating: Int?
    public let publisher: String?
    public let publicationDate: Date?
    public let addedDate: Date?
    public let languages: [String]
    public let identifiers: [String: String]
    public let comments: String?
    public let formats: [BookFormatValue]
    public let cover: CoverValue?
    public let rawMetadata: [String: String]?
    public let isDeleted: Bool

    public init(
        id: UUID,
        title: String,
        authors: [String],
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
        formats: [BookFormatValue],
        cover: CoverValue?,
        rawMetadata: [String: String]? = nil,
        isDeleted: Bool
    ) {
        self.id = id
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
        self.isDeleted = isDeleted
    }
}
