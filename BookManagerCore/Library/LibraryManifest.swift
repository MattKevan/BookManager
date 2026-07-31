import Foundation

public struct LibraryManifest: Codable, Equatable, Sendable {
    public let id: UUID
    public let formatVersion: Int
    public let createdAt: Date

    public init(id: UUID, formatVersion: Int = 1, createdAt: Date = .now) {
        self.id = id
        self.formatVersion = formatVersion
        self.createdAt = createdAt
    }
}
