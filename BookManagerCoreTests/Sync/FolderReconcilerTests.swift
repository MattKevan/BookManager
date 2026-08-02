import Foundation
import Testing
@testable import BookManagerCore

@Suite
struct FolderReconcilerTests {
    private struct Harness {
        let layout: LibraryLayout
        let catalog: LocalCatalog
        let repository: LibraryRepository
        let deviceID = UUID()
        let root: URL

        init() async throws {
            root = FileManager.default.temporaryDirectory
                .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            layout = LibraryLayout(root: root)
            try layout.create(manifest: LibraryManifest(id: UUID()))
            let indexURL = FileManager.default.temporaryDirectory
                .appending(path: "\(UUID().uuidString).sqlite")
            catalog = try LocalCatalog(databaseURL: indexURL)
            let indexesDir = indexURL.deletingLastPathComponent()
            repository = try await LibraryRepository.open(
                at: root, indexesDirectory: indexesDir, deviceID: deviceID
            )
        }

        func reconciler() -> FolderReconciler {
            FolderReconciler(layout: layout, catalog: catalog, deviceID: deviceID)
        }

        /// Materializes a book folder (with one format file) via the
        /// repository, then keeps the reconciler's catalog current (the
        /// repository owns a separate index). A format file is essential —
        /// hash-based folder discovery requires it.
        func createBook(title: String) async throws -> IndexedBook {
            let tempDir = FileManager.default.temporaryDirectory
                .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let fileURL = tempDir.appending(path: "book.epub")
            try Data("test epub content \(UUID().uuidString)".utf8).write(to: fileURL)
            let staged = try await repository.stageFile(from: fileURL)
            let book = try await repository.createBook(
                metadata: NewBookMetadata(title: title, authors: ["Alice"]),
                staged: [staged],
                cover: nil
            )
            try? FileManager.default.removeItem(at: tempDir)
            try await catalog.upsert(book)
            return book
        }

        func folderURL(_ relativePath: String) -> URL {
            layout.root.appending(path: relativePath, directoryHint: .isDirectory)
        }
    }

    @Test
    func repointsFolderToCanonicalPathAfterRename() async throws {
        let h = try await Harness()
        let book = try await h.createBook(title: "Original")
        let canonical = CanonicalPathBuilder.relativeDirectory(
            bookID: book.id, title: book.title, authors: book.authors
        )
        // Simulate a divergent path: the folder was moved on disk (as if by a
        // manual move or an interrupted sync) and its id marker lost.
        let folderURL = h.folderURL(canonical)
        let moved = h.root.appending(path: "Somewhere Else", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: folderURL, to: moved)

        let report = try await h.reconciler().reconcile()

        #expect(report.renamed == [book.id])
        #expect(report.missingFolders.isEmpty)
        #expect(FileManager.default.fileExists(atPath: folderURL.path))
        let stored = try await h.catalog.book(id: book.id)
        #expect(stored?.relativePath == canonical)
    }

    @Test
    func noDivergenceLeavesEverythingInPlace() async throws {
        let h = try await Harness()
        let book = try await h.createBook(title: "Racer")
        let canonical = CanonicalPathBuilder.relativeDirectory(
            bookID: book.id, title: book.title, authors: book.authors
        )

        let report = try await h.reconciler().reconcile()

        #expect(report.renamed.isEmpty)
        #expect(report.conflictCopies.isEmpty)
        #expect(report.missingFolders.isEmpty)
        #expect(FileManager.default.fileExists(atPath: h.folderURL(canonical).path))
    }

