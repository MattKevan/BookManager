import Foundation
import Testing
@testable import StacksCore

/// Regression coverage for the core data-layer fixes:
/// - edits seed their HybridLogicalClock from the document's latest clock and
///   name their change files with that clock (no more `0-0-<digest>` files);
/// - a failed multi-step edit rolls back its change files instead of leaving
///   the catalog snapshot stale;
/// - a catalog rebuild quarantines digest-corrupt changes and skips stuck
///   books instead of failing `open()` for the whole library.
@Suite
struct RepositoryIntegrityTests {
    private func library() async throws -> (LibraryRepository, URL, URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let indexes = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let repo = try await LibraryRepository.create(
            at: root, indexesDirectory: indexes, deviceID: UUID()
        )
        return (repo, root, indexes)
    }

    /// The highest clock embedded in a book's change-file names.
    private func maxClockPart(store: ChangeStore, bookID: UUID) async throws -> (physical: Int64, logical: UInt32) {
        var maxClock: (physical: Int64, logical: UInt32) = (0, 0)
        for url in try await store.bookChangeFiles(bookID: bookID) {
            let parts = url.lastPathComponent.split(separator: "-")
            guard parts.count >= 3,
                  let physical = Int64(parts[0]),
                  let logical = UInt32(parts[1]) else { continue }
            if physical > maxClock.physical
                || (physical == maxClock.physical && logical > maxClock.logical) {
                maxClock = (physical, logical)
            }
        }
        return maxClock
    }

    @Test
    func editChangeFilesCarryIncreasingClocks() async throws {
        let (repo, root, indexes) = try await library()
        let book = try await repo.createBook(title: "Original", authors: ["Alice"])
        let store = ChangeStore(layout: LibraryLayout(root: root))

        let afterCreate = try await maxClockPart(store: store, bookID: book.id)
        #expect(afterCreate.physical > 0)

        _ = try await repo.updateBook(id: book.id, edit: BookEdit(title: "Renamed"))
        let afterEdit = try await maxClockPart(store: store, bookID: book.id)
        #expect(afterEdit.physical > afterCreate.physical
            || (afterEdit.physical == afterCreate.physical && afterEdit.logical > afterCreate.logical))

        try await repo.deleteBook(id: book.id)
        let afterDelete = try await maxClockPart(store: store, bookID: book.id)
        #expect(afterDelete.physical > afterEdit.physical
            || (afterDelete.physical == afterEdit.physical && afterDelete.logical > afterEdit.logical))

        _ = try await repo.restoreBook(id: book.id)
        let afterRestore = try await maxClockPart(store: store, bookID: book.id)
        #expect(afterRestore.physical > afterDelete.physical
            || (afterRestore.physical == afterDelete.physical && afterRestore.logical > afterDelete.logical))

        // Delete + restore must converge deterministically on restored: the
        // restore's clock is strictly newer, so no arbitrary tie-break.
        let rebuilt = try await LibraryRepository.open(
            at: root, indexesDirectory: indexes, deviceID: UUID()
        )
        let restored = try #require(try await rebuilt.book(id: book.id))
        #expect(!restored.isDeleted)
        #expect(restored.title == "Renamed")
    }

    @Test
    func updateBookMaterializesFolderForSidecarWrite() async throws {
        let (repo, root, _) = try await library()
        let book = try await repo.createBook(title: "Original", authors: ["Alice"])

        // A synced book whose folder has not been materialized yet (or was
        // trashed externally): the edit must not fail on the metadata.opf
        // sidecar write — the folder is created at the new canonical path.
        let oldFolderURL = LibraryLayout(root: root).root
            .appending(path: book.relativePath, directoryHint: .isDirectory)
        try FileManager.default.removeItem(at: oldFolderURL)

        let updated = try await repo.updateBook(id: book.id, edit: BookEdit(title: "Renamed"))

        #expect(updated.title == "Renamed")
        let newFolderURL = LibraryLayout(root: root).root
            .appending(path: updated.relativePath, directoryHint: .isDirectory)
        #expect(FileManager.default.fileExists(atPath: newFolderURL.path))
        #expect(FileManager.default.fileExists(
            atPath: newFolderURL.appending(path: "metadata.opf").path
        ))

        // The edit is durable and the catalog is consistent after a rebuild.
        let rebuilt = try await repo.rebuildCatalog()
        #expect(rebuilt.booksBuilt == 1)
        #expect(rebuilt.quarantined.isEmpty)
        let reloaded = try #require(try await repo.book(id: book.id))
        #expect(reloaded.title == "Renamed")
    }

    @Test
    func corruptChangeFileIsQuarantinedNotFatal() async throws {
        let (repo, _, _) = try await library()
        let bookA = try await repo.createBook(title: "A", authors: ["Alice"])
        let bookB = try await repo.createBook(title: "B", authors: ["Bob"])
        let store = ChangeStore(layout: LibraryLayout(root: repo.root))

        // Corrupt the root change of book A (garbage bytes, name digest intact).
        let aFiles = try await store.bookChangeFiles(bookID: bookA.id)
        let creation = try #require(aFiles.first)
        try Data("corrupt".utf8).write(to: creation, options: .atomic)

        let report = try await repo.rebuildCatalog()

        #expect(report.quarantined.count == 1)
        #expect(report.quarantined.first?.path.contains("quarantine") == true)
        #expect(report.booksBuilt == 1)
        #expect(report.booksSkipped == [bookA.id])
        #expect(try await repo.books().map(\.id) == [bookB.id])
        let after = try await store.bookChangeFiles(bookID: bookA.id)
        #expect(!after.contains(creation))
    }

    @Test
    func stuckChangeSkipsBookNotLibrary() async throws {
        let (repo, _, _) = try await library()
        let bookA = try await repo.createBook(title: "A", authors: ["Alice"])
        let bookB = try await repo.createBook(title: "B", authors: ["Bob"])
        let store = ChangeStore(layout: LibraryLayout(root: repo.root))

        // Remove the root creation change of book A: its remaining changes are
        // valid but their dependency is gone — the rebuild must skip A, not
        // fail the whole library.
        let aFiles = try await store.bookChangeFiles(bookID: bookA.id)
        let creation = try #require(aFiles.first)
        try FileManager.default.removeItem(at: creation)

        let report = try await repo.rebuildCatalog()

        #expect(report.quarantined.isEmpty)
        #expect(report.booksBuilt == 1)
        #expect(report.booksSkipped == [bookA.id])
        #expect(try await repo.books().map(\.id) == [bookB.id])
    }

    @Test
    func latestClockReflectsNewestFieldClock() throws {
        let deviceID = UUID()
        let document = try AutomergeBookDocument.new(bookID: UUID(), deviceID: deviceID)

        let seed = try document.latestClock()
        #expect(seed?.physicalMilliseconds == 0)  // new() seeds deletions with a (0,0) clock

        _ = try document.setTitle(
            "Range", clock: HybridLogicalClock(physicalMilliseconds: 5_000, nodeID: deviceID)
        )
        _ = try document.setAuthors(
            ["David Epstein"], clock: HybridLogicalClock(physicalMilliseconds: 6_000, nodeID: deviceID)
        )
        _ = try document.setDeleted(
            false, clock: HybridLogicalClock(physicalMilliseconds: 4_000, nodeID: deviceID)
        )

        #expect(try document.latestClock()?.physicalMilliseconds == 6_000)
        #expect(try document.latestClock()?.logical == 0)
        #expect(try document.latestClock()?.nodeID == deviceID)
    }
}
