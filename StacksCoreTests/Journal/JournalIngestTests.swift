import Foundation
import Testing
@testable import StacksCore

@Suite
struct JournalIngestTests {
    private func makeRepo() async throws -> (LibraryRepository, URL, URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let indexes = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let repo = try await LibraryRepository.create(at: root, indexesDirectory: indexes, deviceID: UUID())
        return (repo, root, indexes)
    }

    @Test
    func ingestAppendsWithServerSeqAndDedupes() async throws {
        let (repo, _, _) = try await makeRepo()
        let bookID = UUID()
        let commandID = UUID()
        let command = JournalCommand(
            id: commandID, seq: 0, ts: .now,
            op: .addBook(.init(
                bookID: bookID, title: "Network", authors: ["Alice"],
                series: nil, seriesIndex: nil, tags: [], rating: nil, publisher: nil,
                publicationDate: nil, addedDate: .now, languages: [], identifiers: [:], comments: nil,
                formats: [], cover: nil
            ))
        )
        try await repo.ingest(command)
        try await repo.ingest(command)  // duplicate id — no-op

        #expect(try await repo.books().map(\.title) == ["Network"])
        #expect(await repo.journalSeq() == 1)

        let records = try await repo.journalRecords(after: 0)
        #expect(records.count == 1)
        #expect(records[0].seq == 1)
        #expect(records[0].id == commandID)
    }

    @Test
    func ingestAddBookMaterializesStagedUpload() async throws {
        let (repo, root, _) = try await makeRepo()
        let bookID = UUID()
        let commandID = UUID()
        // The network layer stages the uploaded file before pushing the command.
        let content = Data("uploaded epub bytes".utf8)
        let stagedName = "0-upload.epub"
        try await repo.stageUploadedFile(content, commandID: commandID, stagedName: stagedName)
        let command = JournalCommand(
            id: commandID, seq: 0, ts: .now,
            op: .addBook(.init(
                bookID: bookID, title: "Uploaded", authors: ["Bob"],
                series: nil, seriesIndex: nil, tags: ["tech"], rating: nil, publisher: nil,
                publicationDate: nil, addedDate: .now, languages: [], identifiers: [:], comments: nil,
                formats: [.init(kind: "EPUB", filename: "Uploaded - Bob.epub", contentHash: "hash", size: Int64(content.count), stagedName: stagedName)],
                cover: nil
            ))
        )
        try await repo.ingest(command)

        let book = try #require(try await repo.books().first)
        #expect(book.title == "Uploaded")
        #expect(book.formats.count == 1)
        // The format file was materialized into the book folder.
        let fileURL = LibraryLayout(root: root).root
            .appending(path: book.relativePath, directoryHint: .isDirectory)
            .appending(path: "Uploaded - Bob.epub")
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        #expect(try Data(contentsOf: fileURL) == content)
        // The command staging directory was consumed.
        let stagingDir = LibraryLayout(root: root).stagingRoot
            .appending(path: commandID.uuidString, directoryHint: .isDirectory)
        #expect(!FileManager.default.fileExists(atPath: stagingDir.path))
    }

    @Test
    func journalRecordsAfterCursorReturnsDelta() async throws {
        let (repo, _, _) = try await makeRepo()
        let first = try await repo.createBook(title: "One", authors: ["A"])
        _ = try await repo.updateBook(id: first.id, edit: BookEdit(title: "One: Revised"))
        let seq = await repo.journalSeq()

        let delta = try await repo.journalRecords(after: seq - 1)
        #expect(delta.count == 1)
        #expect(delta[0].seq == seq)
        #expect(try await repo.journalRecords(after: seq).isEmpty)
    }
}
