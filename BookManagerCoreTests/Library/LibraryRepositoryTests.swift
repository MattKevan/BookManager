import Foundation
import Testing
@testable import BookManagerCore

@Suite
struct LibraryRepositoryTests {
    @Test
    func createsBookChangeAndRebuildsFreshCatalog() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let firstIndexes = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let secondIndexes = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let deviceID = UUID()

        let repository = try await LibraryRepository.create(
            at: root,
            indexesDirectory: firstIndexes,
            deviceID: deviceID
        )
        let created = try await repository.createBook(
            title: "Range",
            authors: ["David Epstein"],
            at: Date(timeIntervalSince1970: 1)
        )

        let rebuilt = try await LibraryRepository.open(
            at: root,
            indexesDirectory: secondIndexes,
            deviceID: UUID()
        )

        #expect(try await rebuilt.books() == [created])
    }

    @Test
    func rejectsUnsupportedLibraryFormat() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let layout = LibraryLayout(root: root)
        try layout.create(manifest: LibraryManifest(id: UUID(), formatVersion: 99))

        await #expect(throws: LibraryRepositoryError.unsupportedFormat(99)) {
            try await LibraryRepository.open(
                at: root,
                indexesDirectory: FileManager.default.temporaryDirectory
                    .appending(path: UUID().uuidString, directoryHint: .isDirectory),
                deviceID: UUID()
            )
        }
    }
}
