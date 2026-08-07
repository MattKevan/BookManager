import Foundation

/// A metadata enrichment source (OpenLibrary, Google Books, …). New sources
/// are drop-in registry registrations — no other code changes.
public protocol MetadataSourceProviding: Sendable {
    var name: String { get }
    func search(_ query: MetadataLookupQuery) async throws -> [MetadataCandidate]
}

/// HTTP transport seam so sources are unit-testable without the network.
public protocol MetadataHTTPClient: Sendable {
    func data(from request: URLRequest) async throws -> Data
}

/// Production client: plain URLSession, with a bounded timeout and one retry
/// for transient failures (timeouts, 5xx) so a hung endpoint can't stall the
/// enrichment sheet for the URLSession default of 60s.
public struct URLSessionMetadataHTTPClient: MetadataHTTPClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(from request: URLRequest) async throws -> Data {
        var request = request
        request.timeoutInterval = 15
        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, (500..<600).contains(http.statusCode) {
                return try await retry(request)
            }
            return data
        } catch let error as URLError where error.code == .timedOut {
            return try await retry(request)
        }
    }

    private func retry(_ request: URLRequest) async throws -> Data {
        try await Task.sleep(for: .milliseconds(300))
        let (data, _) = try await session.data(for: request)
        return data
    }
}
