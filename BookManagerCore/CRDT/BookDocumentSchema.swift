import Foundation

public struct VersionedValue<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public let value: Value
    public let clock: HybridLogicalClock

    public init(value: Value, clock: HybridLogicalClock) {
        self.value = value
        self.clock = clock
    }
}

public struct BookDocumentSchema: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var bookID: UUID?
    public var titles: [String: VersionedValue<String>]
    public var authors: [String: VersionedValue<[String]>]
    public var deletions: [String: VersionedValue<Bool>]

    public init(
        schemaVersion: Int = 1,
        bookID: UUID? = nil,
        titles: [String: VersionedValue<String>] = [:],
        authors: [String: VersionedValue<[String]>] = [:],
        deletions: [String: VersionedValue<Bool>] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.bookID = bookID
        self.titles = titles
        self.authors = authors
        self.deletions = deletions
    }
}

public struct ResolvedBook: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let title: String
    public let authors: [String]
    public let isDeleted: Bool
    public let modifiedClock: HybridLogicalClock
}
