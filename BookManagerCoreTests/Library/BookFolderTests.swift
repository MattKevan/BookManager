import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import BookManagerCore

@Suite
struct BookFolderTests {
    private func makeLayout() throws -> (root: URL, layout: LibraryLayout) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let layout = LibraryLayout(root: root)
        try layout.create(manifest: LibraryManifest(id: UUID()))
        return (root, layout)
    }

    @Test
    func formatFileNameCombinesTitleAuthorAndKind() {
        let name = CanonicalPathBuilder.formatFileName(
            title: "Range: Why Generalists Triumph?",
            authors: ["David Epstein"],
            kind: "EPUB"
        )
        #expect(name == "Range_ Why Generalists Triumph_ - David Epstein.epub")
    }

    @Test
    func materializeCreatesCalibreStyleFolderWithFilesAndSidecars() async throws {
        let (root, layout) = try makeLayout()
        let folder = BookFolder(layout: layout)
        let bookID = UUID()
        let resolved = ResolvedBook(
            id: bookID,
            title: "Range",
            authors: ["David Epstein"],
            series: nil, seriesIndex: nil,
            tags: [], rating: nil, publisher: nil,
            publicationDate: nil, addedDate: nil,
            languages: [], identifiers: [:], comments: nil,
            formats: [], cover: nil,
            isDeleted: false,
            modifiedClock: HybridLogicalClock(physicalMilliseconds: 1, nodeID: UUID())
        )
        let source = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).epub")
        try Data("epub-bytes".utf8).write(to: source)

        let staged = try await folder.stage(from: source)
        #expect(staged.kind == "EPUB")
        #expect(staged.contentHash == "bd93fefcffbd3707e18d27bd9faca7b7")
        #expect(staged.size == 10)

        let result = try await folder.materialize(
            bookID: bookID,
            resolved: resolved,
            staged: [staged],
            cover: nil
        )

        #expect(result.path == "David Epstein/Range (\(String(bookID.uuidString.prefix(8)).lowercased()))")
        let dir = await folder.bookDirectoryURL(relativePath: result.path)
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "Range - David Epstein.epub").path))
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "metadata.opf").path))
        #expect(result.formats.count == 1)
        #expect(result.formats[0].filename == "Range - David Epstein.epub")
        #expect(!FileManager.default.fileExists(atPath: staged.url.path))
    }

    @Test
    func materializeWritesCoverAndOpf() async throws {
        let (root, layout) = try makeLayout()
        let folder = BookFolder(layout: layout)
        let bookID = UUID()
        let resolved = ResolvedBook(
            id: bookID, title: "Range", authors: ["David Epstein"],
            series: "Studies", seriesIndex: 1, tags: ["science"], rating: 4,
            publisher: "Riverhead", publicationDate: Date(timeIntervalSince1970: 1_000),
            addedDate: Date(timeIntervalSince1970: 2_000), languages: ["eng"],
            identifiers: ["isbn": "123"], comments: "A book.",
            formats: [], cover: nil, isDeleted: false,
            modifiedClock: HybridLogicalClock(physicalMilliseconds: 1, nodeID: UUID())
        )
        let coverBytes = try Self.jpegFixture()

        let result = try await folder.materialize(
            bookID: bookID, resolved: resolved, staged: [], cover: coverBytes
        )

        let dir = await folder.bookDirectoryURL(relativePath: result.path)
        let coverURL = dir.appending(path: "cover.jpg")
        #expect(FileManager.default.fileExists(atPath: coverURL.path))
        let opf = try String(contentsOf: dir.appending(path: "metadata.opf"), encoding: .utf8)
        #expect(opf.contains("<dc:title>Range</dc:title>"))
        #expect(opf.contains("<dc:creator opf:role=\"aut\">David Epstein</dc:creator>"))
        #expect(opf.contains("Studies"))
    }

    @Test
    func renameMovesFolderAndSidecars() async throws {
        let (root, layout) = try makeLayout()
        let folder = BookFolder(layout: layout)
        let bookID = UUID()
        let resolved = ResolvedBook(
            id: bookID, title: "Range", authors: ["David Epstein"],
            series: nil, seriesIndex: nil, tags: [], rating: nil, publisher: nil,
            publicationDate: nil, addedDate: nil, languages: [], identifiers: [:],
            comments: nil, formats: [], cover: nil, isDeleted: false,
            modifiedClock: HybridLogicalClock(physicalMilliseconds: 1, nodeID: UUID())
        )
        let old = try await folder.materialize(bookID: bookID, resolved: resolved, staged: [], cover: nil)

        let edited = ResolvedBook(
            id: bookID, title: "Range: Revised", authors: ["David Epstein"],
            series: nil, seriesIndex: nil, tags: [], rating: nil, publisher: nil,
            publicationDate: nil, addedDate: nil, languages: [], identifiers: [:],
            comments: nil, formats: [], cover: nil, isDeleted: false,
            modifiedClock: HybridLogicalClock(physicalMilliseconds: 2, nodeID: UUID())
        )
        let newPath = CanonicalPathBuilder.relativeDirectory(
            bookID: bookID, title: "Range: Revised", authors: ["David Epstein"]
        )
        try await folder.rename(bookID: bookID, from: old.path, to: newPath, oldFormats: [], newFormats: [])

        let oldDir = await folder.bookDirectoryURL(relativePath: old.path)
        let newDir = await folder.bookDirectoryURL(relativePath: newPath)
        #expect(!FileManager.default.fileExists(atPath: oldDir.path))
        #expect(FileManager.default.fileExists(atPath: newDir.appending(path: "metadata.opf").path))
        #expect(layout.transactionsRoot.children.isEmpty)
    }

    @Test
    func trashAndRestoreRoundTrip() async throws {
        let (root, layout) = try makeLayout()
        let folder = BookFolder(layout: layout)
        let bookID = UUID()
        let resolved = ResolvedBook(
            id: bookID, title: "Range", authors: ["David Epstein"],
            series: nil, seriesIndex: nil, tags: [], rating: nil, publisher: nil,
            publicationDate: nil, addedDate: nil, languages: [], identifiers: [:],
            comments: nil, formats: [], cover: nil, isDeleted: false,
            modifiedClock: HybridLogicalClock(physicalMilliseconds: 1, nodeID: UUID())
        )
        let materialized = try await folder.materialize(bookID: bookID, resolved: resolved, staged: [], cover: nil)

        try await folder.trash(bookID: bookID, relativePath: materialized.path)
        let trashedDir = await folder.bookDirectoryURL(relativePath: materialized.path)
        #expect(!FileManager.default.fileExists(atPath: trashedDir.path))

        let restored = try await folder.restore(bookID: bookID, relativePath: materialized.path)
        #expect(restored == materialized.path)
        let restoredDir = await folder.bookDirectoryURL(relativePath: restored)
        #expect(FileManager.default.fileExists(atPath: restoredDir.path))
        #expect(layout.transactionsRoot.children.isEmpty)
    }

    private static func jpegFixture() throws -> Data {
        // 1x1 red JPEG produced via ImageIO.
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        let image = context.makeImage()!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            data, "public.jpeg" as CFString, 1, nil
        )!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}

private extension URL {
    var children: [URL] {
        (try? FileManager.default.contentsOfDirectory(at: self, includingPropertiesForKeys: nil)) ?? []
    }
}
