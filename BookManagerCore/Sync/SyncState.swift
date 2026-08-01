import Foundation

/// Local record of which change files have been applied to a library's
/// catalog, plus the outbox root, persisted under Application Support
/// (never in the synced library). Missing or corrupt state degrades to
/// "empty" — it must never block ingest.
public struct SyncState: Sendable {
    public let libraryID: UUID
    public let outbox: Outbox
    private let stateURL: URL

    public init(root: URL, libraryID: UUID) throws {
        self.libraryID = libraryID
        outbox = try Outbox(root: root
            .appending(path: "Outbox", directoryHint: .isDirectory)
            .appending(path: libraryID.uuidString, directoryHint: .isDirectory))
        let dir = root.appending(path: "SyncState", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        stateURL = dir.appending(path: "\(libraryID.uuidString).json")
    }

    public var fileURL: URL { stateURL }

    public func appliedFingerprints() throws -> Set<String> {
        guard let data = try? Data(contentsOf: stateURL),
              let set = try? JSONDecoder().decode(Set<String>.self, from: data) else {
            return []
        }
        return set
    }

    public func recordApplied(_ fingerprints: Set<String>) throws {
        let merged = try appliedFingerprints().union(fingerprints)
        let data = try JSONEncoder().encode(merged)
        try data.write(to: stateURL, options: .atomic)
    }

    public func reset() throws {
        try? FileManager.default.removeItem(at: stateURL)
    }
}
