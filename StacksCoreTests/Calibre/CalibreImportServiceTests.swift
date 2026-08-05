import Foundation
import Testing
@testable import StacksCore

@Suite
struct CalibreImportServiceTests {
    private func layout() throws -> LibraryLayout {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let layout = LibraryLayout(root: root)
        try layout.create(manifest: LibraryManifest(id: UUID()))
        return layout
    }

    private func records(from library: URL) throws -> [CalibreBookRecord] {
        let reader = try CalibreReader.open(libraryURL: library)
        defer { try? reader.close() }
        return try reader.books()
    }

    @Test
    func importsAllSelectedBooks() async throws {
        let layout = try layout()
        let service = CalibreImportService(layout: layout)
        let repository = CalibreMemoryRepository()
        let library = try CalibreFixture.makeLibrary(named: "svc-all-\(UUID().uuidString)")
        let records = try records(from: library)

        let report = try await service.importBooks(
            records, from: library.path,
            libraryID: "acceptance-fixture-uuid",
            selection: [1, 2, 4],
            into: repository
        )

        #expect(report.imported.map(\.calibreID) == [1, 2, 4])
        #expect(report.duplicates.isEmpty)
        #expect(report.failed.isEmpty)
        #expect(report.skipped.isEmpty)
        #expect(report.summary.contains("3 imported"))

        let created = await repository.createdBooks()
        #expect(created.count == 3)

        // Book 1 exercises the full mapping matrix (authors ordered, series,
        // halved rating, julian dates, identifiers, HTML comments, raw payload).
        let first = try #require(created.first)
        #expect(first.metadata.title == "Range: Why Generalists Triumph in a Specialized World")
        #expect(first.metadata.authors == ["David Epstein", "Peter Brown"])
        #expect(first.metadata.series == "Studies")
        #expect(first.metadata.seriesIndex == 1.5)
        #expect(first.metadata.tags == ["Science", "Sport"])
        #expect(first.metadata.rating == 4)
        #expect(first.metadata.publisher == "Riverhead")
        #expect(first.metadata.languages == ["eng", "fra"])
        #expect(first.metadata.identifiers["isbn"] == "978-0-7352-2129-1")
        #expect(first.metadata.identifiers["asin"] == "B07VWM1Z2B")
        #expect(first.metadata.comments == "<p>Great book</p>")
        #expect(first.metadata.publicationDate == Date(timeIntervalSince1970: 1_559_001_600))
        #expect(first.metadata.addedDate == Date(timeIntervalSince1970: 1_705_276_800))
        #expect(first.metadata.rawMetadata?["calibre.custom.genre"] == "science")
        #expect(first.metadata.rawMetadata?["calibre.custom.shelves"] == "[\"read\",\"favorites\"]")
        #expect(first.metadata.rawMetadata?["calibre.lccn"] == "2018049465")
        #expect(first.stagedCount == 2)
        #expect(first.cover != nil)
    }

    @Test
    func subsetSelectionImportsOnlySelected() async throws {
        let layout = try layout()
        let service = CalibreImportService(layout: layout)
        let repository = CalibreMemoryRepository()
        let library = try CalibreFixture.makeLibrary(named: "svc-subset-\(UUID().uuidString)")
        let records = try records(from: library)

        let report = try await service.importBooks(
            records, from: library.path,
            libraryID: "acceptance-fixture-uuid",
            selection: [1, 2],
            into: repository
        )

        #expect(report.items.map(\.calibreID) == [1, 2])
        #expect(report.imported.count == 2)
        #expect((await repository.createdBooks()).count == 2)
    }

