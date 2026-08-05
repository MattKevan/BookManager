import Foundation

/// Phases of a Calibre library scan, surfaced to the UI while the scan runs
/// off the main actor.
public enum CalibreScanPhase: Sendable, Equatable {
    /// `CalibreReader.open` is copying the source `metadata.db` (Calibre
    /// embeds cover blobs — hundreds of MB for large libraries).
    case copyingDatabase
    /// Every book row (with cover blobs) is being read from the snapshot.
    case readingBooks
}

/// Reads a Calibre library's summary + book records in a single pass, off the
/// caller's thread. The app runs this in a detached task: the metadata.db
/// copy and the full books read (which hydrates every cover blob) are far too
/// heavy for the main actor — the old synchronous path beachballed when
/// opening a large library.
public struct CalibreLibraryScanner: Sendable {
    /// Scans the library at `libraryURL`, reporting phase changes through
    /// `progress` (called synchronously on the scanning thread). The summary
    /// is derived from the single `books()` read, so the books table — with
    /// its cover blobs — is scanned only once instead of twice.
    public static func scan(
        libraryURL: URL,
        progress: @Sendable (CalibreScanPhase) -> Void = { _ in }
    ) throws -> (summary: CalibreLibrarySummary, books: [CalibreBookRecord]) {
        progress(.copyingDatabase)
        let reader = try CalibreReader.open(libraryURL: libraryURL)
        defer { try? reader.close() }
        progress(.readingBooks)
        let books = try reader.books()
        let metadata = try reader.summaryMetadata()
        return (
            summary: CalibreLibrarySummary(
                userVersion: metadata.userVersion,
                libraryID: metadata.libraryID,
                bookCount: books.count,
                formatCount: metadata.formatCount,
                titles: books.map(\.title)
            ),
            books: books
        )
    }
}
