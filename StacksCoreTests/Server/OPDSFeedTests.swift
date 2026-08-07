import Foundation
import Testing
@testable import StacksCore

@Suite
struct OPDSFeedTests {
    private func book(id: UUID = UUID(), title: String, authors: [String] = ["Alice"], tags: [String] = [], added: Int64 = 1) -> IndexedBook {
        IndexedBook(
            id: id, title: title, authors: authors, tags: tags,
            addedMilliseconds: added, modifiedMilliseconds: 1, isDeleted: false
        )
    }

    @Test
    func rootContainsNavigationEntriesAndSearchLink() {
        let feed = OPDSFeed.root(baseURL: "http://example.com")
        #expect(feed.contains("<title>All Books</title>"))
        #expect(feed.contains("<title>Authors</title>"))
        #expect(feed.contains("<title>Series</title>"))
        #expect(feed.contains("<title>Tags</title>"))
        #expect(feed.contains("<title>Formats</title>"))
        #expect(feed.contains("<title>Newest</title>"))
        #expect(feed.contains("rel=\"search\" href=\"http://example.com/opds/search?q={searchTerms}\""))
    }

    @Test
    func bookEntryHasCoverAndAcquisitionLinks() {
        let id = UUID()
        let book = IndexedBook(
            id: id, title: "Range", authors: ["David Epstein"],
            identifiers: ["isbn": "978-0-7352-2129-1"],
            formats: [.init(kind: "EPUB", filename: "a.epub", contentHash: "h", size: 1)],
            coverHash: "cover-hash", modifiedMilliseconds: 1, isDeleted: false
        )
        let feed = OPDSFeed.booksFeed(title: "X", books: [book], baseURL: "http://example.com", pageHref: "/opds/books")
        #expect(feed.contains("rel=\"http://opds-spec.org/cover\" href=\"http://example.com/api/books/\(id.uuidString)/cover\""))
        #expect(feed.contains("rel=\"http://opds-spec.org/acquisition/open-access\" href=\"http://example.com/api/books/\(id.uuidString)/download?format=epub\""))
        #expect(feed.contains("<dc:identifier>isbn:978-0-7352-2129-1</dc:identifier>"))
        #expect(feed.contains("<author><name>David Epstein</name></author>"))
    }

    @Test
    func specialCharactersAreEscaped() {
        let book = book(title: "Don't & <Panic> \"Now\"")
        let feed = OPDSFeed.entry(book: book, baseURL: "http://example.com")
        #expect(!feed.contains("&<Panic>"))
        #expect(feed.contains("&amp; &lt;Panic&gt;"))
        #expect(feed.contains("&quot;Now&quot;"))
    }

    @Test
    func paginationAddsNextAndPreviousLinks() {
        let books = (0..<30).map { book(title: "Book \($0)") }
        let page1 = OPDSFeed.booksFeed(title: "X", books: books, baseURL: "http://example.com", page: 1, pageHref: "/opds/books")
        #expect(page1.contains("rel=\"next\" href=\"http://example.com/opds/books?page=2\""))
        #expect(!page1.contains("rel=\"previous\""))

        let page2 = OPDSFeed.booksFeed(title: "X", books: books, baseURL: "http://example.com", page: 2, pageHref: "/opds/books")
        #expect(page2.contains("rel=\"previous\" href=\"http://example.com/opds/books?page=1\""))
        // Page 2 has the remaining 5 books, no next.
        #expect(!page2.contains("rel=\"next\""))
        // Only 25 entries per page.
        #expect(page1.components(separatedBy: "<entry>").count == 26)
    }
}
