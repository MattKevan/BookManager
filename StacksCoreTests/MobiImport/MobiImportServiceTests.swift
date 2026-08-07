import Foundation
import Testing
@testable import StacksCore

@Suite
struct MobiImportServiceTests {
    private final class FixtureMarker {}

    private func fixtureURL() throws -> URL {
        let bundle = Bundle(for: FixtureMarker.self)
        return try #require(bundle.url(forResource: "fixture", withExtension: "mobi"))
    }

    private func layout() throws -> LibraryLayout {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let layout = LibraryLayout(root: root)
        try layout.create(manifest: LibraryManifest(id: UUID()))
        return layout
    }

    @Test
    func importsMobiAsEpub() async throws {
        let service = ImportService(layout: try layout())
        let repository = MobiMemoryRepository()
        let mobiURL = try fixtureURL()

        let report = try await service.importFiles([mobiURL], into: repository)

        #expect(report.imported.count == 1)
        #expect(report.failed.isEmpty)
        // The converted format is EPUB.
        #expect(report.imported[0].kind == .epub)
        // The report keeps the original MOBI source label.
        #expect(report.imported[0].sourceURL.lastPathComponent == "fixture.mobi")

        let created = await repository.createdBooks()
        #expect(created.count == 1)
        // The staged file is the converted EPUB.
        #expect(created[0].stagedKinds == ["EPUB"])
        // The fixture carries no title metadata; the filename fallback applies.
        #expect(!created[0].book.title.isEmpty)
        #expect(created[0].book.title == "fixture")
    }

    @Test
    func reimportingTheSameMobiIsDetectedAsDuplicate() async throws {
        let service = ImportService(layout: try layout())
        let repository = MobiMemoryRepository()
        let mobiURL = try fixtureURL()

        _ = try await service.importFiles([mobiURL], into: repository)
        let second = try await service.importFiles([mobiURL], into: repository)

        // The converter is deterministic, so the same MOBI yields the same
        // EPUB bytes and content hash: the second import is a duplicate.
        #expect(second.duplicates.count == 1)
        #expect(second.imported.isEmpty)
    }

    @Test
    func stagingIsCleanedAfterMobiImport() async throws {
        let layout = try layout()
        let service = ImportService(layout: layout)
        let repository = MobiMemoryRepository()

        _ = try await service.importFiles([try fixtureURL()], into: repository)

        let staging = layout.controlRoot.appending(path: "staging", directoryHint: .isDirectory)
        let leftovers = (try? FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? []
        #expect(leftovers.isEmpty)
    }
}

/// Repository double mirroring `ImportServiceTests.MemoryRepository`, extended
/// to capture the staged file kinds so the test can assert the converted
/// format is EPUB.
private actor MobiMemoryRepository: LibraryRepositoryImporting {
    private var hashes: [String: UUID] = [:]
    private var created: [(book: IndexedBook, stagedKinds: [String])] = []

    func bookIDs(byFormatHash contentHash: String) async throws -> [UUID] {
        hashes[contentHash].map { [$0] } ?? []
    }

    func allBooksForDuplicateCheck() async throws -> [IndexedBook] {
        created.map(\.book)
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
        created.append((book, staged.map(\.kind)))
        return book
    }

    func createdBooks() -> [(book: IndexedBook, stagedKinds: [String])] { created }
}
