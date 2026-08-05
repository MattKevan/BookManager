import Foundation
import Testing
@testable import StacksCore

@Suite
struct CoverUpdateTests {
    private func repository() async throws -> (LibraryRepository, URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let indexURL = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).sqlite")
        let repo = try await LibraryRepository.create(
            at: root, indexesDirectory: indexURL.deletingLastPathComponent(), deviceID: UUID()
        )
        return (repo, root)
    }

    @Test
    func updateCoverWritesChangeMaterializesAndUpdatesCatalog() async throws {
        let (repo, root) = try await repository()
        let book = try await repo.createBook(title: "Covered", authors: ["Alice"])
        #expect(book.coverHash == nil)

        let cover = Data(repeating: 0xFF, count: 64)
        let updated = try await repo.updateCover(coverData: cover, for: book.id)

        #expect(updated.coverHash != nil)
        // Materialized cover.jpg exists with the exact bytes.
        let coverURL = root
            .appending(path: updated.relativePath, directoryHint: .isDirectory)
            .appending(path: "cover.jpg")
        #expect(FileManager.default.fileExists(atPath: coverURL.path))
        #expect(try Data(contentsOf: coverURL) == cover)
        // The change is durable: rebuild the catalog from changes and the cover survives.
        try await repo.rebuildCatalog()
        let rebuilt = try await repo.books().first { $0.id == book.id }
        #expect(rebuilt?.coverHash == updated.coverHash)
    }

    @Test
    func updateCoverThrowsForMissingBook() async throws {
        let (repo, _) = try await repository()
        let ghost = UUID()
        await #expect(throws: LibraryRepositoryError.bookNotFound(ghost)) {
            _ = try await repo.updateCover(coverData: Data([1]), for: ghost)
        }
    }
}
