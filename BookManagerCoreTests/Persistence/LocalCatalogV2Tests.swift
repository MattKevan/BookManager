import Foundation
import Testing
@testable import BookManagerCore

@Suite
struct LocalCatalogV2Tests {
    private func catalog() throws -> LocalCatalog {
        let databaseURL = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).sqlite")
        return try LocalCatalog(databaseURL: databaseURL)
    }

    private func book(
        id: UUID = UUID(),
        title: String = "Range",
        authors: [String] = ["David Epstein"],
        tags: [String] = [],
        series: String? = nil,
        identifiers: [String: String] = [:],
        formats: [BookFormatRecord] = [],
        deleted: Bool = false
    ) -> IndexedBook {
        IndexedBook(
            id: id, title: title, authors: authors,
            series: series, seriesIndex: series == nil ? nil : 1,
            tags: tags, rating: 4, publisher: "Riverhead",
            publicationMilliseconds: 1_000, addedMilliseconds: 2_000,
            languages: ["eng"], identifiers: identifiers,
            comments: "A great book", formats: formats,
            coverHash: nil, relativePath: "David Epstein/Range (12345678)",
            modifiedMilliseconds: 1_000, isDeleted: deleted,
            snapshot: Data([1, 2, 3])
        )
    }

    @Test
    func facetsCountAndFilter() async throws {
        let catalog = try catalog()
        try await catalog.upsert(book(title: "Range", authors: ["David Epstein"], tags: ["science"], series: "Studies"))
        try await catalog.upsert(book(id: UUID(), title: "Talent", authors: ["Daniel Coyle"], tags: ["science", "sport"], series: "Studies"))
        try await catalog.upsert(book(id: UUID(), title: "Solo", authors: ["Alice"], tags: ["fiction"]))

        let authors = try await catalog.facetCounts(.author)
        #expect(Set(authors.map(\.value)) == ["David Epstein", "Daniel Coyle", "Alice"])
        #expect(authors.allSatisfy { $0.count == 1 })

        let series = try await catalog.facetCounts(.series)
        #expect(series.first { $0.value == "Studies" }?.count == 2)

        let tags = try await catalog.facetCounts(.tag)
        #expect(tags.first { $0.value == "science" }?.count == 2)

        let filtered = try await catalog.books(facetType: .tag, value: "science")
        #expect(filtered.map(\.title).sorted() == ["Range", "Talent"])
    }

    @Test
    func searchCoversSeriesTagsAndIdentifiers() async throws {
        let catalog = try catalog()
        try await catalog.upsert(book(title: "Range", tags: ["biology"], identifiers: ["isbn": "978-0-7352-2129-1"]))
        try await catalog.upsert(book(id: UUID(), title: "Other", authors: ["Someone"]))

        #expect(try await catalog.search("biology").count == 1)
        #expect(try await catalog.search("2129").count == 1)
    }

    @Test
    func deletedBooksAreQueryableButExcludedFromNormalQueries() async throws {
        let catalog = try catalog()
        let deleted = book(title: "Gone", deleted: true)
        try await catalog.upsert(deleted)
        try await catalog.upsert(book(title: "Here"))

        #expect(try await catalog.allBooks().map(\.title) == ["Here"])
        #expect(try await catalog.deletedBooks().map(\.title) == ["Gone"])
        #expect(try await catalog.book(id: deleted.id)?.title == "Gone")
    }

    @Test
    func formatHashLookupFindsDuplicates() async throws {
        let catalog = try catalog()
        let format = BookFormatRecord(kind: "EPUB", filename: "a.epub", contentHash: "deadbeef", size: 10)
        let id = UUID()
        try await catalog.upsert(book(id: id, formats: [format]))

        #expect(try await catalog.bookIDs(byFormatHash: "deadbeef") == [id])
        #expect(try await catalog.bookIDs(byFormatHash: "cafebabe").isEmpty)
    }

    @Test
    func reupsertRefreshesFacetsAndHashes() async throws {
        let catalog = try catalog()
        let id = UUID()
        try await catalog.upsert(book(id: id, title: "Range", tags: ["science"], formats: [
            BookFormatRecord(kind: "EPUB", filename: "a.epub", contentHash: "h1", size: 1)
        ]))
        try await catalog.upsert(book(id: id, title: "Range", tags: ["fiction"], formats: [
            BookFormatRecord(kind: "PDF", filename: "b.pdf", contentHash: "h2", size: 2)
        ]))

        #expect(try await catalog.facetCounts(.tag).map(\.value) == ["fiction"])
        #expect(try await catalog.bookIDs(byFormatHash: "h2") == [id])
        #expect(try await catalog.bookIDs(byFormatHash: "h1").isEmpty)
        #expect(try await catalog.allBooks().first?.formats.first?.kind == "PDF")
    }
}
