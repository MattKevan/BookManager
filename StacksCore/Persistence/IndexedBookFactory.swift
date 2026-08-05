import Foundation

/// Builds an `IndexedBook` from a resolved Automerge document — the shared
/// normalization used by the repository (edits, rebuilds) and the sync engine
/// (ingest). Kept in one place so the two paths cannot drift.
public enum IndexedBookFactory {
    public static func make(
        resolved book: ResolvedBook,
        bookID: UUID,
        path: String,
        snapshot: Data
    ) throws -> IndexedBook {
        let normalizeEmpty: (String?) -> String? = { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        let normalizeZero: (Double?) -> Double? = { value in
            guard let value, value != 0 else { return nil }
            return value
        }
        let normalizeRating: (Int?) -> Int? = { value in
            guard let value, value != 0 else { return nil }
            return value
        }
        // `.clear` edits write the epoch-0 sentinel; map it back to nil so the
        // UI shows "no date" instead of 1970-01-01 (plan's clear-sentinel contract).
        let epochZero = Date(timeIntervalSince1970: 0)
        let normalizeDate: (Date?) -> Date? = { value in
            guard let value, value != epochZero else { return nil }
            return value
        }
        return IndexedBook(
            id: bookID,
            title: book.title,
            authors: book.authors,
            series: normalizeEmpty(book.series),
            seriesIndex: normalizeZero(book.seriesIndex),
            tags: book.tags,
            rating: normalizeRating(book.rating),
            publisher: normalizeEmpty(book.publisher),
            publicationMilliseconds: normalizeDate(book.publicationDate).map { Int64($0.timeIntervalSince1970 * 1_000) },
            addedMilliseconds: normalizeDate(book.addedDate).map { Int64($0.timeIntervalSince1970 * 1_000) },
            languages: book.languages,
            identifiers: book.identifiers,
            comments: normalizeEmpty(book.comments),
            rawMetadata: book.rawMetadata,
            formats: book.formats.map {
                BookFormatRecord(
                    kind: $0.kind, filename: $0.filename,
                    contentHash: $0.contentHash, size: $0.size
                )
            },
            coverHash: book.cover?.contentHash,
            relativePath: path,
            modifiedMilliseconds: book.modifiedClock.physicalMilliseconds,
            isDeleted: book.isDeleted,
            snapshot: snapshot
        )
    }
}
