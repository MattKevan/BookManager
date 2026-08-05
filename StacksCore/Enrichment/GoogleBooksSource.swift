import Foundation

/// Google Books volumes API source (https://developers.google.com/books).
/// Field-scoped queries (isbn:/intitle:/inauthor:); covers come from
/// `volumeInfo.imageLinks.thumbnail`.
public struct GoogleBooksSource: MetadataSourceProviding {
    public let name = "Google Books"
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
        var components = URLComponents(string: "https://www.googleapis.com/books/v1/volumes")!
        let terms: String
        if let isbn = query.isbn {
            terms = "isbn:\(MetadataScoring.normalizeDigits(isbn))"
        } else {
            var parts = ["intitle:\(query.title)"]
            if let author = query.authors.first {
                parts.append("inauthor:\(author)")
            }
            terms = parts.joined(separator: " ")
        }
        components.queryItems = [
            URLQueryItem(name: "q", value: terms),
            URLQueryItem(name: "maxResults", value: "20"),
        ]
        guard let url = components.url else { throw MetadataSourceError.badURL }
        return url
    }

    static func decode(_ data: Data, sourceName: String) throws -> [MetadataCandidate] {
        struct Response: Decodable {
            let items: [Item]?
        }
        struct Item: Decodable {
            let id: String
            let volumeInfo: VolumeInfo
        }
        struct VolumeInfo: Decodable {
            let title: String?
            let authors: [String]?
            let publisher: String?
            let publishedDate: String?
            let imageLinks: ImageLinks?
        }
        struct ImageLinks: Decodable {
            let thumbnail: String?
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        return (response.items ?? []).compactMap { item in
            guard let title = item.volumeInfo.title, !title.isEmpty else { return nil }
            let coverURL = item.volumeInfo.imageLinks?.thumbnail
                .map { $0.replacingOccurrences(of: "http://", with: "https://") }
                .flatMap(URL.init(string:))
            return MetadataCandidate(
                id: "google-\(item.id)",
                title: title,
                authors: item.volumeInfo.authors ?? [],
                publisher: item.volumeInfo.publisher,
                publicationDate: item.volumeInfo.publishedDate
                    .flatMap(MetadataDateParser.date(fromPublishedString:)),
                isbn: nil,
                coverURL: coverURL,
                sourceName: sourceName
            )
        }
    }
}
