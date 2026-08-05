import Foundation

public struct DeviceBookRecord: Sendable, Equatable, Identifiable {
    public let file: DeviceFile
    public let title: String
    public let authors: [String]
    public let format: String
    public let isDRM: Bool
    /// False until `DeviceBookScanner.enrich` has parsed the file. The browse
    /// list is built without downloads (Kindle MTP ops cost ~24s each, so a
    /// full metadata pass over a 178-book device takes ~71 minutes); details
    /// are fetched lazily for the selected row.
    public let isEnriched: Bool

    public init(
        file: DeviceFile,
        title: String,
        authors: [String],
        format: String,
        isDRM: Bool,
        isEnriched: Bool = false
    ) {
        self.file = file
        self.title = title
        self.authors = authors
        self.format = format
        self.isDRM = isDRM
        self.isEnriched = isEnriched
    }

    public var id: String { file.id }
}

/// Lists a device's books by filename (fast, no downloads) and lazily enriches
/// individual records with parsed metadata + the DRM flag. A full-metadata pass
/// downloads every file, which is prohibitively slow on MTP devices whose USB
/// link sleeps between operations — so browse uses `list` and the UI calls
/// `enrich` only for the row the user selects.
public struct DeviceBookScanner: Sendable {
    private static let bookExtensions: Set<String> = ["mobi", "azw", "azw3", "epub", "pdf", "kfx", "prc", "txt"]

    private let transport: any DeviceTransport

    public init(transport: any DeviceTransport) {
        self.transport = transport
    }

    /// One listing operation, no downloads. Records carry filename-stem titles
    /// (Kindle filenames are "Title - Author.ext"), no authors, and no DRM
    /// knowledge until `enrich` runs.
    public func list(in folder: DeviceFolder) async throws -> [DeviceBookRecord] {
        let files = try await transport.listFiles(in: folder)
            .filter { !$0.name.hasPrefix(".") && Self.isBookFile($0) }
        return files.map { file in
            let ext = URL(fileURLWithPath: file.name).pathExtension.lowercased()
            return DeviceBookRecord(
                file: file,
                title: stem(of: file.name),
                authors: [],
                format: ext.uppercased(),
                isDRM: false
            )
        }
    }

    /// Applies a parsed `metadata.calibre` cache to listed records: any record
    /// whose file matches a cache entry (lowercased path + exact size) gets the
    /// cached title/authors/DRM flag and is marked enriched, so the UI shows
    /// real metadata instantly and the lazy per-row enrich skips it. Unmatched
    /// records (new books, Amazon Wi-Fi downloads, size-changed files) keep
    /// their filename-only state. No downloads happen here.
    public func apply(cache: CalibreCache, to records: [DeviceBookRecord]) -> [DeviceBookRecord] {
        records.map { record in
            guard let entry = cache.entry(matching: record.file) else { return record }
            return DeviceBookRecord(
                file: record.file,
                title: entry.title.isEmpty ? record.title : entry.title,
                authors: entry.authors,
                format: record.format,
                isDRM: entry.isDRM,
                isEnriched: true
            )
        }
    }

    /// Downloads the record's file and parses it for real title/authors/DRM.
    /// Never throws on an unreadable or malformed file — it degrades to the
    /// filename-only record marked enriched, so the UI stops offering to
    /// retry. A failed download degrades the same way.
    public func enrich(_ record: DeviceBookRecord) async throws -> DeviceBookRecord {
        let ext = URL(fileURLWithPath: record.file.name).pathExtension.lowercased()
        guard Self.bookExtensions.contains(ext) else {
            return DeviceBookRecord(
                file: record.file, title: record.title, authors: record.authors,
                format: record.format, isDRM: record.isDRM, isEnriched: true
            )
        }

        let scratch = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let localURL = scratch.appending(path: record.file.name)
        guard (try? await transport.download(record.file, to: localURL)) != nil else {
            return DeviceBookRecord(
                file: record.file, title: record.title, authors: [],
                format: record.format, isDRM: false, isEnriched: true
            )
        }

        switch ext {
        case "mobi", "azw", "azw3":
            do {
                let content = try MobiReader(url: localURL).extract()
                return DeviceBookRecord(
                    file: record.file,
                    title: content.title.isEmpty ? record.title : content.title,
                    authors: content.authors,
                    format: record.format,
                    isDRM: false,
                    isEnriched: true
                )
            } catch MobiReaderError.drmProtected {
                return DeviceBookRecord(
                    file: record.file, title: record.title, authors: [],
                    format: record.format, isDRM: true, isEnriched: true
                )
            } catch {
                return DeviceBookRecord(
                    file: record.file, title: record.title, authors: [],
                    format: record.format, isDRM: false, isEnriched: true
                )
            }
        case "epub", "pdf":
            let kind = MetadataExtractor.kind(for: localURL)
            let extracted = kind.flatMap { try? MetadataExtractor.extract(from: localURL, kind: $0) }
            return DeviceBookRecord(
                file: record.file,
                title: (extracted.map { $0.title.isEmpty ? record.title : $0.title }) ?? record.title,
                authors: extracted?.authors ?? [],
                format: record.format,
                isDRM: false,
                isEnriched: true
            )
        default: // kfx, prc, txt — filename-only listing (KFX shown as unsupported by the UI)
            return DeviceBookRecord(
                file: record.file, title: record.title, authors: [],
                format: record.format, isDRM: false, isEnriched: true
            )
        }
    }

    private static func isBookFile(_ file: DeviceFile) -> Bool {
        bookExtensions.contains(URL(fileURLWithPath: file.name).pathExtension.lowercased())
    }

    private func stem(of name: String) -> String {
        URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
    }
}
