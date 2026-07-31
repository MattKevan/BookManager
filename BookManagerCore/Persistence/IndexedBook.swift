import Foundation
import GRDB

public struct IndexedBook: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let title: String
    public let authors: [String]
    public let modifiedMilliseconds: Int64
    public let isDeleted: Bool
    public let snapshot: Data

    public init(
        id: UUID,
        title: String,
        authors: [String],
        modifiedMilliseconds: Int64,
        isDeleted: Bool,
        snapshot: Data
    ) {
        self.id = id
        self.title = title
        self.authors = authors
        self.modifiedMilliseconds = modifiedMilliseconds
        self.isDeleted = isDeleted
        self.snapshot = snapshot
    }
}

extension IndexedBook: FetchableRecord, PersistableRecord, TableRecord {
    public static let databaseTableName = "book"

    public enum Columns {
        static let id = Column("id")
        static let title = Column("title")
        static let authors = Column("authors")
        static let modifiedMilliseconds = Column("modifiedMilliseconds")
        static let isDeleted = Column("isDeleted")
        static let snapshot = Column("snapshot")
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.authors == rhs.authors
            && lhs.modifiedMilliseconds == rhs.modifiedMilliseconds
            && lhs.isDeleted == rhs.isDeleted
    }
}