    @Test
    func adoptsOrForksOnCanonicalPathRace() async throws {
        let h = try await Harness()
        let book = try await h.createBook(title: "Racer")
        let canonical = CanonicalPathBuilder.relativeDirectory(
            bookID: book.id, title: book.title, authors: book.authors
        )
        // The canonical name is taken by DIFFERENT content (another Mac wrote
        // something there); the real folder sits at a stale path. Reconcile
        // must fork the imposter (never overwrite) and move the real folder in.
        let canonicalURL = h.folderURL(canonical)
        let stale = h.root.appending(path: "Stale Place", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: canonicalURL, to: stale)
        try FileManager.default.createDirectory(at: canonicalURL, withIntermediateDirectories: true)
        try Data("imposter".utf8).write(to: canonicalURL.appending(path: "junk.txt"))

        let report = try await h.reconciler().reconcile()

        #expect(report.renamed == [book.id])
        #expect(report.conflictCopies.count == 1)
        // The imposter is preserved (forked), not deleted.
        #expect(FileManager.default.fileExists(atPath: report.conflictCopies[0].path))
        // The real content is back at the canonical path.
        let realFile = canonicalURL.appending(path: book.formats[0].filename)
        #expect(FileManager.default.fileExists(atPath: realFile.path))
    }

    @Test
    func rePointsAfterMetadataEditFromAnotherMac() async throws {
        let h = try await Harness()
        let book = try await h.createBook(title: "Before")
        // Simulate merged metadata from another Mac: the title changed in the
        // document, so the canonical path moved — but the on-disk folder is
        // still at the pre-merge path.
        let snapshot = try await h.catalog.snapshot(bookID: book.id)!
        let document = try AutomergeBookDocument(snapshot: snapshot, deviceID: h.deviceID)
        var clock = HybridLogicalClock(nodeID: h.deviceID)
        _ = try document.setTitle("After", clock: clock.tick())
        let resolved = try document.resolvedBook()
        let expected = CanonicalPathBuilder.relativeDirectory(
            bookID: book.id, title: resolved.title, authors: resolved.authors
        )
        let merged = try IndexedBookFactory.make(
            resolved: resolved, bookID: book.id, path: expected, snapshot: document.snapshot()
        )
        try await h.catalog.upsert(merged)
        let after = try await h.catalog.book(id: book.id)!
        #expect(after.title == "After")

        let report = try await h.reconciler().reconcile()

        #expect(report.renamed == [book.id])
        let stored = try await h.catalog.book(id: book.id)
        #expect(stored?.relativePath == expected)
        #expect(FileManager.default.fileExists(atPath: h.folderURL(expected).path))
    }

    @Test
    func missingFoldersAreRecordedNotFabricated() async throws {
        let h = try await Harness()
        let book = try await h.createBook(title: "Ghost")
        let canonical = CanonicalPathBuilder.relativeDirectory(
            bookID: book.id, title: book.title, authors: book.authors
        )
        try FileManager.default.removeItem(at: h.folderURL(canonical))

        let report = try await h.reconciler().reconcile()

        #expect(report.missingFolders == [book.id])
        #expect(report.errors.isEmpty)
    }

    @Test
    func restoresTrashEntryForNonDeletedBook() async throws {
        let h = try await Harness()
        let book = try await h.createBook(title: "Resurrected")
        let canonical = CanonicalPathBuilder.relativeDirectory(
            bookID: book.id, title: book.title, authors: book.authors
        )
        // Simulate a delete-then-restore on the other Mac: the folder sits in
        // the library trash (moved there exactly as `BookFolder.trash` does —
        // trashRoot/<bookID> becomes the folder) while the catalog row is
        // non-deleted.
        try FileManager.default.createDirectory(at: h.layout.trashRoot, withIntermediateDirectories: true)
        let trashDir = h.layout.trashRoot.appending(path: book.id.uuidString, directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: h.folderURL(canonical), to: trashDir)

        let report = try await h.reconciler().reconcile()

        #expect(report.restoredFromTrash == [book.id])
        #expect(report.missingFolders.isEmpty)
        #expect(FileManager.default.fileExists(atPath: h.folderURL(canonical).path))
        #expect(!FileManager.default.fileExists(atPath: trashDir.path))
    }

