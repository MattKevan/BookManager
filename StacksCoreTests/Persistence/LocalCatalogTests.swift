import Foundation
import Testing
@testable import StacksCore

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

    @Test
    func facetCountsExcludeDeletedBooks() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).sqlite")
        let catalog = try LocalCatalog(databaseURL: databaseURL)
        let live = IndexedBook(
            id: UUID(), title: "Range", authors: ["David Epstein"], tags: ["science"],
            modifiedMilliseconds: 1_000, isDeleted: false, snapshot: Data()
        )
        let deleted = IndexedBook(
            id: UUID(), title: "Gone", authors: ["David Epstein"], tags: ["science"],
            modifiedMilliseconds: 1_000, isDeleted: true, snapshot: Data()
        )

        try await catalog.upsert(live)
        try await catalog.upsert(deleted)

        // Deleting a book must not leave its authors/tags inflating the
        // sidebar counts forever: the count reflects live books only, while
        // the facet listing still agrees with it.
        let authorCounts = try await catalog.facetCounts(.author)
        #expect(authorCounts.count == 1)
        #expect(authorCounts[0].value == "David Epstein")
        #expect(authorCounts[0].count == 1)
        let tagCounts = try await catalog.facetCounts(.tag)
        #expect(tagCounts.count == 1)
        #expect(tagCounts[0].value == "science")
        #expect(tagCounts[0].count == 1)
        let listing = try await catalog.books(facetType: .author, value: "David Epstein")
        #expect(listing.map(\.id) == [live.id])
    }

    @Test
    func searchToleratesUnbalancedQuotesAndOperators() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).sqlite")
        let catalog = try LocalCatalog(databaseURL: databaseURL)
        let book = IndexedBook(
            id: UUID(), title: "Don't Panic", authors: ["Adams"],
            modifiedMilliseconds: 1_000, isDeleted: false, snapshot: Data()
        )
        try await catalog.upsert(book)

        // Unbalanced quote: raw FTS5 input would throw a syntax error and
        // surface as an empty search; the sanitizer must treat it as text
        // (FTS5 tokenizes "Don't Panic" as don/t/panic, so "dont" matches
        // nothing — the contract is a clean empty result, not a crash).
        #expect(try await catalog.search("don\"t").isEmpty)
        #expect(try await catalog.search("panic").map(\.id) == [book.id])
        // Bare operators must not crash either.
        #expect(try await catalog.search("-").isEmpty)
        #expect(try await catalog.search("* OR").isEmpty)
        // Quote-only input behaves like no search at all.
        #expect(try await catalog.search("\"\"\"").map(\.id) == [book.id])
    }
}
