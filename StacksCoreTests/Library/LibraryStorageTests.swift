import Foundation
import Testing
@testable import StacksCore

@Suite
struct LibraryStorageTests {
    @Test
    func createsPortableControlDirectoriesAndManifest() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let layout = LibraryLayout(root: root)
        let manifest = LibraryManifest(id: UUID(), createdAt: Date(timeIntervalSince1970: 1))

        try layout.create(manifest: manifest)

        #expect(FileManager.default.fileExists(atPath: layout.manifestURL.path))
        #expect(try layout.readManifest() == manifest)
        #expect(FileManager.default.fileExists(atPath: layout.bookChangesRoot.path))
        #expect(FileManager.default.fileExists(atPath: layout.libraryChangesRoot.path))
    }

    @Test
    func canonicalPathIncludesHumanNamesAndStableShortID() {
        let id = UUID(uuidString: "12345678-0000-0000-0000-000000000000")!
        let relative = CanonicalPathBuilder.relativeDirectory(
            bookID: id,
            title: "Range: Why Generalists Triumph?",
            authors: ["David Epstein"]
        )

        #expect(relative == "David Epstein/Range_ Why Generalists Triumph_ (12345678)")
    }

    @Test
    func changeStoreWritesOnceAndEnumeratesByBook() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let layout = LibraryLayout(root: root)
        try layout.create(manifest: LibraryManifest(id: UUID()))
        let store = ChangeStore(layout: layout)
        let bookID = UUID()
        let deviceID = UUID()
        let clock = HybridLogicalClock(physicalMilliseconds: 1_000, nodeID: deviceID)
        let data = Data("encoded-change".utf8)

        let first = try await store.writeBookChange(
            data,
            bookID: bookID,
            deviceID: deviceID,
            clock: clock
        )
        let second = try await store.writeBookChange(
            data,
            bookID: bookID,
            deviceID: deviceID,
            clock: clock
        )

        #expect(first.url == second.url)
        #expect(first.created)
        #expect(!second.created)
        #expect(try await store.bookChanges(bookID: bookID) == [data])
    }
}
