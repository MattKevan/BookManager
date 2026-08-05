import Foundation

/// OpenLibrary Book Search source (https://openlibrary.org/search.json) +
/// Covers API. Identified requests (User-Agent) get a higher rate limit; the
/// app sends one on every request.
public struct OpenLibrarySource: MetadataSourceProviding {
    public let name = "OpenLibrary"
    private let client: any MetadataHTTPClient
    private let userAgent: String

    public init(client: any MetadataHTTPClient, userAgent: String) {
        self.client = client
        self.userAgent = userAgent
    }

    public func search(_ query: MetadataLookupQuery) async throws -> [MetadataCandidate] {
        let url = try Self.searchURL(for: query)
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let data = try await client.data(from: request)
        return try Self.decode(data, sourceName: name)
    }

    static func searchURL(for query: MetadataLookupQuery) throws -> URL {
        var components = URLComponents(string: "https://openlibrary.org/search.json")!
        if let isbn = query.isbn {
            components.queryItems = [
                URLQueryItem(name: "q", value: "isbn:\(MetadataScoring.normalizeDigits(isbn))"),
            ]
        } else {
            components.queryItems = [
                URLQueryItem(name: "title", value: query.title),
                URLQueryItem(name: "author", value: query.authors.first ?? ""),
            ]
        }
        guard let url = components.url else { throw MetadataSourceError.badURL }
        return url
    }

    static func decode(_ data: Data, sourceName: String) throws -> [MetadataCandidate] {
        struct Response: Decodable {
            let docs: [Doc]?
        }
        struct Doc: Decodable {
            let title: String?
            let author_name: [String]?
            let publisher: [String]?
            let first_publish_year: Int?
            let isbn: [String]?
            let cover_i: Int?
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        return (response.docs ?? []).enumerated().compactMap { index, doc in
            guard let title = doc.title, !title.isEmpty else { return nil }
            let cover: URL?
            let idSuffix: String
            if let coverID = doc.cover_i {
                idSuffix = "\(coverID)"
                cover = URL(string: "https://covers.openlibrary.org/b/id/\(coverID)-M.jpg")
            } else if let isbn = doc.isbn?.first {
                idSuffix = isbn
                cover = URL(string: "https://covers.openlibrary.org/b/isbn/\(isbn)-M.jpg")
            } else {
                // Same-title docs have no cover_i/isbn handle — the index keeps
                // candidate ids unique so the review sheet's ForEach rows stay
                // distinct (a duplicate id would let Apply target the wrong row).
                idSuffix = "\(MetadataScoring.slug(title))-\(index)"
                cover = nil
            }
            return MetadataCandidate(
                id: "openlibrary-\(idSuffix)",
                title: title,
                authors: doc.author_name ?? [],
                publisher: doc.publisher?.first,
                publicationDate: doc.first_publish_year.flatMap(MetadataDateParser.date(fromYear:)),
                isbn: doc.isbn?.first,
                coverURL: cover,
                sourceName: sourceName
            )
        }
    }
}
