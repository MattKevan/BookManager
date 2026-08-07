import Foundation
import Testing
@testable import StacksCore

/// Shared helpers for server tests: a real `LibraryServer` on a probed free
/// port, driven over HTTP. (HummingbirdTesting's router-level client breaks
/// swift-testing's result serialization on this toolchain — the real socket
/// is both the workaround and a better test.)
enum ServerTestHarness {
    /// Binds a loopback socket to port 0 to find a free port, then closes it.
    static func freePort() throws -> Int {
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

    /// Starts the server for `libraryPath` on `port` in a background task.
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
        try await Task.sleep(for: .milliseconds(300))
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
