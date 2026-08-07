import Foundation
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

    private func freePort() throws -> Int {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        _ = withUnsafePointer(to: &addr) { pointer in
            Darwin.bind(socket, UnsafeRawPointer(pointer).assumingMemoryBound(to: sockaddr.self), socklen_t(MemoryLayout<sockaddr_in>.size))
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { pointer in
            Darwin.getsockname(socket, UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: sockaddr.self), &length)
        }
        let port = Int(addr.sin_port.bigEndian)
        Darwin.close(socket)
        return port
    }

    private func startServer(port: Int, auth: Bool) async throws {
        let server = try await LibraryServer(configuration: try await makeConfiguration(port: port, auth: auth))
        let app = try await server.makeApplication()
        Task { try await app.run() }
        try await Task.sleep(for: .milliseconds(200))
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
        let port = try freePort()
        try await startServer(port: port, auth: false)
        let status = try await send(port, path: "/api/sync?after=0")
        #expect(status == 200)
    }

    @Test
    func requiresCredentialsWhenConfigured() async throws {
        let port = try freePort()
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
