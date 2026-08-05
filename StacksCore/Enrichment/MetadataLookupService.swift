import Foundation

/// Scoring + normalization rules shared by the lookup service and the sources.
public enum MetadataScoring {
    /// ISBN-exact (normalized digits) → 100. Else exact normalized-title match
    /// → 60 + (author overlap ratio × 40); title mismatch → 0.
    public static func score(_ candidate: MetadataCandidate, for query: MetadataLookupQuery) -> Int {
        if let isbn = query.isbn, let candidateISBN = candidate.isbn,
           normalizeDigits(isbn) == normalizeDigits(candidateISBN) {
            return 100
        }
        guard normalize(candidate.title) == normalize(query.title) else { return 0 }
        let queryAuthors = Set(query.authors.map(normalize))
        guard !queryAuthors.isEmpty else { return 60 }
        let candidateAuthors = Set(candidate.authors.map(normalize))
        let overlap = queryAuthors.intersection(candidateAuthors).count
        let ratio = Double(overlap) / Double(queryAuthors.count)
        return 60 + Int((ratio * 40).rounded())
    }

    /// Candidates sorted by score descending, stable (source order preserved
    /// for ties).
    public static func ranked(_ candidates: [MetadataCandidate], for query: MetadataLookupQuery) -> [MetadataCandidate] {
        candidates.enumerated()
            .sorted { lhs, rhs in
                let lhsScore = score(lhs.element, for: query)
                let rhsScore = score(rhs.element, for: query)
                if lhsScore != rhsScore { return lhsScore > rhsScore }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// The auto-apply candidate: the top result when it scores ≥ 90 and beats
    /// the runner-up by ≥ 20; otherwise nil (review).
    public static func autoApply(from ranked: [MetadataCandidate], for query: MetadataLookupQuery) -> MetadataCandidate? {
        guard let top = ranked.first else { return nil }
        let topScore = score(top, for: query)
        guard topScore >= 90 else { return nil }
        if ranked.count > 1, topScore - score(ranked[1], for: query) < 20 { return nil }
        return top
    }

    /// Lowercase, strip punctuation, collapse whitespace.
    public static func normalize(_ value: String) -> String {
        let kept = value.lowercased().filter { $0.isLetter || $0.isNumber || $0.isWhitespace }
        return kept.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Digits only — ISBNs differ in hyphens/X suffix casing.
    public static func normalizeDigits(_ value: String) -> String {
        value.lowercased().filter(\.isNumber)
    }

    /// A stable slug for candidate ids when a source gives no other handle.
    public static func slug(_ value: String) -> String {
        normalize(value).replacingOccurrences(of: " ", with: "-")
    }
}

/// Runs a metadata lookup: normalizes the query, consults sources in priority
/// order (cancellable, first non-empty source wins, per-source failures fall
/// through), scores/ranks, caches per normalized query, and picks the
/// auto-apply candidate when unambiguous.
public actor MetadataLookupService {
    private let registry: MetadataRegistry
    private var cache: [String: MetadataLookupResult]

    public init(registry: MetadataRegistry, cache: [String: MetadataLookupResult] = [:]) {
        self.registry = registry
        self.cache = cache
    }

    public func lookup(_ query: MetadataLookupQuery) async throws -> MetadataLookupResult {
        try Task.checkCancellation()
        let key = Self.cacheKey(for: query)
        if let cached = cache[key] { return cached }

        var candidates: [MetadataCandidate] = []
        var firstError: Error?
        for source in registry.sources {
            try Task.checkCancellation()
            do {
                let results = try await source.search(query)
                if !results.isEmpty {
                    candidates = results
                    break
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if candidates.isEmpty, let firstError {
            throw firstError
        }

        let ranked = MetadataScoring.ranked(candidates, for: query)
        let result = MetadataLookupResult(
            candidates: ranked,
            autoApply: MetadataScoring.autoApply(from: ranked, for: query)
        )
        cache[key] = result
        return result
    }

    /// ISBN queries normalize to digits; otherwise normalized
    /// `title|firstAuthor`. Case/punctuation-insensitive.
    public static func cacheKey(for query: MetadataLookupQuery) -> String {
        if let isbn = query.isbn {
            return "isbn:\(MetadataScoring.normalizeDigits(isbn))"
        }
        let title = MetadataScoring.normalize(query.title)
        let author = query.authors.first.map(MetadataScoring.normalize) ?? ""
        return "\(title)|\(author)"
    }
}
