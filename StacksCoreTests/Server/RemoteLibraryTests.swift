import Foundation
import Testing
@testable import StacksCore

@Suite
struct RemoteLibraryTests {
    private func makeRemote(port: Int) throws -> RemoteLibrary {
        try RemoteLibrary(configuration: .init(
            baseURL: URL(string: "http://127.0.0.1:\(port)")!,
            queueDirectory: ServerTestHarness.queueDirectory()
        ))
    }

    @Test
    func pullAfterPushShowsBookAndConvergesOnSecondClient() async throws {
        let (libraryPath, indexes) = try await ServerTestHarness.makeLibrary()
        let port = try ServerTestHarness.freePort()
        try await ServerTestHarness.startServer(libraryPath: libraryPath, indexesDirectory: indexes, port: port)

        // Client A pushes an addBook + an edit.
        let clientA = try makeRemote(port: port)
        let bookID = UUID()
        let outcome = try await clientA.push(ServerTestHarness.makeAddBook(id: bookID, title: "Remote", authors: ["Alice"]))
        guard case .applied = outcome else {
            Issue.record("expected applied, got \(outcome)")
            return
        }
        _ = try await clientA.push(ClientCommand(id: UUID(), op: .updateBook(.init(
            bookID: bookID, edit: .init(title: "Remote: Revised")
        ))))

        // Client B connects fresh: pull → the book with the edit applied.
        let clientB = try makeRemote(port: port)
        try await clientB.pull()
        let book = try #require(await clientB.book(id: bookID))
        #expect(book.title == "Remote: Revised")
        #expect(await await clientB.books().count == 1)

        // Client A's pull is now a delta (no new commands).
        try await clientA.pull()
        #expect(await clientA.serverSeq == 2)
    }

    @Test
    func stagedUploadMaterializesAndDownloads() async throws {
        let (libraryPath, indexes) = try await ServerTestHarness.makeLibrary()
        let port = try ServerTestHarness.freePort()
        try await ServerTestHarness.startServer(libraryPath: libraryPath, indexesDirectory: indexes, port: port)

        let client = try makeRemote(port: port)
        let bookID = UUID()
        let content = Data("remote upload".utf8)
        let command = ClientCommand(id: bookID, op: .addBook(.init(
            bookID: bookID, title: "Uploaded", authors: ["Bob"],
            series: nil, seriesIndex: nil, tags: [], rating: nil, publisher: nil,
            publicationDate: nil, addedDate: .now, languages: [], identifiers: [:], comments: nil,
            formats: [.init(kind: "EPUB", filename: "Uploaded - Bob.epub", contentHash: "h", size: Int64(content.count), stagedName: "0-book.epub")],
            cover: nil
        )))
        let outcome = try await client.push(command, stagedFiles: ["0-book.epub": content])
        guard case .applied = outcome else {
            Issue.record("expected applied, got \(outcome)")
            return
        }
        let download = try await client.downloadFormat(id: bookID, format: "epub")
        defer { try? FileManager.default.removeItem(at: download.deletingLastPathComponent()) }
        #expect(try Data(contentsOf: download) == content)
    }

    @Test
    func offlineEditQueuesAndFlushesOnReconnect() async throws {
        let (libraryPath, indexes) = try await ServerTestHarness.makeLibrary()
        let port = try ServerTestHarness.freePort()

        // Client configured for the server's port, but the server is DOWN.
        let client = try makeRemote(port: port)
        let bookID = UUID()
        let outcome = try await client.push(ServerTestHarness.makeAddBook(id: bookID, title: "Offline", authors: ["Carol"]))
        guard case .queued = outcome else {
            Issue.record("expected queued while unreachable, got \(outcome)")
            return
        }
        #expect(await client.pendingOfflineCount() == 1)

        // Server comes up; flush converges the library.
        try await ServerTestHarness.startServer(libraryPath: libraryPath, indexesDirectory: indexes, port: port)
        try await client.flushOffline()
        #expect(await client.pendingOfflineCount() == 0)

        try await client.pull()
        let book = try #require(await client.book(id: bookID))
        #expect(book.title == "Offline")
    }

    @Test
    func pullSendsCredentialsWhenConfigured() async throws {
        let (libraryPath, indexes) = try await ServerTestHarness.makeLibrary()
        let port = try ServerTestHarness.freePort()
        try await ServerTestHarness.startServer(
            libraryPath: libraryPath, indexesDirectory: indexes, port: port,
            username: "alice", password: "secret"
        )

        // No credentials → unreachable/server error.
        let anonymous = try makeRemote(port: port)
        await #expect(throws: (any Error).self) {
            try await anonymous.pull()
        }

        // With credentials → pulls cleanly.
        let authed = try RemoteLibrary(configuration: .init(
            baseURL: URL(string: "http://127.0.0.1:\(port)")!,
            credential: .init(username: "alice", password: "secret"),
            queueDirectory: ServerTestHarness.queueDirectory()
        ))
        try await authed.pull()
        #expect(await authed.books().isEmpty)
    }
}
