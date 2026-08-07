import Foundation
import Testing
@testable import StacksCore

@Suite
struct ImportServiceTests {
    private func layout() throws -> LibraryLayout {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let layout = LibraryLayout(root: root)
        try layout.create(manifest: LibraryManifest(id: UUID()))
        return layout
    }

    @Test
    func importsFilesAndReportsDuplicates() async throws {
        let layout = try layout()
        let service = ImportService(layout: layout)
        let repository = MemoryRepository()
        let epub = try Fixtures.makeEPUB(named: "import-1.epub")
        let pdf = try Fixtures.makePDF(named: "import-1.pdf")

        let report = try await service.importFiles([epub, pdf], into: repository)

        #expect(report.imported.count == 2)
        #expect(report.failed.isEmpty)
        #expect(report.duplicates.isEmpty)
        #expect(report.items.count == 2)
    }

    @Test
    func exactDuplicatesAreSkippedNotSilentlyCopied() async throws {
        let layout = try layout()
        let service = ImportService(layout: layout)
        let repository = MemoryRepository()
        let epub = try Fixtures.makeEPUB(named: "import-2.epub")
        let pdf = try Fixtures.makePDF(named: "import-2.pdf")

        _ = try await service.importFiles([epub, pdf], into: repository)
        let second = try await service.importFiles([epub], into: repository)

        #expect(second.duplicates.count == 1)
        #expect(second.imported.isEmpty)
    }

    @Test
    func duplicateImportCleansStaging() async throws {
        let layout = try layout()
        let service = ImportService(layout: layout)
        let repository = MemoryRepository()
        let epub = try Fixtures.makeEPUB(named: "import-4.epub")

        _ = try await service.importFiles([epub], into: repository)
        _ = try await service.importFiles([epub], into: repository)

        let staging = layout.controlRoot.appending(path: "staging", directoryHint: .isDirectory)
        let leftovers = (try? FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? []
        #expect(leftovers.isEmpty)
    }

    @Test
    func likelyDuplicateIsHintedOnImportedItem() async throws {
        let layout = try layout()
        let service = ImportService(layout: layout)
        let existingID = UUID()
        let repository = MemoryRepository(seededBooks: [
            IndexedBook(
                id: existingID,
                title: "Range: Why Generalists Triumph in a Specialized World",
                authors: ["David Epstein"],
                modifiedMilliseconds: 1, isDeleted: false
            )
        ])
        let epub = try Fixtures.makeEPUB(named: "import-3.epub")

        let report = try await service.importFiles([epub], into: repository)

        #expect(report.imported.count == 1)
        let item = try #require(report.imported.first)
        guard case .imported = item.status else {
            Issue.record("expected .imported status, got \(item.status)")
            return
        }
        #expect(item.likelyDuplicateOf == existingID)

        // Same bytes again: still an exact duplicate, not a second likely hint.
        let second = try await service.importFiles([epub], into: repository)
        #expect(second.duplicates.count == 1)
    }

    @Test
    func duplicateIndexIsBuiltOnceNotPerFile() async throws {
        let layout = try layout()
        let service = ImportService(layout: layout)
        let repository = MemoryRepository()
        let epub = try Fixtures.makeEPUB(named: "batch-1.epub")
        let pdf = try Fixtures.makePDF(named: "batch-1.pdf")

        let report = try await service.importFiles([epub, pdf], into: repository)

        #expect(report.imported.count == 2)
        // The whole catalog was materialized ONCE for the whole batch, not per
        // file (the old per-file lookup was O(files × catalog)).
        #expect(await repository.duplicateCheckCount == 1)
    }

    @Test
    func intraRunImportsAreFlaggedAsLikelyDuplicates() async throws {
        let layout = try layout()
        let service = ImportService(layout: layout)
        let repository = MemoryRepository()
        // Same embedded title, different bytes (extra entry → different hash),
        // so the second is NOT an exact duplicate — it must be hinted as a
        // likely duplicate of the first, imported earlier in the SAME batch.
        let first = try Fixtures.makeEPUB(named: "intra-1.epub")
        let second = try Fixtures.makeEPUB(
            named: "intra-2.epub",
            extraEntries: [("OEBPS/extra.txt", Data("extra".utf8))]
        )

        let report = try await service.importFiles([first, second], into: repository)

        #expect(report.imported.count == 2)
        #expect(report.duplicates.isEmpty)
        let hinted = try #require(report.imported.last)
        guard case .imported(let id) = hinted.status else {
            Issue.record("expected .imported status, got \(hinted.status)")
            return
        }
        // The first import's id (registered into the index as it was created).
        #expect(hinted.likelyDuplicateOf != nil)
        #expect(hinted.likelyDuplicateOf != id)
        #expect(await repository.duplicateCheckCount == 1)
    }
}

/// Thin protocol eraser so the importer does not depend on the concrete repository actor.
/// The protocol itself lives in StacksCore (ImportService.swift); this test double
/// conforms to it directly.
actor MemoryRepository: LibraryRepositoryImporting {
    private var hashes: [String: UUID] = [:]
    private var books: [IndexedBook]
    /// How many times `allBooksForDuplicateCheck` was called — lets tests pin
    /// the once-per-batch index build (O(N), not O(files × catalog)).
    private(set) var duplicateCheckCount = 0

    init(seededBooks: [IndexedBook] = []) {
        books = seededBooks
    }

    func bookIDs(byFormatHash contentHash: String) async throws -> [UUID] {
        hashes[contentHash].map { [$0] } ?? []
    }

    func allBooksForDuplicateCheck() async throws -> [IndexedBook] {
        duplicateCheckCount += 1
        return books
    }

    func createBook(
        metadata: NewBookMetadata,
        staged: [BookFolder.StagedFile],
        cover: Data?
    ) async throws -> IndexedBook {
        let id = UUID()
        for file in staged {
            hashes[file.contentHash] = id
        }
        let book = IndexedBook(
            id: id, title: metadata.title, authors: metadata.authors,
            modifiedMilliseconds: 1, isDeleted: false
        )
        books.append(book)
        return book
    }
}
