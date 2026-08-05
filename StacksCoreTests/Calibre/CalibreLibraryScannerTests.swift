import Foundation
import Testing
@testable import StacksCore

@Suite
struct CalibreLibraryScannerTests {
    @Test
    func scanMatchesPerCallReaderReads() throws {
        let library = try CalibreFixture.makeLibrary(named: "scanner-match-\(UUID().uuidString)")
        let scanned = try CalibreLibraryScanner.scan(libraryURL: library)

        let reader = try CalibreReader.open(libraryURL: library)
        defer { try? reader.close() }
        let expectedBooks = try reader.books()
        let expectedSummary = try reader.summary()
        defer { try? scanned.reader.close() }

        // The single-pass scan must produce exactly the same records as a
        // direct books() read (payload JSON is deterministically key-sorted).
        #expect(scanned.books == expectedBooks)
        // Summary identity fields are unchanged; titles are derived from the
        // records (post-OPF), which is what the wizard actually displays.
        #expect(scanned.summary.userVersion == expectedSummary.userVersion)
        #expect(scanned.summary.libraryID == expectedSummary.libraryID)
        #expect(scanned.summary.bookCount == expectedSummary.bookCount)
        #expect(scanned.summary.formatCount == expectedSummary.formatCount)
        #expect(scanned.summary.titles == scanned.books.map(\.title))
    }

    @Test
    func scanReportsPhasesInOrder() throws {
        let library = try CalibreFixture.makeLibrary(named: "scanner-phases-\(UUID().uuidString)")
        let phases = LockedBox<[CalibreScanPhase]>([])
        let scanned = try CalibreLibraryScanner.scan(libraryURL: library) { phases.append($0) }
        defer { try? scanned.reader.close() }
        #expect(phases.value == [.copyingDatabase, .readingBooks])
    }

    @Test
    func blobCoversAreDeferredButFetchable() throws {
        let library = try CalibreFixture.makeVariantLibrary(
            named: "scanner-blob-\(UUID().uuidString)", userVersion: 26, extraColumns: true
        )
        let scanned = try CalibreLibraryScanner.scan(libraryURL: library)
        defer { try? scanned.reader.close() }

        // Book 1's cover is stored as a BLOB in the variant; the scan must
        // not materialize it into the record (a large library's embedded
        // covers can be GBs).
        let book = try #require(scanned.books.first { $0.calibreID == 1 })
        #expect(book.cover == nil)

        // ...but the still-open reader can fetch it on demand for the import.
        #expect(try scanned.reader.coverData(for: 1) == Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]))
    }
}

/// Mirrors the locked box in CalibreImportServiceTests (scanner progress
/// callbacks are synchronous, so a lock is deterministic).
private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ element: Value.Element) where Value: RangeReplaceableCollection {
        lock.lock()
        storage.append(element)
        lock.unlock()
    }
}
