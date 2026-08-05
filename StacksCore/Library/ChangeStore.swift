import CryptoKit
import Foundation

public actor ChangeStore {
    private let layout: LibraryLayout

    public init(layout: LibraryLayout) {
        self.layout = layout
    }

    public func writeBookChange(
        _ data: Data,
        bookID: UUID,
        deviceID: UUID,
        clock: HybridLogicalClock
    ) throws -> URL {
        let directory = layout.bookChangesRoot
            .appending(path: bookID.uuidString, directoryHint: .isDirectory)
            .appending(path: deviceID.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let clockPart = "\(clock.physicalMilliseconds)-\(clock.logical)"
        let destination = directory.appending(path: "\(clockPart)-\(digest).amchange")

        if FileManager.default.fileExists(atPath: destination.path) {
            return destination
        }

        try data.write(to: destination, options: .atomic)
        return destination
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
}
