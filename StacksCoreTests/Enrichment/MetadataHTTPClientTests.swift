import Foundation
import StacksCore
import Testing

/// Pins `URLSessionMetadataHTTPClient`'s timeout/retry contract via a stubbed
/// URLProtocol (the HTTP path was previously exercised by no test at all).
@Suite
struct MetadataHTTPClientTests {
    private final class StubURLProtocol: URLProtocol {
        /// The handler the next load runs. `nonisolated(unsafe)`: URL loading
        /// runs on its own thread and the test sets this before each request.
        nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
        nonisolated(unsafe) static var callCount = 0

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.callCount += 1
            guard let handler = Self.handler else {
                client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
                return
            }
            do {
                let (response, data) = try handler(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}
    }

    private func makeClient() -> URLSessionMetadataHTTPClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSessionMetadataHTTPClient(session: URLSession(configuration: config))
    }

    private func response(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://example.com/search.json")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    @Test
    func retriesTransientServerErrorOnce() async throws {
        StubURLProtocol.callCount = 0
        StubURLProtocol.handler = { _ in
            if StubURLProtocol.callCount == 1 {
                return (self.response(503), Data())
            }
            return (self.response(200), Data("ok".utf8))
        }
        defer { StubURLProtocol.handler = nil }

        let client = makeClient()
        let data = try await client.data(from: URLRequest(url: URL(string: "https://example.com/search.json")!))

        #expect(String(data: data, encoding: .utf8) == "ok")
        #expect(StubURLProtocol.callCount == 2)
    }

    @Test
    func succeedsWithoutRetryOnFirstTry() async throws {
        StubURLProtocol.callCount = 0
        StubURLProtocol.handler = { _ in (self.response(200), Data("ok".utf8)) }
        defer { StubURLProtocol.handler = nil }

        let client = makeClient()
        let data = try await client.data(from: URLRequest(url: URL(string: "https://example.com/search.json")!))

        #expect(String(data: data, encoding: .utf8) == "ok")
        #expect(StubURLProtocol.callCount == 1)
    }

    @Test
    func doesNotRetryClientErrors() async throws {
        StubURLProtocol.callCount = 0
        StubURLProtocol.handler = { _ in (self.response(404), Data("nope".utf8)) }
        defer { StubURLProtocol.handler = nil }

        let client = makeClient()
        let data = try await client.data(from: URLRequest(url: URL(string: "https://example.com/search.json")!))

        #expect(String(data: data, encoding: .utf8) == "nope")
        #expect(StubURLProtocol.callCount == 1)
    }
}
