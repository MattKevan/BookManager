import CryptoKit
import Foundation

/// Durable queue of changes that could not be written to the library because
/// the library folder was unreachable. Payloads and naming match the library
/// change store exactly, so draining is a file move into the library.
public struct Outbox: Sendable {
    /// The outbox root, exposed for drain's relative-path math (the outbox
    /// mirrors the library change store's `books/<bookID>/<deviceID>/…`
    /// layout under this root).
    public let outboxRoot: URL

    public init(root: URL) throws {
        outboxRoot = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    public func stage(
        change: Data,
        bookID: UUID,
        deviceID: UUID,
        clock: HybridLogicalClock
    ) throws -> URL {
        let directory = outboxRoot
            .appending(path: bookID.uuidString, directoryHint: .isDirectory)
            .appending(path: deviceID.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let digest = SHA256.hash(data: change).map { String(format: "%02x", $0) }.joined()
        let clockPart = "\(clock.physicalMilliseconds)-\(clock.logical)"
        let destination = directory.appending(path: "\(clockPart)-\(digest).amchange")
        if FileManager.default.fileExists(atPath: destination.path) {
            return destination
        }
        try change.write(to: destination, options: .atomic)
        return destination
    }

    public func pendingCount() throws -> Int {
        try pendingFiles().count
    }

    public func pendingFiles() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: outboxRoot.path) else { return [] }
        let enumerator = FileManager.default.enumerator(
            at: outboxRoot, includingPropertiesForKeys: [.isRegularFileKey]
        )
        return (enumerator?.compactMap { $0 as? URL } ?? [])
            .filter { $0.pathExtension == "amchange" }
            .sorted { $0.path < $1.path }
    }

    public func remove(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}
