import Foundation

public struct VersionedValue<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public let value: Value
    public let clock: HybridLogicalClock

    public init(value: Value, clock: HybridLogicalClock) {
        self.value = value
        self.clock = clock
    }
}

public struct BookDocumentSchema: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var bookID: UUID?
    public var titles: [String: VersionedValue<String>]
    public var authors: [String: VersionedValue<[String]>]
    public var deletions: [String: VersionedValue<Bool>]
    public var series: [String: VersionedValue<String>]
    public var seriesIndexes: [String: VersionedValue<Double>]
    public var tags: [String: [String: VersionedValue<Bool>]]
    public var ratings: [String: VersionedValue<Int>]
    public var publishers: [String: VersionedValue<String>]
    public var publicationDates: [String: VersionedValue<Date>]
    public var addedDates: [String: VersionedValue<Date>]
    public var languages: [String: VersionedValue<[String]>]
    public var identifiers: [String: [String: VersionedValue<String>]]
    public var comments: [String: VersionedValue<String>]
    public var formats: [String: [String: VersionedValue<BookFormatValue>]]
    public var covers: [String: VersionedValue<CoverValue>]
    public var rawMetadata: [String: VersionedValue<String>]

    public init(
        schemaVersion: Int = 2,
        bookID: UUID? = nil,
        titles: [String: VersionedValue<String>] = [:],
        authors: [String: VersionedValue<[String]>] = [:],
        deletions: [String: VersionedValue<Bool>] = [:],
        series: [String: VersionedValue<String>] = [:],
        seriesIndexes: [String: VersionedValue<Double>] = [:],
        tags: [String: [String: VersionedValue<Bool>]] = [:],
        ratings: [String: VersionedValue<Int>] = [:],
        publishers: [String: VersionedValue<String>] = [:],
        publicationDates: [String: VersionedValue<Date>] = [:],
        addedDates: [String: VersionedValue<Date>] = [:],
        languages: [String: VersionedValue<[String]>] = [:],
        identifiers: [String: [String: VersionedValue<String>]] = [:],
        comments: [String: VersionedValue<String>] = [:],
        formats: [String: [String: VersionedValue<BookFormatValue>]] = [:],
        covers: [String: VersionedValue<CoverValue>] = [:],
        rawMetadata: [String: VersionedValue<String>] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.bookID = bookID
        self.titles = titles
        self.authors = authors
        self.deletions = deletions
        self.series = series
        self.seriesIndexes = seriesIndexes
        self.tags = tags
        self.ratings = ratings
        self.publishers = publishers
        self.publicationDates = publicationDates
        self.addedDates = addedDates
        self.languages = languages
        self.identifiers = identifiers
        self.comments = comments
        self.formats = formats
        self.covers = covers
        self.rawMetadata = rawMetadata
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, bookID, titles, authors, deletions, series, seriesIndexes
        case tags, ratings, publishers, publicationDates, addedDates
        case languages, identifiers, comments, formats, covers, rawMetadata
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        bookID = try container.decodeIfPresent(UUID.self, forKey: .bookID)
        titles = try container.decodeIfPresent([String: VersionedValue<String>].self, forKey: .titles) ?? [:]
        authors = try container.decodeIfPresent([String: VersionedValue<[String]>].self, forKey: .authors) ?? [:]
        deletions = try container.decodeIfPresent([String: VersionedValue<Bool>].self, forKey: .deletions) ?? [:]
        series = try container.decodeIfPresent([String: VersionedValue<String>].self, forKey: .series) ?? [:]
        seriesIndexes = try container.decodeIfPresent([String: VersionedValue<Double>].self, forKey: .seriesIndexes) ?? [:]
        tags = try container.decodeIfPresent([String: [String: VersionedValue<Bool>]].self, forKey: .tags) ?? [:]
        ratings = try container.decodeIfPresent([String: VersionedValue<Int>].self, forKey: .ratings) ?? [:]
        publishers = try container.decodeIfPresent([String: VersionedValue<String>].self, forKey: .publishers) ?? [:]
        publicationDates = try container.decodeIfPresent([String: VersionedValue<Date>].self, forKey: .publicationDates) ?? [:]
        addedDates = try container.decodeIfPresent([String: VersionedValue<Date>].self, forKey: .addedDates) ?? [:]
        languages = try container.decodeIfPresent([String: VersionedValue<[String]>].self, forKey: .languages) ?? [:]
        identifiers = try container.decodeIfPresent([String: [String: VersionedValue<String>]].self, forKey: .identifiers) ?? [:]
        comments = try container.decodeIfPresent([String: VersionedValue<String>].self, forKey: .comments) ?? [:]
        formats = try container.decodeIfPresent([String: [String: VersionedValue<BookFormatValue>]].self, forKey: .formats) ?? [:]
        covers = try container.decodeIfPresent([String: VersionedValue<CoverValue>].self, forKey: .covers) ?? [:]
        rawMetadata = try container.decodeIfPresent([String: VersionedValue<String>].self, forKey: .rawMetadata) ?? [:]
    }
}

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
    public let modifiedClock: HybridLogicalClock

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
        isDeleted: Bool,
        modifiedClock: HybridLogicalClock
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
        self.modifiedClock = modifiedClock
    }
}
