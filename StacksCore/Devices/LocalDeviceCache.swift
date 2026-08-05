import Foundation

/// A book record as persisted by the local device listing cache — a display
/// cache (instant device view on re-select or relaunch), not a metadata source.
public struct LocalCachedBook: Codable, Sendable, Equatable {
    public let fileName: String
    public let filePath: String
    public let fileSize: Int64
    public let title: String
    public let authors: [String]
    public let format: String
    public let isDRM: Bool
    public let isEnriched: Bool

    public init(
        fileName: String,
        filePath: String,
        fileSize: Int64,
        title: String,
        authors: [String],
        format: String,
        isDRM: Bool,
        isEnriched: Bool
    ) {
        self.fileName = fileName
        self.filePath = filePath
        self.fileSize = fileSize
        self.title = title
        self.authors = authors
        self.format = format
        self.isDRM = isDRM
        self.isEnriched = isEnriched
    }

    public init(record: DeviceBookRecord) {
        fileName = record.file.name
        filePath = record.file.path
        fileSize = record.file.size
        title = record.title
        authors = record.authors
        format = record.format
        isDRM = record.isDRM
        isEnriched = record.isEnriched
    }

    public func asDeviceBookRecord() -> DeviceBookRecord {
        DeviceBookRecord(
            file: DeviceFile(name: fileName, path: filePath, size: fileSize),
            title: title,
            authors: authors,
            format: format,
            isDRM: isDRM,
            isEnriched: isEnriched
        )
    }
}

/// The persisted listing for one device, keyed by vendor/product id.
public struct LocalDeviceSnapshot: Codable, Sendable, Equatable {
    public let key: String
    public let records: [LocalCachedBook]
    public let savedAt: Date

    public init(key: String, records: [LocalCachedBook], savedAt: Date) {
        self.key = key
        self.records = records
        self.savedAt = savedAt
    }
}

/// File-backed per-device listing cache. Loads are tolerant — a missing or
/// corrupt file degrades to nil, never throwing out of the caller's control.
public struct LocalDeviceCache: Sendable {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func load(key: String) throws -> LocalDeviceSnapshot? {
        let url = fileURL(for: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder.bookManager.decode(LocalDeviceSnapshot.self, from: data)
        } catch {
            // Corrupt or unreadable cache: degrade silently.
            return nil
        }
    }

    /// Atomic-ish: write to a temp file in the same directory, then replace or
    /// move into place.
    public func save(_ snapshot: LocalDeviceSnapshot) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder.bookManager.encode(snapshot)
        let url = fileURL(for: snapshot.key)
        let temp = directory.appending(path: "\(Self.sanitized(snapshot.key)).tmp-\(UUID().uuidString)")
        try data.write(to: temp, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } else {
            try FileManager.default.moveItem(at: temp, to: url)
        }
    }

    public func delete(key: String) {
        try? FileManager.default.removeItem(at: fileURL(for: key))
    }

    private func fileURL(for key: String) -> URL {
        directory.appending(path: "\(Self.sanitized(key)).json")
    }

    /// Filenames may only contain alphanumerics (the key derives from
    /// vendor/product ids, which are numeric — this guards against any future
    /// key that carries path separators).
    static func sanitized(_ key: String) -> String {
        String(key.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
}
