import CryptoKit
import Foundation

public actor ChangeStore {
    /// Result of a change write: the destination URL plus whether this call
    /// created the file (vs. deduplicating onto an identical existing change).
    /// Callers that roll back a failed multi-step edit must only delete files
    /// they actually created.
    public struct WriteResult: Sendable {
        public let url: URL
        public let created: Bool

        public init(url: URL, created: Bool) {
            self.url = url
            self.created = created
        }
    }

    private let layout: LibraryLayout

    public init(layout: LibraryLayout) {
        self.layout = layout
    }

    public func writeBookChange(
        _ data: Data,
        bookID: UUID,
        deviceID: UUID,
        clock: HybridLogicalClock
    ) throws -> WriteResult {
        let directory = layout.bookChangesRoot
            .appending(path: bookID.uuidString, directoryHint: .isDirectory)
            .appending(path: deviceID.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let clockPart = "\(clock.physicalMilliseconds)-\(clock.logical)"
        let destination = directory.appending(path: "\(clockPart)-\(digest).amchange")

        if FileManager.default.fileExists(atPath: destination.path) {
            return WriteResult(url: destination, created: false)
        }

        try data.write(to: destination, options: .atomic)
        return WriteResult(url: destination, created: true)
    }

    public func bookChanges(bookID: UUID) throws -> [Data] {
        let bookRoot = layout.bookChangesRoot
            .appending(path: bookID.uuidString, directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: bookRoot.path) else {
            return []
        }
        let keys: [URLResourceKey] = [.isRegularFileKey]
        let files = FileManager.default.enumerator(
            at: bookRoot,
            includingPropertiesForKeys: keys
        )?.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "amchange" }
            .sorted { $0.path < $1.path } ?? []
        return try files.map { try Data(contentsOf: $0) }
    }

    public func bookIDs() throws -> [UUID] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: layout.bookChangesRoot,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        return urls.compactMap { UUID(uuidString: $0.lastPathComponent) }
            .sorted { $0.uuidString < $1.uuidString }
    }

    /// The `.amchange` files for one book (URLs, not decoded data) — the
    /// ingest path needs the source URLs to quarantine corrupt files.
    /// Mirrors `bookChanges(bookID:)`'s enumeration exactly.
    public func bookChangeFiles(bookID: UUID) throws -> [URL] {
        let bookRoot = layout.bookChangesRoot
            .appending(path: bookID.uuidString, directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: bookRoot.path) else {
            return []
        }
        let keys: [URLResourceKey] = [.isRegularFileKey]
        return (FileManager.default.enumerator(
            at: bookRoot,
            includingPropertiesForKeys: keys
        )?.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "amchange" }
            .sorted { $0.path < $1.path }) ?? []
    }

    /// True when a change file's name digest (which this store derives from
    /// the file's content) does not match the content — i.e. the file was
    /// never written by the change store. Shared by ingest and rebuild so the
    /// quarantine policy is defined in exactly one place.
    public static func hasCorruptDigest(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        let expected = sha256Hex(data)
        let name = url.lastPathComponent
        guard name.hasSuffix(".amchange") else { return false }
        let base = name.dropLast(".amchange".count)
        guard let dash = base.lastIndex(of: "-") else { return false }
        let digest = base[dash...].dropFirst()
        return digest != expected
    }

    /// Moves a corrupt change file out of the change store into quarantine.
    /// Quarantine is one-way (nothing re-imports it) — only call for files
    /// whose name digest mismatches content, never for valid-but-stuck
    /// changes.
    public func quarantine(_ url: URL) throws -> URL {
        let dir = layout.quarantineRoot
            .appending(path: Date().timeIntervalSince1970.description, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let destination = dir.appending(path: "\(UUID().uuidString)-\(url.lastPathComponent)")
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
