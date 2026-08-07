import Foundation

public struct LibraryManifest: Codable, Equatable, Sendable {
    public let id: UUID
    public let formatVersion: Int
    public let createdAt: Date

    /// Format 2 = the journal storage era. Format 1 (Automerge change store)
    /// libraries are a hard break: `LibraryRepository.open` rejects them with
    /// `unsupportedFormat` — no migration (user decision).
    public init(id: UUID, formatVersion: Int = 2, createdAt: Date = .now) {
        self.id = id
        self.formatVersion = formatVersion
        self.createdAt = createdAt
    }
}
