import Foundation

/// Phases of a Calibre library scan, surfaced to the UI while the scan runs
/// off the main actor.
public enum CalibreScanPhase: Sendable, Equatable {
    /// `CalibreReader.open` is copying the source `metadata.db` (Calibre
    /// embeds cover blobs — hundreds of MB for large libraries).
    case copyingDatabase
    /// Every book row is being read from the snapshot.
    case readingBooks
}

/// Result of a Calibre library scan: the book records + derived summary,
/// plus the still-open reader (the caller owns and closes it) used for
/// on-demand cover fetches during the import.
public struct CalibreScanResult: Sendable {
    public let reader: CalibreReader
    public let summary: CalibreLibrarySummary
    public let books: [CalibreBookRecord]

    public init(reader: CalibreReader, summary: CalibreLibrarySummary, books: [CalibreBookRecord]) {
        self.reader = reader
        self.summary = summary
        self.books = books
    }
}

/// Reads a Calibre library's summary + book records in a single pass, off the
/// caller's thread. The app runs this in a detached task: the metadata.db
/// copy and the full books read are far too heavy for the main actor — the
/// old synchronous path beachballed when opening a large library.
public struct CalibreLibraryScanner: Sendable {
    /// Scans the library at `libraryURL`, reporting phase changes through
    /// `progress` (called synchronously on the scanning thread). The summary
    /// is derived from the single `books()` read, so the books table is
    /// scanned only once instead of twice.
    ///
    /// Blob covers are deferred: `books(includeBlobCovers: false)` skips the
    /// `cover` column so a large library's embedded covers are never
    /// materialized in memory at once. The returned reader stays open so the
    /// import can fetch each cover on demand via `coverData(for:)` — the
    /// caller owns the reader and must close it.
    public static func scan(
        libraryURL: URL,
        progress: @Sendable (CalibreScanPhase) -> Void = { _ in }
    ) throws -> CalibreScanResult {
        progress(.copyingDatabase)
        let reader = try CalibreReader.open(libraryURL: libraryURL)
        do {
            progress(.readingBooks)
            let books = try reader.books(includeBlobCovers: false)
            let metadata = try reader.summaryMetadata()
            let summary = CalibreLibrarySummary(
                userVersion: metadata.userVersion,
                libraryID: metadata.libraryID,
                bookCount: books.count,
                formatCount: metadata.formatCount,
                titles: books.map(\.title)
            )
            return CalibreScanResult(reader: reader, summary: summary, books: books)
        } catch {
            try? reader.close()
            throw error
        }
    }
}