    @Test
    func exactDuplicatesAreSkipped() async throws {
        let layout = try layout()
        let service = CalibreImportService(layout: layout)
        let library = try CalibreFixture.makeLibrary(named: "svc-dup-\(UUID().uuidString)")
        let records = try records(from: library)

        // Book 1's EPUB format is already in the library.
        let epubURL = library.appending(path: "David Epstein/Range (1)/Range - David Epstein.epub")
        let epubHash = BookFolder.contentHash(try Data(contentsOf: epubURL))
        let existingID = UUID()
        let repository = CalibreMemoryRepository(seededHashes: [epubHash: existingID])

        let report = try await service.importBooks(
            records, from: library.path,
            libraryID: "acceptance-fixture-uuid",
            selection: [1, 2],
            into: repository
        )

        #expect(report.duplicates.count == 1)
        #expect(report.duplicates[0].calibreID == 1)
        guard case .duplicate(let matching) = report.duplicates[0].status else {
            Issue.record("expected .duplicate status, got \(report.duplicates[0].status)")
            return
        }
        #expect(matching == existingID)
        #expect(report.imported.map(\.calibreID) == [2])
        #expect(report.failed.isEmpty)

        // No silent copy of the duplicate book: only book 2 was created.
        let created = await repository.createdBooks()
        #expect(created.count == 1)
        #expect(created[0].metadata.title == "Talent")

        // Staging was cleaned: no leftover staged files or directories.
        let staging = layout.controlRoot.appending(path: "staging", directoryHint: .isDirectory)
        let leftovers = (try? FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? []
        #expect(leftovers.isEmpty)
    }

    @Test
    func resumeSkipsCompletedBooks() async throws {
        let layout = try layout()
        let library = try CalibreFixture.makeLibrary(named: "svc-resume-\(UUID().uuidString)")
        let records = try records(from: library)

        // First run: book 2 ("Talent") fails inside the repository.
        let failing = CalibreMemoryRepository(failOnTitle: "Talent")
        let service = CalibreImportService(layout: layout)
        let first = try await service.importBooks(
            records, from: library.path,
            libraryID: "acceptance-fixture-uuid",
            selection: [1, 2],
            into: failing
        )
        #expect(first.imported.map(\.calibreID) == [1])
        #expect(first.failed.map(\.calibreID) == [2])

        // Progress records only the completed book.
        let progressURL = CalibreImportService.progressFileURL(sourcePath: library.path, layout: layout)
        let progress = try JSONDecoder().decode(
            CalibreImportProgress.self, from: Data(contentsOf: progressURL)
        )
        #expect(progress.completedBookIDs == [1])
        #expect(progress.selection == [1, 2])
        #expect(progress.libraryID == "acceptance-fixture-uuid")
        #expect(progress.sourcePath == library.path)

        // Second run with a healthy repository: the completed book is skipped,
        // the failed one imports.
        let healthy = CalibreMemoryRepository()
        let second = try await service.importBooks(
            records, from: library.path,
            libraryID: "acceptance-fixture-uuid",
            selection: [1, 2],
            into: healthy
        )
        #expect(second.skipped.map(\.calibreID) == [1])
        #expect(second.imported.map(\.calibreID) == [2])
        #expect(second.failed.isEmpty)
        let created = await healthy.createdBooks()
        #expect(created.count == 1)
        #expect(created[0].metadata.title == "Talent")
    }

    @Test
    func progressFileIsWrittenUnderControlRoot() async throws {
        let layout = try layout()
        let service = CalibreImportService(layout: layout)
        let repository = CalibreMemoryRepository()
        let library = try CalibreFixture.makeLibrary(named: "svc-progress-\(UUID().uuidString)")
        let records = try records(from: library)

        _ = try await service.importBooks(
            records, from: library.path,
            libraryID: "acceptance-fixture-uuid",
            selection: [1, 2],
            into: repository
        )

        let url = CalibreImportService.progressFileURL(sourcePath: library.path, layout: layout)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(url.deletingLastPathComponent().lastPathComponent
                == CalibreImportService.sourcePathHash(library.path))
        let progress = try JSONDecoder().decode(
            CalibreImportProgress.self, from: Data(contentsOf: url)
        )
        #expect(progress.completedBookIDs == [1, 2])
    }

    @Test
    func missingFormatFilesFailTheBook() async throws {
        let layout = try layout()
        let service = CalibreImportService(layout: layout)
        let repository = CalibreMemoryRepository()
        let library = try CalibreFixture.makeLibrary(named: "svc-missing-\(UUID().uuidString)")
        let records = try records(from: library)

        let report = try await service.importBooks(
            records, from: library.path,
            libraryID: "acceptance-fixture-uuid",
            selection: [6, 1],
            into: repository
        )

        let failedBook = report.failed.first { $0.calibreID == 6 }
        #expect(failedBook != nil)
        if case .failed(let message) = failedBook?.status {
            #expect(message.contains("Ghost"))
        }
        #expect(report.imported.map(\.calibreID) == [1])
        // The missing-format book was never staged or created.
        #expect((await repository.createdBooks()).count == 1)
    }

    @Test
    func blobCoversArePassedThrough() async throws {
        let layout = try layout()
        let service = CalibreImportService(layout: layout)
        let repository = CalibreMemoryRepository()
        let library = try CalibreFixture.makeVariantLibrary(
            named: "svc-blob-\(UUID().uuidString)", userVersion: 26, extraColumns: true
        )
        let records = try records(from: library)

        let report = try await service.importBooks(
            records, from: library.path,
            libraryID: "acceptance-fixture-uuid",
            selection: [1],
            into: repository
        )
        #expect(report.imported.count == 1)

        let created = await repository.createdBooks()
        let first = try #require(created.first)
        #expect(first.cover == Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]))
        #expect(first.metadata.rawMetadata?["calibre.pages"] == "320")
    }

    @Test
    func reportsMonotonicProgressAcrossSelectedBooks() async throws {
        let layout = try layout()
        let service = CalibreImportService(layout: layout)
        let repository = CalibreMemoryRepository()
        let library = try CalibreFixture.makeLibrary(named: "svc-progress-frac-\(UUID().uuidString)")
        let records = try records(from: library)

        let samples = LockedBox<[Double]>([])
        let report = try await service.importBooks(
            records, from: library.path,
            libraryID: "acceptance-fixture-uuid",
            selection: [1, 2, 4],
            into: repository,
            progress: { samples.append($0) }
        )

        #expect(report.imported.map(\.calibreID) == [1, 2, 4])
        // One report per selected book, ending at 1.0.
        #expect(samples.value == [1.0 / 3.0, 2.0 / 3.0, 1.0])
    }

    @Test
    func duplicateCheckRunsOnceNotPerBook() async throws {
        let layout = try layout()
        let service = CalibreImportService(layout: layout)
        let repository = CalibreMemoryRepository()
        let library = try CalibreFixture.makeLibrary(named: "svc-dupcheck-\(UUID().uuidString)")
        let records = try records(from: library)

        // Regression: the duplicate-check index must be loaded once per
        // import, not once per book (O(N) not O(N^2) for large libraries).
        _ = try await service.importBooks(
            records, from: library.path,
            libraryID: "acceptance-fixture-uuid",
            selection: [1, 2, 4],
            into: repository
        )

        #expect(await repository.duplicateCheckCallCount() == 1)
    }

    @Test
    func intraRunLikelyDuplicateIsDetected() async throws {
        let layout = try layout()
        let service = CalibreImportService(layout: layout)
        let repository = CalibreMemoryRepository()
        let library = try CalibreFixture.makeLibrary(named: "svc-intrarun-\(UUID().uuidString)")
        let records = try records(from: library)

        // A second record with book 1's title + first author but a DIFFERENT
        // format file (so it is not an exact-content duplicate). Importing
        // both in one run must flag the second as a likely duplicate of the
        // first — the incremental index registers each imported book.
        let book1 = try #require(records.first { $0.calibreID == 1 })
        let book2 = try #require(records.first { $0.calibreID == 2 })
        let twin = CalibreBookRecord(
            calibreID: 101,
            title: book1.title,
            authors: book1.authors,
            series: book1.series,
            seriesIndex: book1.seriesIndex,
            tags: book1.tags,
            rating: book1.rating,
            publisher: book1.publisher,
            publicationDate: book1.publicationDate,
            addedDate: book1.addedDate,
            languages: book1.languages,
            identifiers: book1.identifiers,
            comments: book1.comments,
            formats: [book2.formats[0]],
            cover: book1.cover,
            pages: book1.pages,
            sourceUUID: book1.sourceUUID,
            titleSort: book1.titleSort,
            authorSort: book1.authorSort,
            lastModified: book1.lastModified,
            sourcePath: book1.sourcePath,
            originalFormats: book1.originalFormats,
            conversionOptions: book1.conversionOptions,
            extraIdentifiers: book1.extraIdentifiers,
            customColumnDefinitions: book1.customColumnDefinitions,
            rawMetadata: book1.rawMetadata,
            opfPath: book1.opfPath
        )

        let report = try await service.importBooks(
            [twin, book1], from: library.path,
            libraryID: "acceptance-fixture-uuid",
            selection: [book1.calibreID, twin.calibreID],
            into: repository
        )

        #expect(report.imported.map(\.calibreID) == [1, 101])
        let twinItem = try #require(report.imported.first { $0.calibreID == 101 })
        let firstItem = try #require(report.imported.first { $0.calibreID == 1 })
        guard case .imported(let firstBookID) = firstItem.status else {
            Issue.record("expected .imported status, got \(firstItem.status)")
            return
        }
        #expect(twinItem.likelyDuplicateOf == firstBookID)
    }

    @Test
    func importPreservesRawPayloadEndToEnd() async throws {
        let layout = try layout()
        let service = CalibreImportService(layout: layout)
        let repository = CalibreMemoryRepository()
        let library = try CalibreFixture.makeVariantLibrary(
            named: "svc-v27-\(UUID().uuidString)", userVersion: 27, extraColumns: false
        )
        let reader = try CalibreReader.open(libraryURL: library)
        let records = try reader.books()
        try reader.close()

        let report = try await service.importBooks(
            records, from: library.path,
            libraryID: "acceptance-fixture-uuid",
            selection: [1], into: repository
        )
        #expect(report.imported.count == 1)

        let created = try #require(await repository.createdBooks().first)
        let raw = created.metadata.rawMetadata ?? [:]
        #expect(raw["calibre.uuid"] == "uuid-1")
        #expect(raw["calibre.titleSort"] == "Range: Why Generalists Triumph in a Specialized World")
        #expect(raw["calibre.authorSort"] == "Epstein, David")
        #expect(raw["calibre.sourcePath"] == "David Epstein/Range (1)")
        #expect(raw["calibre.pages"] == "320")
        #expect(raw["calibre.conversionOptions"] != nil)
        #expect(raw["calibre.originalFormats"] != nil)
        #expect(raw["calibre.customColumns"] != nil)
        #expect(raw["calibre.custom.genre"] == "science")
        #expect(raw["calibre.custom.shelves"] != nil)
    }
}

private struct CapturedCreate {
    let metadata: NewBookMetadata
    let stagedCount: Int
    let cover: Data?
}

/// Repository double mirroring the Slice 2 `MemoryRepository` (which is
/// file-private to `ImportServiceTests.swift`), extended for Calibre import:
/// seeded hashes (duplicate detection), per-title failure injection (resume),
/// and created-book capture.
private actor CalibreMemoryRepository: LibraryRepositoryImporting {
    private var hashes: [String: UUID]
    private var books: [IndexedBook]
    private let failOnTitle: String?
    private var created: [CapturedCreate] = []
    private var duplicateCheckCalls = 0

    init(
        seededHashes: [String: UUID] = [:],
        seededBooks: [IndexedBook] = [],
        failOnTitle: String? = nil
    ) {
        hashes = seededHashes
        books = seededBooks
        self.failOnTitle = failOnTitle
    }

    func bookIDs(byFormatHash contentHash: String) async throws -> [UUID] {
        hashes[contentHash].map { [$0] } ?? []
    }

    func allBooksForDuplicateCheck() async throws -> [IndexedBook] {
        duplicateCheckCalls += 1
        return books
    }

    func createBook(
        metadata: NewBookMetadata,
        staged: [BookFolder.StagedFile],
        cover: Data?
    ) async throws -> IndexedBook {
        if let failOnTitle, metadata.title == failOnTitle {
            throw TestInjectedError.injectedFailure
        }
        let id = UUID()
        for file in staged {
            hashes[file.contentHash] = id
        }
        let book = IndexedBook(
            id: id, title: metadata.title, authors: metadata.authors,
            modifiedMilliseconds: 1, isDeleted: false, snapshot: Data()
        )
        books.append(book)
        created.append(CapturedCreate(metadata: metadata, stagedCount: staged.count, cover: cover))
        return book
    }

    func createdBooks() -> [CapturedCreate] { created }

    func duplicateCheckCallCount() -> Int { duplicateCheckCalls }
}

/// Minimal thread-safe accumulator for progress/phase callbacks. The import
/// service invokes progress closures synchronously on its own executor, so a
/// plain locked box is deterministic: every append completes before
/// `importBooks` returns.
private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ element: Value.Element) where Value: RangeReplaceableCollection {
        lock.lock()
        storage.append(element)
        lock.unlock()
    }
}

private enum TestInjectedError: Error {
    case injectedFailure
}
