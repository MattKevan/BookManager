import Foundation
import StacksCore
import Testing
@testable import Stacks

/// App-layer orchestration tests (the app target's first unit-test bundle).
/// Cover the enrichment sweep's review-pause contract: `enrichBooksMissingMetadata`
/// must stop at the first presented candidate so the loop cannot clobber the
/// review sheet with later books' candidates (or auto-apply under a live sheet).
@MainActor
@Suite
struct LibrarySessionEnrichmentTests {
    /// A source that always returns one ambiguous candidate (title mismatch →
    /// score 0 → never auto-applies, always presented for review).
    private final class AmbiguousSource: MetadataSourceProviding, @unchecked Sendable {
        let name = "fake"
        private let lock = NSLock()
        private var _callCount = 0

        var callCount: Int {
            lock.withLock { _callCount }
        }

        func search(_ query: MetadataLookupQuery) async throws -> [MetadataCandidate] {
            lock.withLock { _callCount += 1 }
            return [
                MetadataCandidate(
                    id: "fake-1",
                    title: "Something Else Entirely",
                    authors: ["Someone Else"],
                    publisher: nil,
                    publicationDate: nil,
                    isbn: nil,
                    coverURL: nil,
                    sourceName: name
                )
            ]
        }
    }

    private func makeSession() async throws -> (LibrarySession, [IndexedBook], LibraryConnection) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let indexes = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let deviceID = UUID()
        let repo = try await LibraryRepository.create(
            at: root, indexesDirectory: indexes, deviceID: deviceID
        )
        let alpha = try await repo.createBook(title: "Alpha", authors: ["Alice"])
        let beta = try await repo.createBook(title: "Beta", authors: ["Bob"])
        let connection = try await LibraryConnection(
            openAt: root, indexesDirectory: indexes, deviceID: deviceID
        )
        let session = LibrarySession(
            deviceID: UUID(),
            bookmarks: LibraryBookmarkStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        )
        session.home = connection
        return (session, [alpha, beta], connection)
    }

    @Test
    func enrichmentSweepStopsWhenReviewSheetIsPresented() async throws {
        let (session, books, connection) = try await makeSession()
        defer { connection.stop() }
        let source = AmbiguousSource()
        session.metadataService = MetadataLookupService(registry: MetadataRegistry(sources: [source]))

        await session.enrichBooksMissingMetadata(books.map(\.id))

        // The first ambiguous book presented the review sheet…
        #expect(session.metadataReviewPresented)
        #expect(session.metadataBookID == books[0].id)
        // …and the sweep stopped: the second book was never looked up, so its
        // candidates could not clobber the sheet (and no auto-apply could fire
        // under it).
        #expect(source.callCount == 1)
        #expect(session.metadataCandidates.first?.sourceName == "fake")
    }
}
