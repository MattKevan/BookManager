import Foundation
import Testing
@testable import StacksCore

@Suite
struct JournalRebuildTests {
    @Test
    func createEditDeleteSurviveRebuild() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let indexes = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let repo = try await LibraryRepository.create(
            at: root, indexesDirectory: indexes, deviceID: UUID()
        )
        let book = try await repo.createBook(title: "Range", authors: ["Alice"])
        _ = try await repo.updateBook(id: book.id, edit: BookEdit(title: "Range: Revised"))
        try await repo.deleteBook(id: book.id)

        // A fresh repository over the same root rebuilds from the journal.
        let reopened = try await LibraryRepository.open(
            at: root, indexesDirectory: indexes, deviceID: UUID()
        )
        #expect(try await reopened.books().isEmpty)
        let deleted = try await reopened.deletedBooks()
        #expect(deleted.map(\.title) == ["Range: Revised"])
    }

    @Test
    func editRenameAndFolderSidecarSurviveRebuild() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let indexes = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let repo = try await LibraryRepository.create(
            at: root, indexesDirectory: indexes, deviceID: UUID()
        )
        let book = try await repo.createBook(title: "Original", authors: ["Alice"])
        let updated = try await repo.updateBook(id: book.id, edit: BookEdit(title: "Renamed"))

        // The folder was renamed to the new canonical path with a fresh OPF.
        let folderURL = LibraryLayout(root: root).root
            .appending(path: updated.relativePath, directoryHint: .isDirectory)
        #expect(FileManager.default.fileExists(atPath: folderURL.path))
        #expect(FileManager.default.fileExists(
            atPath: folderURL.appending(path: "metadata.opf").path
        ))

        let reopened = try await LibraryRepository.open(
            at: root, indexesDirectory: indexes, deviceID: UUID()
        )
        let reloaded = try #require(try await reopened.book(id: book.id))
        #expect(reloaded.title == "Renamed")
        #expect(reloaded.relativePath == updated.relativePath)
    }

    @Test
    func snapshotAcceleratesRebuildWithoutChangingResult() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let indexes = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let repo = try await LibraryRepository.create(
            at: root, indexesDirectory: indexes, deviceID: UUID()
        )
        for i in 0..<3 {
            _ = try await repo.createBook(title: "Book \(i)", authors: ["Alice"])
        }
        // Force a snapshot past the commands (the auto-snapshot threshold is
        // 1000 commands; this is the explicit write).
        let journal = Journal(layout: LibraryLayout(root: root))
        try await journal.open()
        try await journal.writeSnapshot(JournalSnapshot(
            lastSeq: await journal.currentSeq,
            books: (try await repo.books()).map { JournalSnapshot.Book(book: $0) }
        ))

        let reopened = try await LibraryRepository.open(
            at: root, indexesDirectory: indexes, deviceID: UUID()
        )
        #expect(try await reopened.books().count == 3)
    }

    @Test
    func restoreSurvivesRebuild() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let indexes = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let repo = try await LibraryRepository.create(
            at: root, indexesDirectory: indexes, deviceID: UUID()
        )
        let book = try await repo.createBook(title: "Range", authors: ["Alice"])
        try await repo.deleteBook(id: book.id)
        _ = try await repo.restoreBook(id: book.id)

        let reopened = try await LibraryRepository.open(
            at: root, indexesDirectory: indexes, deviceID: UUID()
        )
        #expect(try await reopened.books().map(\.title) == ["Range"])
        #expect(try await reopened.deletedBooks().isEmpty)
    }
}