    @Test
    func trashesFolderOfDeletedBook() async throws {
        let h = try await Harness()
        let book = try await h.createBook(title: "Doomed")
        // A deleted book whose folder is still in place: reconcile must move it
        // into the library trash.
        let deleted = IndexedBook(
            id: book.id, title: book.title, authors: book.authors,
            relativePath: book.relativePath,
            modifiedMilliseconds: book.modifiedMilliseconds,
            isDeleted: true, snapshot: book.snapshot
        )
        try await h.catalog.upsert(deleted)

        let report = try await h.reconciler().reconcile()

        #expect(report.errors.isEmpty)
        let trashDir = h.layout.trashRoot.appending(path: book.id.uuidString, directoryHint: .isDirectory)
        #expect(FileManager.default.fileExists(atPath: trashDir.path))
    }

    @Test
    func conflictCopiesAreNeverDiscovered() async throws {
        // Regression: a conflict-copy sibling embeds the book's short id and
        // would be found by the discovery scan when the canonical folder is
        // gone — re-forked again on the next pass (unbounded folder growth).
        // The scan must never adopt, rename, or re-fork conflict copies.
        let h = try await Harness()
        let book = try await h.createBook(title: "Loop")
        let canonical = CanonicalPathBuilder.relativeDirectory(
            bookID: book.id, title: book.title, authors: book.authors
        )
        try FileManager.default.removeItem(at: h.folderURL(canonical))
        let shortID = String(book.id.uuidString.prefix(8)).lowercased()
        let conflictURL = h.folderURL(canonical + " (conflict \(shortID))")
        try FileManager.default.createDirectory(at: conflictURL, withIntermediateDirectories: true)

        let report = try await h.reconciler().reconcile()

        #expect(report.missingFolders == [book.id])
        #expect(report.conflictCopies.isEmpty)
        #expect(report.renamed.isEmpty)
        // The conflict copy is preserved untouched.
        #expect(FileManager.default.fileExists(atPath: conflictURL.path))
    }

    @Test
    func emptyRelativePathIsGuardedNotRenamed() async throws {
        // A malformed row: no materialized folder (empty relativePath, no
        // formats). Reconcile must never treat the library ROOT as the book
        // folder — with empty formats `folderMatches` is vacuously true and the
        // root would be renamed/forked as if it were the book (the 10k
        // benchmark found a ~55s root-rename attempt). The row is surfaced in
        // errors and left alone.
        let h = try await Harness()
        let malformed = IndexedBook(
            id: UUID(), title: "Malformed", authors: ["Alice"],
            relativePath: "",
            modifiedMilliseconds: 1_000, isDeleted: false, snapshot: Data([1])
        )
        try await h.catalog.upsert(malformed)

        let report = try await h.reconciler().reconcile()

        #expect(report.errors.contains {
            $0.contains("empty relativePath") && $0.contains(malformed.id.uuidString)
        })
        #expect(!report.missingFolders.contains(malformed.id))
        #expect(report.renamed.isEmpty)
        #expect(report.adopted.isEmpty)
        #expect(report.conflictCopies.isEmpty)
        // The library root was not renamed or moved.
        #expect(FileManager.default.fileExists(atPath: h.root.path))
        #expect(FileManager.default.fileExists(atPath: h.layout.controlRoot.path))
    }

    @Test
    func discoveryStillFindsStrayFoldersViaIndex() async throws {
        let h = try await Harness()
        let book = try await h.createBook(title: "Indexed")
        let canonical = CanonicalPathBuilder.relativeDirectory(
            bookID: book.id, title: book.title, authors: book.authors
        )
        // Move the folder somewhere non-canonical (the discovery case).
        let folderURL = h.layout.root.appending(path: canonical, directoryHint: .isDirectory)
        let moved = h.layout.root.appending(path: "Stray \(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: folderURL, to: moved)

        let report = try await h.reconciler().reconcile()
        #expect(report.renamed == [book.id])
        #expect(report.missingFolders.isEmpty)
        #expect(FileManager.default.fileExists(atPath: folderURL.path))
    }
}
