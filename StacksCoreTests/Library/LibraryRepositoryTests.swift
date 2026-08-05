import Foundation
import Testing
@testable import StacksCore

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
    /// Creating over a folder that is already a library must not clobber its
    /// manifest (Settings > Create New / Cmd+Shift+N over an existing
    /// Book Manager library would otherwise fork it with a fresh id).
    @Test
    func rejectsCreatingOverExistingLibrary() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let indexes = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)

        _ = try await LibraryRepository.create(at: root, indexesDirectory: indexes, deviceID: UUID())

        await #expect(throws: LibraryRepositoryError.libraryAlreadyExists) {
            try await LibraryRepository.create(at: root, indexesDirectory: indexes, deviceID: UUID())
        }
    }
}

@Suite
struct LibraryRepositoryV2Tests {
    private func makeRepository() async throws -> LibraryRepository {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let indexes = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        return try await LibraryRepository.create(
            at: root,
            indexesDirectory: indexes,
            deviceID: UUID()
        )
    }

    @Test
    func createsBookWithFormatsCoverAndMetadata() async throws {
        let repository = try await makeRepository()
        let source = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).epub")
        try Data("imported-epub".utf8).write(to: source)
        let staged = try await repository.stageFile(from: source)
        let cover = try Fixtures.jpeg1x1()

        let book = try await repository.createBook(
            metadata: NewBookMetadata(
                title: "Range",
                authors: ["David Epstein"],
                series: "Studies",
                seriesIndex: 1.5,
                tags: ["science", "sport"],
                rating: 4,
                publisher: "Riverhead",
                publicationDate: Date(timeIntervalSince1970: 1_000),
                languages: ["eng"],
                identifiers: ["isbn": "978-0-7352-2129-1"],
                comments: "A great book"
            ),
            staged: [staged],
            cover: cover
        )

        #expect(book.title == "Range")
        #expect(book.tags.sorted() == ["science", "sport"])
        #expect(book.series == "Studies")
        #expect(book.formats.first?.kind == "EPUB")
        #expect(book.coverHash != nil)
        #expect(book.relativePath == "David Epstein/Range (\(String(book.id.uuidString.prefix(8)).lowercased()))")
        #expect(try await repository.books().count == 1)
    }

    @Test
    func updateBookEditsMetadataAndRenamesFolder() async throws {
        let repository = try await makeRepository()
        let book = try await repository.createBook(
            metadata: NewBookMetadata(title: "Range", authors: ["David Epstein"]),
            staged: [],
            cover: nil
        )

        let updated = try await repository.updateBook(
            id: book.id,
            edit: BookEdit(title: "Range: Revised", tags: ["science"])
        )

        #expect(updated.title == "Range: Revised")
        #expect(updated.tags == ["science"])
        #expect(updated.relativePath.contains("Range_ Revised"))
        #expect(try await repository.books().first?.title == "Range: Revised")
        #expect(try await repository.facetCounts(.tag).first?.value == "science")
    }

    @Test
    func deleteAndRestoreRoundTripThroughTrash() async throws {
        let repository = try await makeRepository()
        let source = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).pdf")
        try Data("some-pdf".utf8).write(to: source)
        let book = try await repository.createBook(
            metadata: NewBookMetadata(title: "Range", authors: ["David Epstein"]),
            staged: [try await repository.stageFile(from: source)],
            cover: nil
        )

        try await repository.deleteBook(id: book.id)
        #expect(try await repository.books().isEmpty)
        #expect(try await repository.deletedBooks().map(\.id) == [book.id])
        #expect(try await repository.bookFolderURL(id: book.id) == nil)

        let restored = try await repository.restoreBook(id: book.id)
        #expect(restored.title == "Range")
        #expect(try await repository.books().map(\.id) == [book.id])
        #expect(try await repository.bookFolderURL(id: book.id) != nil)
    }

    @Test
    func missingFormatFilesAreReported() async throws {
        let repository = try await makeRepository()
        let source = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).epub")
        try Data("x".utf8).write(to: source)
        let book = try await repository.createBook(
            metadata: NewBookMetadata(title: "Range", authors: ["David Epstein"]),
            staged: [try await repository.stageFile(from: source)],
            cover: nil
        )
        // Remove the format file behind the repository's back.
        let folderURL = try await repository.bookFolderURL(id: book.id)!
        try FileManager.default.removeItem(at: folderURL.appending(path: book.formats[0].filename))

        let missing = try await repository.missingFormatFiles()
        #expect(missing.count == 1)
        #expect(missing[0].filename == book.formats[0].filename)
    }

    @Test
    func rebuildMaterializesFullMetadataAndFacets() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let firstIndexes = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let secondIndexes = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let repository = try await LibraryRepository.create(at: root, indexesDirectory: firstIndexes, deviceID: UUID())
        _ = try await repository.createBook(
            metadata: NewBookMetadata(title: "Range", authors: ["David Epstein"], series: "Studies", tags: ["science"]),
            staged: [],
            cover: nil
        )

        let rebuilt = try await LibraryRepository.open(at: root, indexesDirectory: secondIndexes, deviceID: UUID())

        let books = try await rebuilt.books()
        #expect(books.count == 1)
        #expect(books[0].series == "Studies")
        #expect(books[0].tags == ["science"])
        #expect(try await rebuilt.facetCounts(.series).first?.value == "Studies")
    }

    @Test
    func updateAndDeleteSurviveCatalogRebuild() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let firstIndexes = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let secondIndexes = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let repository = try await LibraryRepository.create(at: root, indexesDirectory: firstIndexes, deviceID: UUID())
        let book = try await repository.createBook(
            metadata: NewBookMetadata(title: "Range", authors: ["David Epstein"], tags: ["science"]),
            staged: [], cover: nil
        )
        _ = try await repository.updateBook(id: book.id, edit: BookEdit(title: "Range: Revised", tags: ["science", "sport"]))

        // Rebuild from the change store into a fresh catalogue.
        let rebuilt = try await LibraryRepository.open(at: root, indexesDirectory: secondIndexes, deviceID: UUID())
        let updated = try await rebuilt.books().first
        #expect(updated?.title == "Range: Revised")
        #expect(updated?.tags == ["science", "sport"])

        // Delete, then rebuild again — the tombstone must survive too.
        try await rebuilt.deleteBook(id: book.id)
        let thirdIndexes = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let rebuiltAgain = try await LibraryRepository.open(at: root, indexesDirectory: thirdIndexes, deviceID: UUID())
        #expect(try await rebuiltAgain.books().isEmpty)
        #expect(try await rebuiltAgain.deletedBooks().map(\.id) == [book.id])
    }
}
