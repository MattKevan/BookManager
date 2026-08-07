import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Hummingbird
import Testing
@testable import StacksCore

@Suite
struct AuthTests {
    private static let isoEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let isoDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
    private func makeConfiguration(port: Int, auth: Bool) async throws -> ServerConfiguration {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let libraryPath = root.appending(path: "library", directoryHint: .isDirectory).path
        _ = try await LibraryRepository.create(
            at: URL(fileURLWithPath: libraryPath),
            indexesDirectory: root.appending(path: "indexes", directoryHint: .isDirectory),
            deviceID: UUID()
        )
        return ServerConfiguration(
            port: port,
            libraryPath: libraryPath,
            indexesDirectory: root.appending(path: "server-indexes", directoryHint: .isDirectory),
            username: auth ? "alice" : nil,
            password: auth ? "secret" : nil
        )
    }

    private func startServer(port: Int, auth: Bool) async throws {
        let server = try await LibraryServer(configuration: try await makeConfiguration(port: port, auth: auth))
        let app = try await server.makeApplication()
        Task { try await app.run() }
        try await ServerTestHarness.waitForServer(port: port)
    }

    private func send(_ port: Int, path: String, headers: [String: String] = [:]) async throws -> Int {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.timeoutInterval = 5
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    private func basicAuthHeader(username: String, password: String) -> String {
        let data = Data("\(username):\(password)".utf8)
        return "Basic \(data.base64EncodedString())"
    }

    @Test
    func anonymousWhenNoCredentialsConfigured() async throws {
        let port = try ServerTestHarness.freePort()
        try await startServer(port: port, auth: false)
        let status = try await send(port, path: "/api/sync?after=0")
        #expect(status == 200)
    }

    @Test
    func requiresCredentialsWhenConfigured() async throws {
        let port = try ServerTestHarness.freePort()
        try await startServer(port: port, auth: true)
        let syncPath = "/api/sync?after=0"

        let denied = try await send(port, path: syncPath)
        #expect(denied == 401)

        let wrong = try await send(
            port, path: syncPath,
            headers: ["Authorization": basicAuthHeader(username: "alice", password: "nope")]
        )
        #expect(wrong == 401)

        let ok = try await send(
            port, path: syncPath,
            headers: ["Authorization": basicAuthHeader(username: "alice", password: "secret")]
        )
        #expect(ok == 200)
    }
}
