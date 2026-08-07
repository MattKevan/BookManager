import Foundation

/// Builds an `IndexedBook` from a resolved book state — the shared
/// normalization used by the repository's journal applies and the rebuild
/// path. Kept in one place so the paths cannot drift.
public enum IndexedBookFactory {
    public static func make(
        resolved book: ResolvedBook,
        bookID: UUID,
        path: String,
        modifiedMilliseconds: Int64
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
        // UI shows "no date" instead of 1970-01-01.
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
            modifiedMilliseconds: modifiedMilliseconds,
            isDeleted: book.isDeleted
        )
    }
}
