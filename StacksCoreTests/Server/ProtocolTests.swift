import Foundation
import Hummingbird
import Testing
@testable import StacksCore

/// Protocol tests against the REAL socket: the server runs on a probed free
/// port (HummingbirdTesting's router-level client breaks swift-testing's
/// result serialization on this toolchain — demangle failures, uncounted
/// tests, exit 65), so these exercise the actual HTTP path instead.
@Suite
struct ProtocolTests {
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
    private func makeConfiguration(port: Int) async throws -> ServerConfiguration {
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
            indexesDirectory: root.appending(path: "server-indexes", directoryHint: .isDirectory)
        )
    }

    /// Binds a loopback socket to port 0 to find a free port, then closes it.
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

    /// Starts the server on the given port in a background task, waiting until
    /// it accepts connections.
    private func startServer(port: Int) async throws {
        let server = try await LibraryServer(configuration: try await makeConfiguration(port: port))
        let app = try await server.makeApplication()
        Task { try await app.run() }
        for _ in 0..<50 {
            if await portResponds(port) { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw ProtocolError.serverDidNotStart
    }

    private enum ProtocolError: Error {
        case serverDidNotStart
    }

    private func portResponds(_ port: Int) async -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/sync?after=0")!)
        request.timeoutInterval = 1
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    private func send(
        _ port: Int, method: String, path: String, body: Data? = nil, headers: [String: String] = [:]
    ) async throws -> (status: Int, data: Data) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = method
        request.httpBody = body
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.timeoutInterval = 5
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    @Test
    func pushAndPullRoundTrip() async throws {
        let port = try freePort()
        try await startServer(port: port)

        let bookID = UUID()
        let addID = UUID()
        let push = SyncPushRequest(commands: [
            ClientCommand(id: addID, op: .addBook(.init(
                bookID: bookID, title: "Network", authors: ["Alice"],
                series: nil, seriesIndex: nil, tags: ["tech"], rating: nil, publisher: nil,
                publicationDate: nil, addedDate: .now, languages: [], identifiers: [:], comments: nil,
                formats: [], cover: nil
            ))),
            ClientCommand(id: UUID(), op: .updateBook(.init(bookID: bookID, edit: .init(title: "Network: Revised")))),
        ])
        let pushed = try await send(port, method: "POST", path: "/api/commands",
                                    body: try ProtocolTests.isoEncoder.encode(push))
        #expect(pushed.status == 200)
        let pushResult = try ProtocolTests.isoDecoder.decode(SyncPushResponse.self, from: pushed.data)
        #expect(pushResult.errors.isEmpty)
        #expect(pushResult.applied.count == 2)

        let pull = try await send(port, method: "GET", path: "/api/sync?after=0")
        let result = try ProtocolTests.isoDecoder.decode(SyncPullResponse.self, from: pull.data)
        #expect(result.commands.count == 2)
        #expect(result.commands.map(\.seq) == [1, 2])
        #expect(result.commands.first?.id == addID)

        let delta = try await send(port, method: "GET", path: "/api/sync?after=1")
        let deltaResult = try ProtocolTests.isoDecoder.decode(SyncPullResponse.self, from: delta.data)
        #expect(deltaResult.commands.count == 1)
        #expect(deltaResult.commands[0].seq == 2)
    }

    @Test
    func identityEndpointExposesLibraryAndIsAuthGated() async throws {
        let port = try freePort()
        try await startServer(port: port)

        // Anonymous server: identity returns the library id + display name.
        let identity = try await send(port, method: "GET", path: "/api/identity")
        #expect(identity.status == 200)
        let decoded = try ProtocolTests.isoDecoder.decode(LibraryIdentity.self, from: identity.data)
        #expect(decoded.version == 2)
        #expect(!decoded.id.uuidString.isEmpty)

        // The identity endpoint rides the same auth gate as everything else.
        // Start a second server with basic auth on a fresh port.
        let authedPort = try freePort()
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let libraryPath = root.appending(path: "library", directoryHint: .isDirectory).path
        _ = try await LibraryRepository.create(
            at: URL(fileURLWithPath: libraryPath),
            indexesDirectory: root.appending(path: "indexes", directoryHint: .isDirectory),
            deviceID: UUID()
        )
        let server = try await LibraryServer(configuration: ServerConfiguration(
            port: authedPort,
            libraryPath: libraryPath,
            indexesDirectory: root.appending(path: "server-indexes", directoryHint: .isDirectory),
            username: "alice",
            password: "secret"
        ))
        let app = try await server.makeApplication()
        Task { try await app.run() }
        for _ in 0..<50 {
            if await portResponds(authedPort) { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        let anonymous = try await send(authedPort, method: "GET", path: "/api/identity")
        #expect(anonymous.status == 401)
        let withCredentials = try await send(
            authedPort, method: "GET", path: "/api/identity",
            headers: ["Authorization": "Basic \(Data("alice:secret".utf8).base64EncodedString())"]
        )
        #expect(withCredentials.status == 200)
        let decodedAuthed = try ProtocolTests.isoDecoder.decode(LibraryIdentity.self, from: withCredentials.data)
        #expect(decodedAuthed.name == libraryPath.split(separator: "/").last.map(String.init))
    }

    @Test
    func deleteOfUnknownBookIsNoOp() async throws {
        let port = try freePort()
        try await startServer(port: port)

        // A stale client racing another client's delete pushes a delete for a
        // book the server no longer knows. End-state semantics: no-op SUCCESS.
        let push = SyncPushRequest(commands: [
            ClientCommand(id: UUID(), op: .deleteBook(.init(bookID: UUID()))),
            ClientCommand(id: UUID(), op: .restoreBook(.init(bookID: UUID()))),
        ])
        let pushed = try await send(port, method: "POST", path: "/api/commands",
                                    body: try ProtocolTests.isoEncoder.encode(push))
        #expect(pushed.status == 200)
        let pushResult = try ProtocolTests.isoDecoder.decode(SyncPushResponse.self, from: pushed.data)
        #expect(pushResult.errors.isEmpty)
        #expect(pushResult.applied.count == 2)

        // Both commands are recorded (they define the sync cursor for other
        // clients) and replay cleanly on every pull.
        let pull = try await send(port, method: "GET", path: "/api/sync?after=0")
        let result = try ProtocolTests.isoDecoder.decode(SyncPullResponse.self, from: pull.data)
        #expect(result.commands.count == 2)

        // The server survives: a real add still applies afterwards.
        let addID = UUID()
        let add = SyncPushRequest(commands: [
            ClientCommand(id: addID, op: .addBook(.init(
                bookID: UUID(), title: "After", authors: [], series: nil, seriesIndex: nil,
                tags: [], rating: nil, publisher: nil, publicationDate: nil, addedDate: .now,
                languages: [], identifiers: [:], comments: nil, formats: [], cover: nil
            ))),
        ])
        let pushedAdd = try await send(port, method: "POST", path: "/api/commands",
                                       body: try ProtocolTests.isoEncoder.encode(add))
        let addResult = try ProtocolTests.isoDecoder.decode(SyncPushResponse.self, from: pushedAdd.data)
        #expect(addResult.errors.isEmpty)
        #expect(addResult.applied == [3])
    }

    @Test
    func updateOfUnknownBookIsRejected() async throws {
        let port = try freePort()
        try await startServer(port: port)

        // A command that cannot apply must never enter the journal — it would
        // be re-served to every client on every pull, wedging their replays.
        let push = SyncPushRequest(commands: [
            ClientCommand(id: UUID(), op: .updateBook(.init(
                bookID: UUID(), edit: .init(title: "Ghost")
            ))),
            ClientCommand(id: UUID(), op: .setCover(.init(
                bookID: UUID(), cover: nil
            ))),
        ])
        let pushed = try await send(port, method: "POST", path: "/api/commands",
                                    body: try ProtocolTests.isoEncoder.encode(push))
        #expect(pushed.status == 200)
        let pushResult = try ProtocolTests.isoDecoder.decode(SyncPushResponse.self, from: pushed.data)
        #expect(pushResult.applied.isEmpty)
        #expect(pushResult.errors.count == 2)

        // Nothing was recorded: the journal stays empty and the server remains
        // fully replayable.
        let pull = try await send(port, method: "GET", path: "/api/sync?after=0")
        let result = try ProtocolTests.isoDecoder.decode(SyncPullResponse.self, from: pull.data)
        #expect(result.commands.isEmpty)
    }

    @Test
    func duplicateCommandIdAppliesOnce() async throws {
        let port = try freePort()
        try await startServer(port: port)

        let command = ClientCommand(id: UUID(), op: .addBook(.init(
            bookID: UUID(), title: "Once", authors: ["Bob"],
            series: nil, seriesIndex: nil, tags: [], rating: nil, publisher: nil,
            publicationDate: nil, addedDate: .now, languages: [], identifiers: [:], comments: nil,
            formats: [], cover: nil
        )))
        let body = try ProtocolTests.isoEncoder.encode(SyncPushRequest(commands: [command]))
        let first = try await send(port, method: "POST", path: "/api/commands", body: body)
        let second = try await send(port, method: "POST", path: "/api/commands", body: body)
        let firstResult = try ProtocolTests.isoDecoder.decode(SyncPushResponse.self, from: first.data)
        let secondResult = try ProtocolTests.isoDecoder.decode(SyncPushResponse.self, from: second.data)
        #expect(firstResult.applied == [1])
        #expect(secondResult.applied.isEmpty)

        let pull = try await send(port, method: "GET", path: "/api/sync?after=0")
        let result = try ProtocolTests.isoDecoder.decode(SyncPullResponse.self, from: pull.data)
        #expect(result.commands.count == 1)
    }

    @Test
    func stageUploadThenAddBookMaterializes() async throws {
        let port = try freePort()
        try await startServer(port: port)

        let bookID = UUID()
        let commandID = UUID()
        let content = Data("staged upload bytes".utf8)
        let stage = try await send(
            port, method: "POST",
            path: "/api/stage?command=\(commandID.uuidString)&name=0-book.epub",
            body: content
        )
        #expect(stage.status == 200)
        let staged = try ProtocolTests.isoDecoder.decode(StageResponse.self, from: stage.data)
        #expect(staged.stagedName == "0-book.epub")
        #expect(staged.size == Int64(content.count))

        let push = SyncPushRequest(commands: [ClientCommand(id: commandID, op: .addBook(.init(
            bookID: bookID, title: "Staged", authors: ["Carol"],
            series: nil, seriesIndex: nil, tags: [], rating: nil, publisher: nil,
            publicationDate: nil, addedDate: .now, languages: [], identifiers: [:], comments: nil,
            formats: [.init(kind: "EPUB", filename: "Staged - Carol.epub", contentHash: "abc", size: Int64(content.count), stagedName: "0-book.epub")],
            cover: nil
        )))])
        let pushed = try await send(port, method: "POST", path: "/api/commands",
                                    body: try ProtocolTests.isoEncoder.encode(push))
        #expect(pushed.status == 200)

        let download = try await send(port, method: "GET",
                                      path: "/api/books/\(bookID.uuidString)/download?format=epub")
        #expect(download.status == 200)
        #expect(download.data == content)
    }

    @Test
    func unknownBookReturns404() async throws {
        let port = try freePort()
        try await startServer(port: port)
        let response = try await send(port, method: "GET", path: "/api/books/\(UUID().uuidString)/download")
        #expect(response.status == 404)
    }
}
