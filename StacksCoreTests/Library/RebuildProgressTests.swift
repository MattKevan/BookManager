import Foundation
import Synchronization
import Testing
@testable import StacksCore

@Suite
struct RebuildProgressTests {
    private func libraryWithBooks(_ count: Int) async throws -> (LibraryRepository, URL, URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let indexURL = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).sqlite")
        let repo = try await LibraryRepository.create(
            at: root, indexesDirectory: indexURL.deletingLastPathComponent(), deviceID: UUID()
        )
        for i in 0..<count {
            _ = try await repo.createBook(title: "Book \(i)", authors: ["Alice"])
        }
        return (repo, root, indexURL)
    }

    @Test
    func progressIsMonotonicAndCompletes() async throws {
        let (repo, _, _) = try await libraryWithBooks(3)
        let values = Mutex<[Double]>([])
        try await repo.rebuildCatalog(
            progress: { value in values.withLock { $0.append(value) } },
            cancelled: { false }
        )
        let collected = values.withLock { $0 }
        #expect(collected == collected.sorted())
        #expect(collected.last == 1)
        #expect(try await repo.books().count == 3)
    }

    @Test
    func cancellationStopsRebuild() async throws {
        let (repo, _, _) = try await libraryWithBooks(5)
        let seen = Mutex<Int>(0)
        do {
            try await repo.rebuildCatalog(
                progress: { _ in seen.withLock { $0 += 1 } },
                cancelled: { seen.withLock { $0 } >= 2 }
            )
            Issue.record("expected rebuildCancelled")
        } catch LibraryRepositoryError.rebuildCancelled {
            #expect(seen.withLock { $0 } >= 2)
        }
    }
}
