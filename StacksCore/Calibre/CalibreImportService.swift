import CryptoKit
import Foundation

/// Resumable import progress for one Calibre source library.
/// Written atomically to `<control root>/calibre-imports/<sourcePathHash>/progress.json`
/// after every completed book so an interrupted import can resume.
public struct CalibreImportProgress: Codable, Sendable, Equatable {
    public var sourcePath: String
    public var libraryID: String
    /// nil = all books of the source library were selected.
    public var selection: [Int]?
    public var completedBookIDs: [Int]

    public init(sourcePath: String, libraryID: String, selection: [Int]?, completedBookIDs: [Int]) {
        self.sourcePath = sourcePath
        self.libraryID = libraryID
        self.selection = selection
        self.completedBookIDs = completedBookIDs
    }
}

public struct CalibreImportItem: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case imported(UUID)
        case duplicate(matchingBookID: UUID)
        case failed(String)
        case skipped
    }

    public let calibreID: Int
    public let title: String
    public let status: Status
    /// When the imported book's normalized title + first author match an
    /// existing library book, that book's id. Never merged silently.
    public let likelyDuplicateOf: UUID?

    public init(calibreID: Int, title: String, status: Status, likelyDuplicateOf: UUID? = nil) {
        self.calibreID = calibreID
        self.title = title
        self.status = status
        self.likelyDuplicateOf = likelyDuplicateOf
    }
}

public struct CalibreImportReport: Sendable, Equatable {
    public let items: [CalibreImportItem]

    public init(items: [CalibreImportItem]) {
        self.items = items
    }

    public var imported: [CalibreImportItem] {
        items.filter { if case .imported = $0.status { return true }; return false }
    }

    public var duplicates: [CalibreImportItem] {
        items.filter { if case .duplicate = $0.status { return true }; return false }
    }

    public var failed: [CalibreImportItem] {
        items.filter { if case .failed = $0.status { return true }; return false }
    }

    public var skipped: [CalibreImportItem] {
        items.filter { if case .skipped = $0.status { return true }; return false }
    }

    public var summary: String {
        "\(imported.count) imported, \(duplicates.count) duplicates, \(failed.count) failed, \(skipped.count) skipped"
    }
}

public enum CalibreImportError: Error, LocalizedError, Equatable {
    case missingFormatFile(String)

    public var errorDescription: String? {
        switch self {
        case .missingFormatFile(let name):
            return "missing format file: \(name)"
        }
    }
}

