import Foundation

/// One journal command — an idempotent, server-ordered mutation of the
/// library. `id` is client-generated (the dedupe key for replay); `seq` is
/// assigned by the owning server and is the sync cursor.
public struct JournalCommand: Sendable, Codable, Equatable {
    public let id: UUID
    public let seq: Int64
    public let ts: Date
    public let op: Op

    public enum Op: Sendable, Codable, Equatable {
        case addBook(AddBook)
        case updateBook(UpdateBook)
        case setCover(SetCover)
        case deleteBook(DeleteBook)
        case restoreBook(RestoreBook)
    }

    /// One format file staged for an `addBook`. `stagedName` references
    /// `.bookmanager/staging/<commandID>/<stagedName>`; apply moves it into
    /// the book folder and removes the staging directory.
    public struct StagedFormat: Sendable, Codable, Equatable {
        public let kind: String
        public let filename: String
        public let contentHash: String
        public let size: Int64
        public let stagedName: String
    }

    public struct StagedCover: Sendable, Codable, Equatable {
        public let filename: String
        public let contentHash: String
        public let stagedName: String
    }

    public struct AddBook: Sendable, Codable, Equatable {
        public let bookID: UUID
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
        public let formats: [StagedFormat]
        public let cover: StagedCover?
    }

    public struct UpdateBook: Sendable, Codable, Equatable {
        public let bookID: UUID
        public let edit: BookEdit
    }

    public struct SetCover: Sendable, Codable, Equatable {
        public let bookID: UUID
        public let cover: StagedCover?
    }

    public struct DeleteBook: Sendable, Codable, Equatable {
        public let bookID: UUID
    }

    public struct RestoreBook: Sendable, Codable, Equatable {
        public let bookID: UUID
    }
}
