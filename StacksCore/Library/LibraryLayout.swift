import Foundation

public struct LibraryLayout: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    public var controlRoot: URL { root.appending(path: ".bookmanager", directoryHint: .isDirectory) }
    public var manifestURL: URL { controlRoot.appending(path: "library.json") }
    public var changesRoot: URL { controlRoot.appending(path: "changes", directoryHint: .isDirectory) }
    public var bookChangesRoot: URL { changesRoot.appending(path: "books", directoryHint: .isDirectory) }
    public var libraryChangesRoot: URL { changesRoot.appending(path: "library", directoryHint: .isDirectory) }
    public var transactionsRoot: URL { controlRoot.appending(path: "transactions", directoryHint: .isDirectory) }
    public var trashRoot: URL { controlRoot.appending(path: "trash", directoryHint: .isDirectory) }
    public var recoveryRoot: URL { controlRoot.appending(path: "recovery", directoryHint: .isDirectory) }
    public var quarantineRoot: URL { controlRoot.appending(path: "quarantine", directoryHint: .isDirectory) }

    public func create(manifest: LibraryManifest) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        for directory in [
            bookChangesRoot,
            libraryChangesRoot,
            transactionsRoot,
            trashRoot,
            recoveryRoot,
            quarantineRoot
        ] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let data = try JSONEncoder.bookManager.encode(manifest)
        try data.write(to: manifestURL, options: .atomic)
    }

    public func readManifest() throws -> LibraryManifest {
        try JSONDecoder.bookManager.decode(
            LibraryManifest.self,
            from: Data(contentsOf: manifestURL)
        )
    }
}

extension JSONEncoder {
    static var bookManager: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var bookManager: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