/// Imports a copy of a Calibre library (as `CalibreBookRecord`s read by
/// `CalibreReader`) into a Stacks library through the repository,
/// mirroring `ImportService`'s staged pipeline.
///
/// Book-level semantics: if ANY format file of a book is an exact duplicate
/// (its content hash already exists in the library), the whole book reports
/// `.duplicate` and none of its files are copied — never a silent partial
/// copy. If ANY format file is missing on disk, the book reports `.failed`.
///
/// Progress is recorded per book so a re-run with the same source path skips
/// already-completed books (`.skipped`) instead of re-copying them.
public actor CalibreImportService {
    private let layout: LibraryLayout
    private let folder: BookFolder

    public init(layout: LibraryLayout) {
        self.layout = layout
        folder = BookFolder(layout: layout)
    }

    /// Imports the selected records. `selection == nil` selects every record;
    /// otherwise only records whose `calibreID` is in `selection` (a selected
    /// id without a record is skipped silently). Items are ordered by
    /// `calibreID` for stable reports.
    public func importBooks(
        _ records: [CalibreBookRecord],
        from sourcePath: String,
        libraryID: String,
        selection: [Int]?,
        into repository: LibraryRepositoryImporting
    ) async throws -> CalibreImportReport {
        let selectedIDs = selection.map(Set.init)
        let ordered = records.sorted { $0.calibreID < $1.calibreID }
        var progress = readProgress(sourcePath: sourcePath, libraryID: libraryID, selection: selection)
        var items: [CalibreImportItem] = []

        for record in ordered {
            if let selectedIDs, !selectedIDs.contains(record.calibreID) {
                continue
            }
            if progress.completedBookIDs.contains(record.calibreID) {
                items.append(CalibreImportItem(
                    calibreID: record.calibreID, title: record.title, status: .skipped
                ))
                continue
            }
            do {
                switch try await importOne(record, into: repository) {
                case .imported(let book, let likelyDuplicate):
                    progress.completedBookIDs.append(record.calibreID)
                    try writeProgress(progress, sourcePath: sourcePath)
                    items.append(CalibreImportItem(
                        calibreID: record.calibreID, title: record.title,
                        status: .imported(book.id), likelyDuplicateOf: likelyDuplicate
                    ))
                case .duplicate(let matchingBookID):
                    // A duplicate is NOT completed: it was not copied. If the
                    // library copy is later removed, a re-run must be able to
                    // import it. Re-runs simply re-detect the duplicate.
                    items.append(CalibreImportItem(
                        calibreID: record.calibreID, title: record.title,
                        status: .duplicate(matchingBookID: matchingBookID)
                    ))
                }
            } catch {
                // Failed books are NOT completed: a resume retries them.
                items.append(CalibreImportItem(
                    calibreID: record.calibreID, title: record.title,
                    status: .failed(error.localizedDescription)
                ))
            }
        }
        return CalibreImportReport(items: items)
    }

    // MARK: - Per-book pipeline

    private enum ImportOutcome {
        case imported(book: IndexedBook, likelyDuplicateOf: UUID?)
        case duplicate(matchingBookID: UUID)
    }

    private func importOne(
        _ record: CalibreBookRecord,
        into repository: LibraryRepositoryImporting
    ) async throws -> ImportOutcome {
        // A book with any missing format file cannot be copied at all.
        if let missing = record.formats.first(where: { $0.isMissing }) {
            throw CalibreImportError.missingFormatFile(missing.name)
        }

        var staged: [BookFolder.StagedFile] = []
        var stagedCover: BookFolder.StagedFile?
        defer {
            // materialize() consumes the format staged files on success; every
            // other exit, and the cover staged copy (never consumed — the
            // repository writes covers from Data), must be removed so the
            // synced .bookmanager/staging area never leaks files or empty
            // per-import directories.
            for file in staged {
                try? FileManager.default.removeItem(at: file.url)
                try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent())
            }
            if let stagedCover {
                try? FileManager.default.removeItem(at: stagedCover.url)
                try? FileManager.default.removeItem(at: stagedCover.url.deletingLastPathComponent())
            }
        }

        // Stage every format file through the folder's staging pipeline.
        for format in record.formats {
            staged.append(try await folder.stage(from: format.sourceURL))
        }

        // Cover: stage a copy (blob → temp file) and pass the staged bytes as
        // the cover Data the repository stores and materializes.
        var coverData: Data?
        switch record.cover {
        case .blob(let data):
            let tempDir = layout.controlRoot.appending(path: "calibre-covers", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let tempURL = tempDir.appending(path: "\(UUID().uuidString).jpg")
            try data.write(to: tempURL)
            stagedCover = try await folder.stage(from: tempURL)
            coverData = try Data(contentsOf: stagedCover!.url)
            try? FileManager.default.removeItem(at: tempURL)
        case .file(let url):
            stagedCover = try await folder.stage(from: url)
            coverData = try Data(contentsOf: stagedCover!.url)
        case nil:
            break
        }

        // Exact-duplicate gate: if ANY staged format hash already exists in the
        // library, the whole book is a duplicate (never a silent partial copy).
        for file in staged {
            let matches = try await repository.bookIDs(byFormatHash: file.contentHash)
            if let first = matches.first {
                return .duplicate(matchingBookID: first)
            }
        }

        // Likely-duplicate hint (never merged silently — surfaced in the report).
        var likelyDuplicate: UUID?
        if !record.title.isEmpty {
            let candidates = try await repository.allBooksForDuplicateCheck()
            let normalizedTitle = ImportService.normalized(record.title)
            let firstAuthor = record.authors.first.map { ImportService.normalized($0.name) } ?? ""
            likelyDuplicate = candidates.first {
                ImportService.normalized($0.title) == normalizedTitle
                    && ($0.authors.first.map(ImportService.normalized) ?? "") == firstAuthor
            }?.id
        }

        let metadata = NewBookMetadata(
            title: record.title,
            authors: record.authors.map(\.name),
            series: record.series,
            seriesIndex: record.seriesIndex,
            tags: record.tags,
            rating: record.rating,
            publisher: record.publisher,
            publicationDate: record.publicationDate,
            addedDate: record.addedDate,
            languages: record.languages,
            identifiers: record.identifiers,
            comments: record.comments,
            rawMetadata: record.rawMetadata.isEmpty ? nil : record.rawMetadata
        )
        let book = try await repository.createBook(metadata: metadata, staged: staged, cover: coverData)
        return .imported(book: book, likelyDuplicateOf: likelyDuplicate)
    }

    // MARK: - Progress record

    private func readProgress(sourcePath: String, libraryID: String, selection: [Int]?) -> CalibreImportProgress {
        let url = Self.progressFileURL(sourcePath: sourcePath, layout: layout)
        // A corrupt or partial progress file means "no progress": tolerate it.
        guard let data = try? Data(contentsOf: url),
              let progress = try? JSONDecoder().decode(CalibreImportProgress.self, from: data) else {
            return CalibreImportProgress(
                sourcePath: sourcePath, libraryID: libraryID, selection: selection, completedBookIDs: []
            )
        }
        return progress
    }

    private func writeProgress(_ progress: CalibreImportProgress, sourcePath: String) throws {
        let url = Self.progressFileURL(sourcePath: sourcePath, layout: layout)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(progress)
        try data.write(to: url, options: .atomic)
    }

    /// SHA-256 of the canonical source path, first 32 hex chars.
    static func sourcePathHash(_ path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(32).description
    }

    static func progressFileURL(sourcePath: String, layout: LibraryLayout) -> URL {
        layout.controlRoot
            .appending(path: "calibre-imports", directoryHint: .isDirectory)
            .appending(path: sourcePathHash(sourcePath), directoryHint: .isDirectory)
            .appending(path: "progress.json")
    }
}
