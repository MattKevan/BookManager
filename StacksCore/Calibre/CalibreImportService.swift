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

/// Live progress update for one import run, delivered before and after each
/// decided book. `detail` is nil while a book is being processed (the UI shows
/// "Importing <title>…") and carries the outcome after it is decided.
public struct CalibreImportUpdate: Sendable, Equatable {
    /// Number of selected books decided so far (including the current one).
    public let completed: Int
    /// Total number of selected books.
    public let total: Int
    /// Title of the book currently being processed / most recently decided.
    public let currentTitle: String?
    /// Outcome detail after a book is decided; nil while processing.
    public let detail: String?

    public init(completed: Int, total: Int, currentTitle: String?, detail: String?) {
        self.completed = completed
        self.total = total
        self.currentTitle = currentTitle
        self.detail = detail
    }

    /// 0...1 fraction of selected books decided (1 when nothing is selected).
    public var fraction: Double { total > 0 ? Double(completed) / Double(total) : 1 }
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
        into repository: LibraryRepositoryImporting,
        progress: @Sendable (CalibreImportUpdate) -> Void = { _ in },
        coverProvider: @Sendable (Int) throws -> Data? = { _ in nil }
    ) async throws -> CalibreImportReport {
        let selectedIDs = selection.map(Set.init)
        let ordered = records.sorted { $0.calibreID < $1.calibreID }
        var progressRecord = readProgress(sourcePath: sourcePath, libraryID: libraryID, selection: selection)
        var items: [CalibreImportItem] = []

        // Likely-duplicate index, built once (O(N) total, not O(N²) — the old
        // code re-read the whole catalog for every book). A failure to load it
        // only disables the hint; it never fails a book or the import.
        var duplicateLookup: [String: UUID] = [:]
        if let candidates = try? await repository.allBooksForDuplicateCheck() {
            for candidate in candidates {
                let key = Self.duplicateKey(
                    title: candidate.title,
                    firstAuthor: candidate.authors.first ?? ""
                )
                if duplicateLookup[key] == nil { duplicateLookup[key] = candidate.id }
            }
        }

        let selectedCount = selectedIDs.map { set in
            ordered.filter { set.contains($0.calibreID) }.count
        } ?? ordered.count
        var decided = 0

        for record in ordered {
            if let selectedIDs, !selectedIDs.contains(record.calibreID) {
                continue
            }
            // Cancellation is checked per record (and per book inside
            // importOne): a cancelled import stops writing books at the next
            // boundary instead of draining the whole selection.
            try Task.checkCancellation()
            // Report before processing so the UI shows "Importing <title>…"
            // while a book's files are copied (large files take seconds).
            progress(CalibreImportUpdate(
                completed: decided, total: selectedCount,
                currentTitle: record.title, detail: nil
            ))
            let item: CalibreImportItem
            if progressRecord.completedBookIDs.contains(record.calibreID) {
                item = CalibreImportItem(
                    calibreID: record.calibreID, title: record.title, status: .skipped
                )
            } else {
                do {
                    switch try await importOne(
                        record, into: repository,
                        duplicateLookup: &duplicateLookup, coverProvider: coverProvider
                    ) {
                    case .imported(let book, let likelyDuplicate):
                        progressRecord.completedBookIDs.append(record.calibreID)
                        try writeProgress(progressRecord, sourcePath: sourcePath)
                        item = CalibreImportItem(
                            calibreID: record.calibreID, title: record.title,
                            status: .imported(book.id), likelyDuplicateOf: likelyDuplicate
                        )
                    case .duplicate(let matchingBookID):
                        // A duplicate is NOT completed: it was not copied. If the
                        // library copy is later removed, a re-run must be able to
                        // import it. Re-runs simply re-detect the duplicate.
                        item = CalibreImportItem(
                            calibreID: record.calibreID, title: record.title,
                            status: .duplicate(matchingBookID: matchingBookID)
                        )
                    }
                } catch {
                    // Failed books are NOT completed: a resume retries them.
                    item = CalibreImportItem(
                        calibreID: record.calibreID, title: record.title,
                        status: .failed(error.localizedDescription)
                    )
                }
            }
            items.append(item)
            decided += 1
            progress(CalibreImportUpdate(
                completed: decided, total: selectedCount,
                currentTitle: record.title, detail: Self.outcomeDetail(for: item.status)
            ))
        }
        return CalibreImportReport(items: items)
    }

    /// Short outcome text for the progress update's `detail`.
    private static func outcomeDetail(for status: CalibreImportItem.Status) -> String {
        switch status {
        case .imported: "Imported"
        case .duplicate: "Duplicate — already in library"
        case .failed(let message): "Failed: \(message)"
        case .skipped: "Skipped (already imported)"
        }
    }

    // MARK: - Per-book pipeline

    private enum ImportOutcome {
        case imported(book: IndexedBook, likelyDuplicateOf: UUID?)
        case duplicate(matchingBookID: UUID)
    }

    private func importOne(
        _ record: CalibreBookRecord,
        into repository: LibraryRepositoryImporting,
        duplicateLookup: inout [String: UUID],
        coverProvider: @Sendable (Int) throws -> Data?
    ) async throws -> ImportOutcome {
        // A book with any missing format file cannot be copied at all.
        if let missing = record.formats.first(where: { $0.isMissing }) {
            throw CalibreImportError.missingFormatFile(missing.name)
        }
        // Between-books cancellation lands here too (the check at the loop
        // top only fires when a cancelled task resumes there): never start
        // staging a new book under cancellation.
        try Task.checkCancellation()

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
        if let resolved = try await resolveCover(of: record, coverProvider: coverProvider) {
            stagedCover = resolved.staged
            coverData = resolved.data
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
        // Looked up in the pre-built index, which also registers every book
        // imported earlier in this run.
        var likelyDuplicate: UUID?
        if !record.title.isEmpty {
            likelyDuplicate = duplicateLookup[
                Self.duplicateKey(title: record.title, firstAuthor: record.authors.first?.name ?? "")
            ]
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
        // Register the imported book so a later record with the same normalized
        // title + first author is flagged (intra-run duplicate).
        if !record.title.isEmpty {
            let key = Self.duplicateKey(title: record.title, firstAuthor: record.authors.first?.name ?? "")
            if duplicateLookup[key] == nil { duplicateLookup[key] = book.id }
        }
        return .imported(book: book, likelyDuplicateOf: likelyDuplicate)
    }

    /// Resolves the cover for a book: the record's own cover when present,
    /// otherwise a deferred blob cover fetched on demand from the still-open
    /// reader (a fetch failure degrades to no cover — covers are optional
    /// metadata, never a reason to fail a book). Returns the staged cover file
    /// and its bytes; nil when the book has no cover.
    private func resolveCover(
        of record: CalibreBookRecord,
        coverProvider: @Sendable (Int) throws -> Data?
    ) async throws -> (staged: BookFolder.StagedFile, data: Data)? {
        var cover = record.cover
        if cover == nil, let data = try? coverProvider(record.calibreID), !data.isEmpty {
            cover = .blob(data)
        }
        switch cover {
        case .blob(let data):
            let tempDir = layout.controlRoot.appending(path: "calibre-covers", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let tempURL = tempDir.appending(path: "\(UUID().uuidString).jpg")
            try data.write(to: tempURL)
            let staged = try await folder.stage(from: tempURL)
            let bytes = try Data(contentsOf: staged.url)
            try? FileManager.default.removeItem(at: tempURL)
            return (staged, bytes)
        case .file(let url):
            let staged = try await folder.stage(from: url)
            return (staged, try Data(contentsOf: staged.url))
        case nil:
            return nil
        }
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

    /// Normalized (title, first-author) key for the likely-duplicate index.
    /// Both halves are already punctuation-stripped and lowercased by
    /// `ImportService.normalized`; the separator cannot collide with either.
    private static func duplicateKey(title: String, firstAuthor: String) -> String {
        "\(ImportService.normalized(title))|\(ImportService.normalized(firstAuthor))"
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
