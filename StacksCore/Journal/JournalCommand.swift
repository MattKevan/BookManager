import Foundation

/// One journal command — an idempotent, server-ordered mutation of the
/// library. `id` is client-generated (the dedupe key for replay); `seq` is
/// assigned by the owning server and is the sync cursor.
public struct JournalCommand: Sendable, Codable, Equatable {
    public let id: UUID
    public let seq: Int64
    public let ts: Date
    public let op: Op

    public init(id: UUID, seq: Int64, ts: Date, op: Op) {
        self.id = id
        self.seq = seq
        self.ts = ts
        self.op = op
    }

    public enum Op: Sendable, Codable, Equatable {
        case addBook(AddBook)
        case updateBook(UpdateBook)
        case setCover(SetCover)
        case deleteBook(DeleteBook)
        case restoreBook(RestoreBook)

        // Custom Codable: the synthesized form wraps the payload in an `_0`
        // key ("addBook": {"_0": {...}}) — clean single-key encoding is the
        // documented wire format for both the journal and the sync API.
        private enum Key: String, CodingKey {
            case addBook, updateBook, setCover, deleteBook, restoreBook
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            if let value = try container.decodeIfPresent(AddBook.self, forKey: .addBook) {
                self = .addBook(value)
            } else if let value = try container.decodeIfPresent(UpdateBook.self, forKey: .updateBook) {
                self = .updateBook(value)
            } else if let value = try container.decodeIfPresent(SetCover.self, forKey: .setCover) {
                self = .setCover(value)
            } else if let value = try container.decodeIfPresent(DeleteBook.self, forKey: .deleteBook) {
                self = .deleteBook(value)
            } else if let value = try container.decodeIfPresent(RestoreBook.self, forKey: .restoreBook) {
                self = .restoreBook(value)
            } else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown command op")
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: Key.self)
            switch self {
            case .addBook(let value): try container.encode(value, forKey: .addBook)
            case .updateBook(let value): try container.encode(value, forKey: .updateBook)
            case .setCover(let value): try container.encode(value, forKey: .setCover)
            case .deleteBook(let value): try container.encode(value, forKey: .deleteBook)
            case .restoreBook(let value): try container.encode(value, forKey: .restoreBook)
            }
        }
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

        public init(kind: String, filename: String, contentHash: String, size: Int64, stagedName: String) {
            self.kind = kind
            self.filename = filename
            self.contentHash = contentHash
            self.size = size
            self.stagedName = stagedName
        }
    }

    public struct StagedCover: Sendable, Codable, Equatable {
        public let filename: String
        public let contentHash: String
        public let stagedName: String

        public init(filename: String, contentHash: String, stagedName: String) {
            self.filename = filename
            self.contentHash = contentHash
            self.stagedName = stagedName
        }
    }

    public struct AddBook: Sendable, Codable, Equatable {
        public let bookID: UUID

        public init(
            bookID: UUID,
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
            formats: [StagedFormat],
            cover: StagedCover?
        ) {
            self.bookID = bookID
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
        }

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

        public init(bookID: UUID, edit: BookEdit) {
            self.bookID = bookID
            self.edit = edit
        }
    }

    public struct SetCover: Sendable, Codable, Equatable {
        public let bookID: UUID
        public let cover: StagedCover?

        public init(bookID: UUID, cover: StagedCover?) {
            self.bookID = bookID
            self.cover = cover
        }
    }

    public struct DeleteBook: Sendable, Codable, Equatable {
        public let bookID: UUID

        public init(bookID: UUID) {
            self.bookID = bookID
        }
    }

    public struct RestoreBook: Sendable, Codable, Equatable {
        public let bookID: UUID

        public init(bookID: UUID) {
            self.bookID = bookID
        }
    }
}
