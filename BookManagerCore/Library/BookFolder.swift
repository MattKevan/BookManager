import CryptoKit
import Foundation

/// Owns the physical book folders inside a library: staging, materialization,
/// metadata-driven renames, and trash/restore. All multi-step mutations are
/// journaled so an interrupted operation is visible in diagnostics.
public actor BookFolder {
    public struct StagedFile: Sendable {
        public let kind: String
        public let contentHash: String
        public let size: Int64
        public let url: URL

        public init(kind: String, contentHash: String, size: Int64, url: URL) {
            self.kind = kind
            self.contentHash = contentHash
            self.size = size
            self.url = url
        }
    }

    private struct JournalEntry: Codable {
        var operation: String
        var bookID: UUID
        var oldPath: String?
        var newPath: String?
    }

    private let layout: LibraryLayout
    private let manager = FileManager.default

    public init(layout: LibraryLayout) {
        self.layout = layout
    }

    private var stagingRoot: URL {
        layout.controlRoot.appending(path: "staging", directoryHint: .isDirectory)
    }

    public func stage(from sourceURL: URL) throws -> StagedFile {
        let kind = sourceURL.pathExtension.uppercased()
        let stagingDir = stagingRoot.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try manager.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let destination = stagingDir.appending(path: sourceURL.lastPathComponent)
        try manager.copyItem(at: sourceURL, to: destination)
        let data = try Data(contentsOf: destination)
        let hash = Self.contentHash(data)
        return StagedFile(kind: kind, contentHash: hash, size: Int64(data.count), url: destination)
    }

    public static func contentHash(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined().prefix(32).description
    }

    @discardableResult
    public func materialize(
        bookID: UUID,
        resolved: ResolvedBook,
        staged: [StagedFile],
        cover: Data?
    ) throws -> (path: String, formats: [BookFormatValue]) {
        let path = CanonicalPathBuilder.relativeDirectory(
            bookID: bookID,
            title: resolved.title,
            authors: resolved.authors
        )
        let directory = bookDirectoryURL(relativePath: path)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)

        var formats: [BookFormatValue] = []
        for file in staged {
            let filename = CanonicalPathBuilder.formatFileName(
                title: resolved.title,
                authors: resolved.authors,
                kind: file.kind
            )
            let destination = directory.appending(path: filename)
            try manager.moveItem(at: file.url, to: destination)
            formats.append(
                BookFormatValue(
                    kind: file.kind,
                    filename: filename,
                    contentHash: file.contentHash,
                    size: file.size
                )
            )
        }

        if let cover {
            try cover.write(to: directory.appending(path: "cover.jpg"), options: .atomic)
        }

        try OpfGenerator.opfData(bookID: bookID, resolved: resolved)
            .write(to: directory.appending(path: "metadata.opf"), options: .atomic)

        if let rawMetadata = resolved.rawMetadata, !rawMetadata.isEmpty {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(rawMetadata)
                .write(to: directory.appending(path: "raw_metadata.json"), options: .atomic)
        }

        return (path, formats)
    }

    public func trash(bookID: UUID, relativePath: String) throws {
        let journal = try begin(operation: "trash", bookID: bookID, oldPath: relativePath, newPath: nil)
        defer { try? end(journal) }
        let source = bookDirectoryURL(relativePath: relativePath)
        let trashDir = layout.trashRoot.appending(path: bookID.uuidString, directoryHint: .isDirectory)
        if manager.fileExists(atPath: source.path) {
            try manager.createDirectory(at: layout.trashRoot, withIntermediateDirectories: true)
            try manager.moveItem(at: source, to: trashDir)
        }
    }

    public func restore(bookID: UUID, relativePath: String) throws -> String {
        let trashDir = layout.trashRoot.appending(path: bookID.uuidString, directoryHint: .isDirectory)
        guard manager.fileExists(atPath: trashDir.path) else {
            throw BookFolderError.trashEntryMissing(bookID)
        }
        let target = bookDirectoryURL(relativePath: relativePath)
        try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let journal = try begin(operation: "restore", bookID: bookID, oldPath: relativePath, newPath: relativePath)
        defer { try? end(journal) }
        try manager.moveItem(at: trashDir, to: target)
        return relativePath
    }

    public func rename(
        bookID: UUID,
        from oldPath: String,
        to newPath: String,
        oldFormats: [BookFormatValue],
        newFormats: [BookFormatValue]
    ) throws {
        guard oldPath != newPath else { return }
        let oldDir = bookDirectoryURL(relativePath: oldPath)
        guard manager.fileExists(atPath: oldDir.path) else { return }
        let newDir = bookDirectoryURL(relativePath: newPath)
        try manager.createDirectory(at: newDir.deletingLastPathComponent(), withIntermediateDirectories: true)

        let journal = try begin(operation: "rename", bookID: bookID, oldPath: oldPath, newPath: newPath)
        defer { try? end(journal) }

        // Move the folder first, then rename format files whose canonical name changed.
        try manager.moveItem(at: oldDir, to: newDir)
        for old in oldFormats {
            guard let new = newFormats.first(where: { $0.kind == old.kind }),
                  new.filename != old.filename else {
                continue
            }
            let oldFile = newDir.appending(path: old.filename)
            let newFile = newDir.appending(path: new.filename)
            if manager.fileExists(atPath: oldFile.path) && !manager.fileExists(atPath: newFile.path) {
                try manager.moveItem(at: oldFile, to: newFile)
            }
        }
    }

    public func formatFileURL(relativePath: String, filename: String) -> URL {
        bookDirectoryURL(relativePath: relativePath).appending(path: filename)
    }

    public func bookDirectoryURL(relativePath: String) -> URL {
        layout.root.appending(path: relativePath, directoryHint: .isDirectory)
    }

    public func trashDirectoryURL(bookID: UUID) -> URL {
        layout.trashRoot.appending(path: bookID.uuidString, directoryHint: .isDirectory)
    }

    /// Journal entries left behind by interrupted mutations — the read-only
    /// surface diagnostics use to surface incomplete operations.
    public func pendingJournalEntries() throws -> [URL] {
        guard manager.fileExists(atPath: layout.transactionsRoot.path) else { return [] }
        return try manager.contentsOfDirectory(
            at: layout.transactionsRoot,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
    }

    private func begin(operation: String, bookID: UUID, oldPath: String?, newPath: String?) throws -> URL {
        try manager.createDirectory(at: layout.transactionsRoot, withIntermediateDirectories: true)
        let entry = JournalEntry(operation: operation, bookID: bookID, oldPath: oldPath, newPath: newPath)
        let url = layout.transactionsRoot.appending(path: "\(UUID().uuidString).json")
        let data = try JSONEncoder().encode(entry)
        try data.write(to: url, options: .atomic)
        return url
    }

    private func end(_ journal: URL) throws {
        try manager.removeItem(at: journal)
    }
}

public enum BookFolderError: Error, Equatable {
    case trashEntryMissing(UUID)
}
