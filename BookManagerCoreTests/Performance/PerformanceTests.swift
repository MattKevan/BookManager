import Foundation
import Testing
@testable import BookManagerCore

@Suite(.serialized)
struct PerformanceTests {
    private static let bookCount = 10_000

    private func seededCatalog() async throws -> LocalCatalog {
        let catalog = try LocalCatalog(databaseURL: FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).sqlite"))
        let books = (0..<Self.bookCount).map { i -> IndexedBook in
            let id = UUID()
            let title = "Book \(i) of a very long title series"
            let authors = ["Author \(i % 500)"]
            return IndexedBook(
                id: id, title: title, authors: authors,
                series: "Series \(i % 100)", seriesIndex: Double(i % 100),
                tags: ["tag\(i % 50)"], rating: i % 5 + 1, publisher: "Pub \(i % 20)",
                publicationMilliseconds: Int64(1_700_000_000_000 + i),
                addedMilliseconds: Int64(1_700_000_000_000),
                languages: ["eng"], identifiers: ["isbn": "978-\(String(format: "%012d", i))"],
                formats: [], coverHash: nil,
                // Realistic relative path: the reconciler treats a book whose
                // catalog path differs from canonical as needing a move — a
                // seed with "" would resolve to the library root itself.
                relativePath: CanonicalPathBuilder.relativeDirectory(
                    bookID: id, title: title, authors: authors
                ),
                modifiedMilliseconds: Int64(i), isDeleted: false,
                snapshot: Data(repeating: 0x01, count: 256)
            )
        }
        try await catalog.upsertBatch(books)
        return catalog
    }

    @Test
    func searchStaysUnder250msAt10k() async throws {
        let catalog = try await seededCatalog()
        _ = try await catalog.search("Book 9999") // warm-up
        let clock = ContinuousClock()
        let elapsed = try await clock.measure {
            _ = try await catalog.search("Book 9999")
        }
        #expect(elapsed < .milliseconds(250))
    }

    @Test
    func allBooksUnder1sAt10k() async throws {
        let catalog = try await seededCatalog()
        _ = try await catalog.allBooks() // warm-up
        let clock = ContinuousClock()
        let elapsed = try await clock.measure {
            _ = try await catalog.allBooks()
        }
        #expect(elapsed < .seconds(1))
    }

    @Test
    func facetCountsUnder1sAt10k() async throws {
        let catalog = try await seededCatalog()
        _ = try await catalog.facetCounts(.tag) // warm-up
        let clock = ContinuousClock()
        let elapsed = try await clock.measure {
            _ = try await catalog.facetCounts(.tag)
            _ = try await catalog.facetCounts(.author)
        }
        #expect(elapsed < .seconds(1))
    }

    @Test
    func steadyStateReconcileCompletesAt10k() async throws {
        // With no materialized folders every book is "missing" — this exercises
        // the per-pass folder index (one root scan + 10k lookups), not O(N×dirs).
        let catalog = try await seededCatalog()
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let layout = LibraryLayout(root: root)
        try layout.create(manifest: LibraryManifest(id: UUID()))
        let reconciler = FolderReconciler(layout: layout, catalog: catalog, deviceID: UUID())
        let clock = ContinuousClock()
        let elapsed = try await clock.measure {
            _ = try await reconciler.reconcile()
        }
        #expect(elapsed < .seconds(5))
    }
}
