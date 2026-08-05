import Foundation
import Testing
@testable import StacksCore

@Suite
struct MetadataMergePlanTests {
    private func book(
        title: String = "Current Title",
        authors: [String] = ["Existing Author"],
        publisher: String? = "Current Press",
        date: Date? = nil,
        identifiers: [String: String] = [:]
    ) -> IndexedBook {
        IndexedBook(
            id: UUID(), title: title, authors: authors,
            publisher: publisher,
            publicationMilliseconds: date.map { Int64($0.timeIntervalSince1970 * 1_000) },
            identifiers: identifiers,
            modifiedMilliseconds: 1_000, isDeleted: false, snapshot: Data([1])
        )
    }

    private func candidate(
        title: String = "Fetched Title",
        authors: [String] = ["Fetched Author"],
        publisher: String? = "Fetched Press",
        date: Date? = nil,
        isbn: String? = "9780735221291",
        coverURL: URL? = nil
    ) -> MetadataCandidate {
        MetadataCandidate(
            id: "test-1", title: title, authors: authors,
            publisher: publisher, publicationDate: date, isbn: isbn,
            coverURL: coverURL, sourceName: "test"
        )
    }

    @Test
    func defaultsUseFetchedForEmptyFieldsOnly() throws {
        let plan = MetadataMergePlan.make(
            book: book(title: "", authors: [], publisher: nil),
            candidate: candidate()
        )
        let byField = Dictionary(uniqueKeysWithValues: plan.items.map { ($0.field, $0.defaultChoice) })
        #expect(byField[.title] == .useFetched)
        #expect(byField[.authors] == .useFetched)
        #expect(byField[.publisher] == .useFetched)
        #expect(byField[.isbn] == .useFetched)
        // A populated book defaults to Keep.
        let full = MetadataMergePlan.make(book: book(), candidate: candidate())
        let fullByField = Dictionary(uniqueKeysWithValues: full.items.map { ($0.field, $0.defaultChoice) })
        #expect(fullByField[.title] == .keep)
        #expect(fullByField[.publisher] == .keep)
    }

    @Test
    func allKeepProducesEmptyEdit() throws {
        let book = book()
        let candidate = candidate()
        let result = MetadataMergePlan.apply(
            choices: [.title: .keep, .authors: .keep, .publisher: .keep,
                      .publicationDate: .keep, .isbn: .keep, .cover: .keep],
            book: book, candidate: candidate
        )
        #expect(result.edit.title == nil)
        #expect(result.edit.authors == nil)
        #expect(result.edit.publisher == .keep)
        #expect(result.edit.publicationDate == .keep)
        #expect(result.edit.identifiers == nil)
        #expect(result.coverChosen == false)
    }

    @Test
    func chosenFieldsFlowIntoTheEdit() throws {
        let date = Date(timeIntervalSince1970: 1_600_000_000)
        let book = book()
        // coverChosen requires a candidate cover URL (the design gates the cover
        // choice on an available URL; apply never claims a cover it can't fetch).
        let candidate = candidate(
            title: "New Title", authors: ["New Author"], publisher: "New Press", date: date,
            coverURL: URL(string: "https://example.com/c.jpg")
        )
        let result = MetadataMergePlan.apply(
            choices: [.title: .useFetched, .authors: .useFetched, .publisher: .useFetched,
                      .publicationDate: .useFetched, .isbn: .useFetched, .cover: .useFetched],
            book: book, candidate: candidate
        )
        #expect(result.edit.title == "New Title")
        #expect(result.edit.authors == ["New Author"])
        #expect(result.edit.publisher == .set("New Press"))
        #expect(result.edit.publicationDate == .set(date))
        #expect(result.edit.identifiers?["isbn"] == "9780735221291")
        #expect(result.coverChosen == true)
    }

    @Test
    func isbnMergePreservesExistingIdentifiers() throws {
        let book = book(identifiers: ["google": "abc123"])
        let result = MetadataMergePlan.apply(
            choices: [.isbn: .useFetched],
            book: book, candidate: candidate()
        )
        let ids = result.edit.identifiers ?? [:]
        #expect(ids["isbn"] == "9780735221291")
        #expect(ids["google"] == "abc123")
    }

    @Test
    func coverWithoutURLForcesKeep() throws {
        let plan = MetadataMergePlan.make(book: book(), candidate: candidate(coverURL: nil))
        let cover = plan.items.first { $0.field == .cover }
        #expect(cover?.fetchedValue == nil)
        #expect(cover?.defaultChoice == .keep)
    }

    @Test
    func chosenButNilPublisherClears() throws {
        // Choosing "use fetched" for a field the candidate can't supply
        // resolves to .clear (an empty draft clears the field on Save).
        let result = MetadataMergePlan.apply(
            choices: [.publisher: .useFetched],
            book: book(), candidate: candidate(publisher: nil)
        )
        #expect(result.edit.publisher == .clear)
    }

    @Test
    func coverChosenFalseWithoutCoverURL() throws {
        let result = MetadataMergePlan.apply(
            choices: [.cover: .useFetched],
            book: book(), candidate: candidate(coverURL: nil)
        )
        #expect(result.coverChosen == false)
    }

    @Test
    func emptyCandidateTitleDoesNotClearTheBookTitle() throws {
        let result = MetadataMergePlan.apply(
            choices: [.title: .useFetched],
            book: book(), candidate: candidate(title: "")
        )
        #expect(result.edit.title == nil)
    }
}
