import Foundation

/// The periodic full-state snapshot that accelerates rebuilds: seed the
/// catalog from the snapshot, then replay journal records with `seq` greater
/// than `lastSeq`. Written atomically by the owning server.
public struct JournalSnapshot: Sendable, Codable, Equatable {
    public let lastSeq: Int64
    public let books: [Book]

    public struct Book: Sendable, Codable, Equatable {
        public let bookID: UUID
        public let relativePath: String
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
        public let formats: [Format]
        public let cover: Cover?
        public let isDeleted: Bool

        public struct Format: Sendable, Codable, Equatable {
            public let kind: String
            public let filename: String
            public let contentHash: String
            public let size: Int64
        }

        public struct Cover: Sendable, Codable, Equatable {
            public let filename: String
            public let contentHash: String
        }
    }

    public init(lastSeq: Int64, books: [Book]) {
        self.lastSeq = lastSeq
        self.books = books
    }
}

extension JournalSnapshot.Book {
    /// Convenience mapping from a catalog row — used when the server writes
    /// a snapshot.
    public init(book: IndexedBook) {
        self.init(
            bookID: book.id,
            relativePath: book.relativePath,
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
                Format(kind: $0.kind, filename: $0.filename, contentHash: $0.contentHash, size: $0.size)
            },
            cover: book.coverHash.map { Cover(filename: "cover.jpg", contentHash: $0) },
            isDeleted: book.isDeleted
        )
    }
}
