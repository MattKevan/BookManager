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

/// Production client: plain URLSession.
public struct URLSessionMetadataHTTPClient: MetadataHTTPClient {
    public init() {}

    public func data(from request: URLRequest) async throws -> Data {
        let (data, _) = try await URLSession.shared.data(for: request)
        return data
    }
}
