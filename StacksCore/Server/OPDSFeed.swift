import Foundation

/// OPDS 1.2 feed generation for third-party readers (Thorium, KOReader,
/// Calibre). Feeds are built as escaped XML STRINGS — Foundation's
/// `XMLDocument` is not available on Linux (Plan 3), so string building with
/// strict escaping is the portable choice.
public enum OPDSFeed {
    public static let pageSize = 25

    private static let navigationType = "application/atom+xml;profile=opds-catalog;kind=navigation"
    private static let acquisitionType = "application/atom+xml;profile=opds-catalog;kind=acquisition"
    private static let searchType = "application/opensearchdescription+xml"

    // MARK: - Feeds

    /// The root navigation feed: All Books + Authors/Series/Tags/Formats +
    /// Newest, plus the OpenSearch link.
    public static func root(baseURL: String, updated: Date = .now) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom" xmlns:dc="http://purl.org/dc/terms/" xmlns:opds="http://opds-spec.org/2010/catalog">
          <id>urn:uuid:00000000-0000-0000-0000-00000000OPDS</id>
          <title>Book Manager</title>
          <updated>\(iso(updated))</updated>
          <author><name>Book Manager</name></author>
          <link rel="self" href="\(escape(baseURL))/opds" type="\(navigationType)"/>
          <link rel="start" href="\(escape(baseURL))/opds" type="\(navigationType)"/>
          <link rel="search" href="\(escape(baseURL))/opds/search?q={searchTerms}" type="\(searchType)"/>
          \(navigationEntry(title: "All Books", href: "/opds/books", id: "all"))
          \(navigationEntry(title: "Authors", href: "/opds/authors", id: "authors"))
          \(navigationEntry(title: "Series", href: "/opds/series", id: "series"))
          \(navigationEntry(title: "Tags", href: "/opds/tags", id: "tags"))
          \(navigationEntry(title: "Formats", href: "/opds/formats", id: "formats"))
          \(navigationEntry(title: "Newest", href: "/opds/newest", id: "newest"))
        </feed>
        """
    }

    /// An acquisition feed (books, facet values, search results) with
    /// pagination. `pageHref` is the path for page 1 (e.g. `/opds/books`);
    /// the query parameter carries the page.
    public static func booksFeed(
        title: String,
        books: [IndexedBook],
        baseURL: String,
        page: Int = 1,
        pageHref: String,
        updated: Date = .now
    ) -> String {
        let start = (page - 1) * pageSize
        let slice = Array(books.dropFirst(start).prefix(pageSize))
        let hasNext = start + slice.count < books.count
        var links = ""
        if page > 1 {
            links += """
              <link rel="previous" href="\(escape(baseURL))/opds/books?page=\(page - 1)" type="\(acquisitionType)"/>

            """
        }
        if hasNext {
            links += """
              <link rel="next" href="\(escape(baseURL))/opds/books?page=\(page + 1)" type="\(acquisitionType)"/>

            """
        }
        let entries = slice.map { entry(book: $0, baseURL: baseURL) }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom" xmlns:dc="http://purl.org/dc/terms/" xmlns:opds="http://opds-spec.org/2010/catalog">
          <id>urn:uuid:00000000-0000-0000-0000-00000000\(slug(title))</id>
          <title>\(escape(title))</title>
          <updated>\(iso(updated))</updated>
          <author><name>Book Manager</name></author>
          <link rel="self" href="\(escape(baseURL))\(escape(pageHref))\(page > 1 ? "?page=\(page)" : "")" type="\(acquisitionType)"/>
          <link rel="start" href="\(escape(baseURL))/opds" type="\(navigationType)"/>
        \(links)\(entries)
        </feed>
        """
    }

    /// One book entry: identity, metadata, cover link, and acquisition links
    /// for every stored format.
    public static func entry(book: IndexedBook, baseURL: String) -> String {
        let authors = book.authors.map { "      <author><name>\(escape($0))</name></author>" }
            .joined(separator: "\n")
        let identifiers = book.identifiers.map { type, value in
            "      <dc:identifier>\(escape(type)):\(escape(value))</dc:identifier>"
        }.joined(separator: "\n")
        let formats = book.formats.map { format in
            """
              <link rel="http://opds-spec.org/acquisition/open-access" href="\(escape(baseURL))/api/books/\(book.id.uuidString)/download?format=\(escape(format.kind.lowercased()))" type="application/octet-stream"/>
            """
        }.joined(separator: "\n")
        let cover = book.coverHash.map { _ in
            """
              <link rel="http://opds-spec.org/cover" href="\(escape(baseURL))/api/books/\(book.id.uuidString)/cover" type="image/jpeg"/>
            """
        } ?? ""
        return """
        <entry>
          <title>\(escape(book.title))</title>
          <id>urn:uuid:\(book.id.uuidString)</id>
          <updated>\(iso(Date(timeIntervalSince1970: Double(book.modifiedMilliseconds) / 1_000)))</updated>
        \(authors)\(identifiers)\(cover)\(formats)
        </entry>
        """
    }

    // MARK: - Helpers

    private static func navigationEntry(title: String, href: String, id: String) -> String {
        """
        <entry>
          <title>\(escape(title))</title>
          <id>urn:uuid:00000000-0000-0000-0000-\(id)0000000000</id>
          <updated>2000-01-01T00:00:00Z</updated>
          <content type="text">\(escape(title))</content>
          <link rel="subsection" href="\(escape(href))" type="\(acquisitionType)"/>
        </entry>
        """
    }

    /// XML-escapes text content and attribute values.
    public static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func slug(_ value: String) -> String {
        String(escape(value).prefix(32).replacingOccurrences(of: " ", with: "-"))
    }

    private static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
