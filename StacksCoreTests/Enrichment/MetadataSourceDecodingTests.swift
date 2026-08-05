import Foundation
import Testing
@testable import StacksCore

@Suite
struct MetadataSourceDecodingTests {
    @Test
    func openLibraryDecodesSearchResults() throws {
        let json = """
        {
          "docs": [
            {
              "title": "Range: Why Generalists Triumph in a Specialized World",
              "author_name": ["David Epstein"],
              "publisher": ["Riverhead Books"],
              "first_publish_year": 2019,
              "isbn": ["9780735221291", "0735221299"],
              "cover_i": 123456
            },
            {
              "title": "The Talent Code",
              "author_name": ["Daniel Coyle"]
            }
          ]
        }
        """
        let candidates = try OpenLibrarySource.decode(Data(json.utf8), sourceName: "OpenLibrary")

        #expect(candidates.count == 2)
        let first = try #require(candidates.first)
        #expect(first.title == "Range: Why Generalists Triumph in a Specialized World")
        #expect(first.authors == ["David Epstein"])
        #expect(first.publisher == "Riverhead Books")
        #expect(first.isbn == "9780735221291")
        #expect(first.id == "openlibrary-123456")
        #expect(first.coverURL?.absoluteString == "https://covers.openlibrary.org/b/id/123456-M.jpg")
        #expect(Calendar(identifier: .gregorian).component(.year, from: try #require(first.publicationDate)) == 2019)

        let second = try #require(candidates.dropFirst().first)
        // No ISBN/cover_i: id falls back to a title slug plus the doc index
        // (unique ids for same-title docs), so the review sheet rows stay distinct.
        #expect(second.id == "openlibrary-the-talent-code-1")
        #expect(second.coverURL == nil)
        #expect(second.publicationDate == nil)
    }

    @Test
    func openLibrarySearchURLUsesIsbnRouteWhenPresent() throws {
        let url = try OpenLibrarySource.searchURL(
            for: MetadataLookupQuery(isbn: "978-0-7352-2129-1", title: "Range", authors: ["David Epstein"])
        )
        #expect(url.host == "openlibrary.org")
        #expect(url.query?.contains("isbn:9780735221291") == true)
    }

    @Test
    func openLibrarySearchURLFallsBackToTitleAuthor() throws {
        let url = try OpenLibrarySource.searchURL(
            for: MetadataLookupQuery(isbn: nil, title: "Range", authors: ["David Epstein"])
        )
        #expect(url.query?.contains("title=Range") == true)
        #expect(url.query?.contains("author=David%20Epstein") == true)
    }

    @Test
    func googleBooksDecodesVolumes() throws {
        let json = """
        {
          "items": [
            {
              "id": "zyTCAlFPjgYC",
              "volumeInfo": {
                "title": "Range",
                "authors": ["David Epstein"],
                "publisher": "Riverhead",
                "publishedDate": "2019-05-28",
                "imageLinks": {
                  "thumbnail": "http://books.google.com/books?id=zyTCAlFPjgYC&printsec=frontcover&img=1&zoom=1&edge=curl&source=gbs_api"
                }
              }
            }
          ]
        }
        """
        let candidates = try GoogleBooksSource.decode(Data(json.utf8), sourceName: "Google Books")

        #expect(candidates.count == 1)
        let first = try #require(candidates.first)
        #expect(first.id == "google-zyTCAlFPjgYC")
        #expect(first.title == "Range")
        #expect(first.authors == ["David Epstein"])
        #expect(first.publisher == "Riverhead")
        #expect(first.coverURL?.scheme == "https") // http upgraded
        let components = Calendar(identifier: .gregorian).dateComponents(
            [.year, .month, .day], from: try #require(first.publicationDate)
        )
        #expect(components.year == 2019)
        #expect(components.month == 5)
        #expect(components.day == 28)
    }

    @Test
    func googleBooksParsesPartialDatesLeniently() throws {
        let yearOnly = MetadataDateParser.date(fromPublishedString: "2019")
        #expect(Calendar(identifier: .gregorian).component(.year, from: try #require(yearOnly)) == 2019)

        let yearMonth = MetadataDateParser.date(fromPublishedString: "2019-05")
        let components = Calendar(identifier: .gregorian).dateComponents(
            [.year, .month], from: try #require(yearMonth)
        )
        #expect(components.year == 2019)
        #expect(components.month == 5)

        #expect(MetadataDateParser.date(fromPublishedString: "garbage") == nil)
        #expect(MetadataDateParser.date(fromPublishedString: "99") == nil) // out of the sane range
    }

    @Test
    func googleBooksSearchURLBuildsQueries() throws {
        let isbnURL = try GoogleBooksSource.searchURL(
            for: MetadataLookupQuery(isbn: "978-0-7352-2129-1", title: "Range", authors: [])
        )
        #expect(isbnURL.query?.contains("isbn:9780735221291") == true)
        #expect(isbnURL.query?.contains("maxResults=20") == true)

        let titleURL = try GoogleBooksSource.searchURL(
            for: MetadataLookupQuery(isbn: nil, title: "Range", authors: ["David Epstein"])
        )
        #expect(titleURL.query?.contains("intitle:Range") == true)
        #expect(titleURL.query?.contains("inauthor:David%20Epstein") == true)
    }
}
