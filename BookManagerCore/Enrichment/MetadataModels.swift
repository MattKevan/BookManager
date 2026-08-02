import Foundation

/// A metadata lookup for one book: its ISBN when known, plus title and
/// authors for title+author matching.
public struct MetadataLookupQuery: Sendable, Equatable {
    public let isbn: String?
    public let title: String
    public let authors: [String]

    public init(isbn: String?, title: String, authors: [String]) {
        self.isbn = isbn
        self.title = title
        self.authors = authors
    }
}

/// One metadata result from a source, with provenance for the review UI.
public struct MetadataCandidate: Identifiable, Sendable, Equatable {
    /// Stable per-source identity (used by the review list).
    public let id: String
    public let title: String
    public let authors: [String]
    public let publisher: String?
    public let publicationDate: Date?
    public let isbn: String?
    public let coverURL: URL?
    public let sourceName: String

    public init(
        id: String,
        title: String,
        authors: [String],
        publisher: String?,
        publicationDate: Date?,
        isbn: String?,
        coverURL: URL?,
        sourceName: String
    ) {
        self.id = id
        self.title = title
        self.authors = authors
        self.publisher = publisher
        self.publicationDate = publicationDate
        self.isbn = isbn
        self.coverURL = coverURL
        self.sourceName = sourceName
    }
}

/// The outcome of a lookup: all ranked candidates (for the review UI) and the
/// candidate that was unambiguous enough to auto-apply, if any.
public struct MetadataLookupResult: Sendable, Equatable {
    public let candidates: [MetadataCandidate]
    public let autoApply: MetadataCandidate?

    public init(candidates: [MetadataCandidate], autoApply: MetadataCandidate?) {
        self.candidates = candidates
        self.autoApply = autoApply
    }
}

public enum MetadataSourceError: Error, Equatable {
    case badURL
}

/// Shared date parsing for source payloads: "YYYY", "YYYY-MM", "YYYY-MM-DD"
/// (UTC), and year-only conversion for OpenLibrary's first_publish_year.
enum MetadataDateParser {
    static func date(fromPublishedString value: String) -> Date? {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard let year = parts.first, (1000...9999).contains(year) else { return nil }
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(identifier: "UTC")
        components.year = year
        if parts.count > 1 { components.month = parts[1] }
        if parts.count > 2 { components.day = parts[2] }
        return components.date
    }

    static func date(fromYear year: Int) -> Date? {
        guard (1000...9999).contains(year) else { return nil }
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(identifier: "UTC")
        components.year = year
        return components.date
    }
}
