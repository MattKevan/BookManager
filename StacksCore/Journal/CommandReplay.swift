import Foundation

/// The pure command→state transformation shared by every read model: the
/// server's catalog rebuild, remote-library clients replaying a pulled
/// command stream, and future headless read models. Given the current state
/// and a command, produces the next state — no I/O, no folder side effects.
public enum CommandReplay {
    /// Applies one command to the in-memory book state.
    public static func apply(
        _ command: JournalCommand,
        to state: inout [UUID: IndexedBook]
    ) throws {
        switch command.op {
        case .addBook(let payload):
            let path = CanonicalPathBuilder.relativeDirectory(
                bookID: payload.bookID, title: payload.title, authors: payload.authors
            )
            state[payload.bookID] = try IndexedBookFactory.make(
                resolved: resolved(from: payload),
                bookID: payload.bookID,
                path: path,
                modifiedMilliseconds: tsMilliseconds(payload.addedDate ?? .now)
            )
        case .updateBook(let payload):
            guard let current = state[payload.bookID] else {
                throw ReplayError.unknownBook(payload.bookID)
            }
            let resolved = resolved(byApplying: payload.edit, to: current)
            let path = CanonicalPathBuilder.relativeDirectory(
                bookID: payload.bookID, title: resolved.title, authors: resolved.authors
            )
            state[payload.bookID] = try IndexedBookFactory.make(
                resolved: resolved,
                bookID: payload.bookID,
                path: path,
                modifiedMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000)
            )
        case .setCover(let payload):
            guard let current = state[payload.bookID] else {
                throw ReplayError.unknownBook(payload.bookID)
            }
            state[payload.bookID] = replacingCover(current, coverHash: payload.cover?.contentHash)
        case .deleteBook(let payload):
            // Idempotent end-state op: deleting a book that is already gone
            // (a stale client racing another client's delete) is a no-op.
            if let current = state[payload.bookID] {
                state[payload.bookID] = withDeleted(current, isDeleted: true)
            }
        case .restoreBook(let payload):
            // Idempotent end-state op: restoring a book that is not in the
            // catalog is a no-op.
            guard let current = state[payload.bookID] else { break }
            let resolved = resolved(from: current, isDeleted: false)
            let path = CanonicalPathBuilder.relativeDirectory(
                bookID: payload.bookID, title: resolved.title, authors: resolved.authors
            )
            state[payload.bookID] = try IndexedBookFactory.make(
                resolved: resolved,
                bookID: payload.bookID,
                path: path,
                modifiedMilliseconds: current.modifiedMilliseconds
            )
        }
    }

    /// Replays a command stream from scratch (the initial pull / rebuild).
    public static func replay(
        _ commands: [JournalCommand],
        seeding: [JournalSnapshot.Book] = []
    ) throws -> [UUID: IndexedBook] {
        var state: [UUID: IndexedBook] = [:]
        for book in seeding {
            state[book.bookID] = try IndexedBookFactory.make(
                resolved: resolved(from: book),
                bookID: book.bookID,
                path: book.relativePath,
                modifiedMilliseconds: 0
            )
        }
        for command in commands {
            try apply(command, to: &state)
        }
        return state
    }

    public enum ReplayError: Error, Equatable {
        case unknownBook(UUID)
    }

    // MARK: - Mapping helpers (shared with the server's live apply path)

    /// Applies an edit's fields over a current book — nil/`.keep` untouched,
    /// `.set` assigns, `.clear` empties.
    public static func resolved(byApplying edit: BookEdit, to book: IndexedBook) -> ResolvedBook {
        ResolvedBook(
            id: book.id,
            title: edit.title ?? book.title,
            authors: edit.authors ?? book.authors,
            series: edit.series.apply(to: book.series),
            seriesIndex: edit.seriesIndex.apply(to: book.seriesIndex),
            tags: edit.tags ?? book.tags,
            rating: edit.rating.apply(to: book.rating),
            publisher: edit.publisher.apply(to: book.publisher),
            publicationDate: edit.publicationDate.apply(to: book.publicationDate),
            addedDate: book.addedDate,
            languages: edit.languages ?? book.languages,
            identifiers: edit.identifiers ?? book.identifiers,
            comments: edit.comments.apply(to: book.comments),
            formats: book.formats.map {
                BookFormatValue(kind: $0.kind, filename: $0.filename, contentHash: $0.contentHash, size: $0.size)
            },
            cover: book.coverHash.map { CoverValue(filename: "cover.jpg", contentHash: $0) },
            rawMetadata: book.rawMetadata,
            isDeleted: book.isDeleted
        )
    }

    public static func resolved(from book: IndexedBook) -> ResolvedBook {
        resolved(from: book, isDeleted: book.isDeleted)
    }

    public static func resolved(from book: IndexedBook, isDeleted: Bool) -> ResolvedBook {
        ResolvedBook(
            id: book.id,
            title: book.title,
            authors: book.authors,
            series: book.series,
            seriesIndex: book.seriesIndex,
            tags: book.tags,
            rating: book.rating,
            publisher: book.publisher,
            publicationDate: book.publicationDate,
            addedDate: book.addedDate,
            languages: book.languages,
            identifiers: book.identifiers,
            comments: book.comments,
            formats: book.formats.map {
                BookFormatValue(kind: $0.kind, filename: $0.filename, contentHash: $0.contentHash, size: $0.size)
            },
            cover: book.coverHash.map { CoverValue(filename: "cover.jpg", contentHash: $0) },
            rawMetadata: book.rawMetadata,
            isDeleted: isDeleted
        )
    }

    public static func resolved(from payload: JournalCommand.AddBook) -> ResolvedBook {
        ResolvedBook(
            id: payload.bookID,
            title: payload.title,
            authors: payload.authors,
            series: payload.series,
            seriesIndex: payload.seriesIndex,
            tags: payload.tags,
            rating: payload.rating,
            publisher: payload.publisher,
            publicationDate: payload.publicationDate,
            addedDate: payload.addedDate,
            languages: payload.languages,
            identifiers: payload.identifiers,
            comments: payload.comments,
            formats: payload.formats.map {
                // The on-disk name is the canonical one materialize writes
                // (title - author.kind); the catalog must agree with the
                // disk or downloads 404. The payload's filename is only the
                // client's label — canonicalize here so the live apply and
                // the replay produce identical records.
                BookFormatValue(
                    kind: $0.kind,
                    filename: CanonicalPathBuilder.formatFileName(
                        title: payload.title, authors: payload.authors, kind: $0.kind
                    ),
                    contentHash: $0.contentHash,
                    size: $0.size
                )
            },
            cover: payload.cover.map { CoverValue(filename: $0.filename, contentHash: $0.contentHash) },
            rawMetadata: nil,
            isDeleted: false
        )
    }

    public static func resolved(from snapshotBook: JournalSnapshot.Book) -> ResolvedBook {
        ResolvedBook(
            id: snapshotBook.bookID,
            title: snapshotBook.title,
            authors: snapshotBook.authors,
            series: snapshotBook.series,
            seriesIndex: snapshotBook.seriesIndex,
            tags: snapshotBook.tags,
            rating: snapshotBook.rating,
            publisher: snapshotBook.publisher,
            publicationDate: snapshotBook.publicationDate,
            addedDate: snapshotBook.addedDate,
            languages: snapshotBook.languages,
            identifiers: snapshotBook.identifiers,
            comments: snapshotBook.comments,
            formats: snapshotBook.formats.map {
                BookFormatValue(kind: $0.kind, filename: $0.filename, contentHash: $0.contentHash, size: $0.size)
            },
            cover: snapshotBook.cover.map { CoverValue(filename: $0.filename, contentHash: $0.contentHash) },
            rawMetadata: nil,
            isDeleted: snapshotBook.isDeleted
        )
    }

    public static func replacingCover(_ book: IndexedBook, coverHash: String?) -> IndexedBook {
        IndexedBook(
            id: book.id, title: book.title, authors: book.authors,
            series: book.series, seriesIndex: book.seriesIndex, tags: book.tags,
            rating: book.rating, publisher: book.publisher,
            publicationMilliseconds: book.publicationMilliseconds,
            addedMilliseconds: book.addedMilliseconds,
            languages: book.languages, identifiers: book.identifiers, comments: book.comments,
            rawMetadata: book.rawMetadata, formats: book.formats,
            coverHash: coverHash, relativePath: book.relativePath,
            modifiedMilliseconds: book.modifiedMilliseconds, isDeleted: book.isDeleted
        )
    }

    public static func withDeleted(_ book: IndexedBook, isDeleted: Bool) -> IndexedBook {
        IndexedBook(
            id: book.id, title: book.title, authors: book.authors,
            series: book.series, seriesIndex: book.seriesIndex, tags: book.tags,
            rating: book.rating, publisher: book.publisher,
            publicationMilliseconds: book.publicationMilliseconds,
            addedMilliseconds: book.addedMilliseconds,
            languages: book.languages, identifiers: book.identifiers, comments: book.comments,
            rawMetadata: book.rawMetadata, formats: book.formats,
            coverHash: book.coverHash, relativePath: book.relativePath,
            modifiedMilliseconds: book.modifiedMilliseconds, isDeleted: isDeleted
        )
    }

    public static func tsMilliseconds(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1_000)
    }
}

extension FieldEdit {
    /// Applies the keep/set/clear instruction over a current value.
    func apply(to current: T?) -> T? {
        switch self {
        case .keep: return current
        case .set(let value): return value
        case .clear: return nil
        }
    }
}
