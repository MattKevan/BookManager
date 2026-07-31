import Foundation
import Testing
@testable import BookManagerCore

@Suite
struct LocalCatalogTests {
    @Test
    func upsertsListsAndSearchesBooks() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).sqlite")
        let catalog = try LocalCatalog(databaseURL: databaseURL)
        let book = IndexedBook(
            id: UUID(),
            title: "Range",
            authors: ["David Epstein"],
            modifiedMilliseconds: 1_000,
            isDeleted: false,
            snapshot: Data([1, 2, 3])
        )

        try await catalog.upsert(book)

        #expect(try await catalog.allBooks().map(\.title) == ["Range"])
        #expect(try await catalog.search("Epstein").map(\.id) == [book.id])
        #expect(try await catalog.snapshot(bookID: book.id) == Data([1, 2, 3]))
    }

    @Test
    func deletedBooksAreExcludedFromNormalQueries() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).sqlite")
        let catalog = try LocalCatalog(databaseURL: databaseURL)
        let book = IndexedBook(
            id: UUID(),
            title: "Deleted",
            authors: ["Author"],
            modifiedMilliseconds: 1_000,
            isDeleted: true,
            snapshot: Data()
        )

        try await catalog.upsert(book)

        #expect(try await catalog.allBooks().isEmpty)
    }

    @Test
    func reupsertingReplacesSearchEntriesInsteadOfDuplicating() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).sqlite")
        let catalog = try LocalCatalog(databaseURL: databaseURL)
        let bookID = UUID()
        let original = IndexedBook(
            id: bookID,
            title: "Range",
            authors: ["David Epstein"],
            modifiedMilliseconds: 1_000,
            isDeleted: false,
            snapshot: Data([1])
        )
        let revised = IndexedBook(
            id: bookID,
            title: "Range: Revised",
            authors: ["David Epstein"],
            modifiedMilliseconds: 2_000,
            isDeleted: false,
            snapshot: Data([2])
        )

        try await catalog.upsert(original)
        try await catalog.upsert(revised)

        #expect(try await catalog.allBooks().map(\.title) == ["Range: Revised"])
        #expect(try await catalog.search("Epstein").count == 1)
        #expect(try await catalog.search("Range").count == 1)
        #expect(try await catalog.snapshot(bookID: bookID) == Data([2]))
    }
}
