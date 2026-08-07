import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Testing
@testable import StacksCore

/// Shared helpers for server tests: a real `LibraryServer` on a probed free
/// port, driven over HTTP. (HummingbirdTesting's router-level client breaks
/// swift-testing's result serialization on this toolchain — the real socket
/// is both the workaround and a better test.)
enum ServerTestHarness {
    /// Binds a loopback socket to port 0 to find a free port, then closes it.
    static func freePort() throws -> Int {
        #if canImport(Darwin)
        let socket = socket(AF_INET, SOCK_STREAM, 0)
        #else
        // glibc's SOCK_STREAM is an enum (__socket_type), not an Int32.
        let socket = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        var addr = sockaddr_in()
        #if canImport(Darwin)
        // BSD only: glibc's sockaddr_in has no sin_len field.
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        _ = withUnsafePointer(to: &addr) { pointer in
            bind(socket, UnsafeRawPointer(pointer).assumingMemoryBound(to: sockaddr.self), socklen_t(MemoryLayout<sockaddr_in>.size))
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { pointer in
            getsockname(socket, UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: sockaddr.self), &length)
        }
        let port = Int(addr.sin_port.bigEndian)
        close(socket)
        return port
    }

    /// Creates a library at a temp path and returns its root + a config for
    /// that port.
    static func makeLibrary() async throws -> (libraryPath: String, indexesDirectory: URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let libraryPath = root.appending(path: "library", directoryHint: .isDirectory).path
        _ = try await LibraryRepository.create(
            at: URL(fileURLWithPath: libraryPath),
            indexesDirectory: root.appending(path: "indexes", directoryHint: .isDirectory),
            deviceID: UUID()
        )
        return (libraryPath, root.appending(path: "server-indexes", directoryHint: .isDirectory))
    }

    /// Starts the server for `libraryPath` on `port` in a background task and
    /// waits until it answers HTTP requests (any status — a 401 still proves
    /// the listener is up).
    static func startServer(libraryPath: String, indexesDirectory: URL, port: Int, username: String? = nil, password: String? = nil) async throws {
        let configuration = ServerConfiguration(
            port: port,
            libraryPath: libraryPath,
            indexesDirectory: indexesDirectory,
            username: username,
            password: password,
            advertiseBonjour: false
        )
        let server = try await LibraryServer(configuration: configuration)
        let app = try await server.makeApplication()
        Task { try await app.run() }
        try await waitForServer(port: port)
    }

    /// Polls until the server answers an HTTP request on `port` (any status),
    /// or ~2.5s elapse. A fixed startup sleep is not enough under parallel
    /// test load — the socket may not be bound yet when the client fires.
    static func waitForServer(port: Int) async throws {
        for _ in 0..<50 {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/sync?after=0")!)
            request.timeoutInterval = 1
            if let (_, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode != nil {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw ServerTestHarnessError.serverDidNotStart
    }

    enum ServerTestHarnessError: Error {
        case serverDidNotStart
    }

    static let isoEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let isoDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func makeAddBook(id: UUID, title: String, authors: [String]) -> ClientCommand {
        ClientCommand(id: id, op: .addBook(.init(
            bookID: id, title: title, authors: authors,
            series: nil, seriesIndex: nil, tags: [], rating: nil, publisher: nil,
            publicationDate: nil, addedDate: .now, languages: [], identifiers: [:], comments: nil,
            formats: [], cover: nil
        )))
    }

    static func queueDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    }
}
