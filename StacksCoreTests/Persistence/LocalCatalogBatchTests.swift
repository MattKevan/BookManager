import Foundation
import Testing
@testable import StacksCore

@Suite
struct LocalCatalogBatchTests {
    private func catalog() throws -> LocalCatalog {
        try LocalCatalog(databaseURL: FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).sqlite"))
    }

    private func book(_ title: String, tag: String) -> IndexedBook {
        IndexedBook(
            id: UUID(), title: title, authors: ["Alice"],
            tags: [tag],
            modifiedMilliseconds: 1_000, isDeleted: false, snapshot: Data([1])
        )
    }

    @Test
    func batchRoundTripsSearchAndFacets() async throws {
        let catalog = try catalog()
        try await catalog.upsertBatch((1...500).map { book("Book \($0)", tag: $0 % 2 == 0 ? "even" : "odd") })

        #expect(try await catalog.allBooks().count == 500)
        #expect(try await catalog.search("Book 42").count == 1)
        let facets = try await catalog.facetCounts(.tag)
        #expect(facets.first { $0.value == "even" }?.count == 250)
    }

    @Test
    func batchIsAtomicWithSingleUpsertEquivalent() async throws {
        let catalog = try catalog()
        let a = book("A", tag: "x")
        let b = book("B", tag: "y")
        try await catalog.upsertBatch([a, b])
        #expect(try await catalog.book(id: a.id)?.title == "A")
        #expect(try await catalog.book(id: b.id)?.title == "B")
        // Re-upserting the batch (rebuild semantics) converges to the same set.
        try await catalog.upsertBatch([a, b])
        #expect(try await catalog.allBooks().count == 2)
    }
}
