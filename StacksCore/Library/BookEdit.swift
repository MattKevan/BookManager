import Foundation

/// A keep/set/clear instruction for one editable field — the shape of an
/// `updateBook` command's per-field payloads. Codable via synthesis (the
/// journal format is ours; round-trip safety is what matters).
public enum FieldEdit<T: Sendable & Equatable & Codable>: Equatable, Sendable, Codable {
    case keep
    case set(T)
    case clear
}

/// One metadata edit to a book. `nil`/`.keep` fields are untouched; `.set`
/// assigns; `.clear` empties a single-value field. The journal's
/// `updateBook` command carries this verbatim.
public struct BookEdit: Sendable, Codable, Equatable {
    public var title: String?
    public var authors: [String]?
    public var series: FieldEdit<String> = .keep
    public var seriesIndex: FieldEdit<Double> = .keep
    public var tags: [String]?
    public var rating: FieldEdit<Int> = .keep
    public var publisher: FieldEdit<String> = .keep
    public var publicationDate: FieldEdit<Date> = .keep
    public var languages: [String]?
    public var identifiers: [String: String]?
    public var comments: FieldEdit<String> = .keep

    public init(
        title: String? = nil,
        authors: [String]? = nil,
        series: FieldEdit<String> = .keep,
        seriesIndex: FieldEdit<Double> = .keep,
        tags: [String]? = nil,
        rating: FieldEdit<Int> = .keep,
        publisher: FieldEdit<String> = .keep,
        publicationDate: FieldEdit<Date> = .keep,
        languages: [String]? = nil,
        identifiers: [String: String]? = nil,
        comments: FieldEdit<String> = .keep
    ) {
        self.title = title
        self.authors = authors
        self.series = series
        self.seriesIndex = seriesIndex
        self.tags = tags
        self.rating = rating
        self.publisher = publisher
        self.publicationDate = publicationDate
        self.languages = languages
        self.identifiers = identifiers
        self.comments = comments
    }

    /// True when the edit changes nothing (every field is `.keep`/nil). The
    /// batch metadata editor skips such books when committing — a no-op edit
    /// would otherwise append a pointless journal command.
    public var isEmpty: Bool {
        title == nil && authors == nil && tags == nil && languages == nil && identifiers == nil
            && series == .keep && seriesIndex == .keep && rating == .keep
            && publisher == .keep && publicationDate == .keep && comments == .keep
    }
}
