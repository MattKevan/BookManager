import Foundation
import Testing
@testable import StacksCore

@Suite
struct LibraryBookmarkStoreTests {
    @Test
    func storesAndResolvesBookmarkByLibraryID() throws {
        let suite = "StacksTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = LibraryBookmarkStore(defaults: defaults)
        let libraryID = UUID()
        let folder = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        try store.save(folder, for: libraryID)
        let resolved = try store.resolve(libraryID)

        #expect(resolved.url.standardizedFileURL == folder.standardizedFileURL)
    }

    @Test
    func mostRecentlyOpenedLibraryWins() throws {
        let suite = "StacksTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = LibraryBookmarkStore(defaults: defaults)
        let folderA = try makeTempFolder()
        let folderB = try makeTempFolder()
        let idA = UUID()
        let idB = UUID()

        try store.save(folderA, for: idA, at: Date(timeIntervalSinceReferenceDate: 1_000))
        try store.save(folderB, for: idB, at: Date(timeIntervalSinceReferenceDate: 2_000))
        #expect(store.mostRecentlyOpenedLibraryID() == idB)

        // Re-opening A makes it the most recent.
        try store.save(folderA, for: idA, at: Date(timeIntervalSinceReferenceDate: 3_000))
        #expect(store.mostRecentlyOpenedLibraryID() == idA)
    }

    @Test
    func recentLibrariesAreOrderedNewestFirst() throws {
        let suite = "StacksTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = LibraryBookmarkStore(defaults: defaults)
        let folderA = try makeTempFolder()
        let folderB = try makeTempFolder()
        let folderC = try makeTempFolder()
        let idA = UUID()
        let idB = UUID()
        let idC = UUID()

        try store.save(folderA, for: idA, at: Date(timeIntervalSinceReferenceDate: 1_000))
        try store.save(folderB, for: idB, at: Date(timeIntervalSinceReferenceDate: 3_000))
        try store.save(folderC, for: idC, at: Date(timeIntervalSinceReferenceDate: 2_000))

        #expect(store.recentLibraries().map(\.id) == [idB, idC, idA])
    }

    @Test
    func noBookmarksYieldsNoMostRecent() {
        let suite = "StacksTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = LibraryBookmarkStore(defaults: defaults)

        #expect(store.mostRecentlyOpenedLibraryID() == nil)
        #expect(store.recentLibraries().isEmpty)
    }

    private func makeTempFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

}
