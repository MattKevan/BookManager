import Foundation
import Testing
@testable import StacksCore

@Suite
struct OpenLibraryStoreTests {
    @Test
    func savesAndResolvesBookmark() throws {
        let suite = "StacksTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = OpenLibraryStore(defaults: defaults)
        let libraryID = UUID()
        let folder = try makeTempFolder()

        try store.save(folder, for: libraryID, name: "My Library")
        let resolved = try store.resolve(libraryID)

        #expect(resolved.url.standardizedFileURL == folder.standardizedFileURL)
        #expect(resolved.isStale == false)
    }

    @Test
    func resolveUnknownThrowsNotFound() {
        let suite = "StacksTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = OpenLibraryStore(defaults: defaults)

        #expect(throws: LibraryBookmarkError.self) {
            try store.resolve(UUID())
        }
    }

    @Test
    func orderPersistsAndReorders() throws {
        let suite = "StacksTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = OpenLibraryStore(defaults: defaults)
        let idA = UUID()
        let idB = UUID()
        try store.save(makeTempFolder(), for: idA, name: "A")
        try store.save(makeTempFolder(), for: idB, name: "B")

        store.setOrder([idA, idB])
        #expect(store.order() == [idA, idB])

        store.setOrder([idB, idA])
        #expect(store.order() == [idB, idA])
    }

    @Test
    func homeSetAndClear() {
        let suite = "StacksTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = OpenLibraryStore(defaults: defaults)
        let idA = UUID()

        #expect(store.home() == nil)
        store.setHome(idA)
        #expect(store.home() == idA)
        store.setHome(nil)
        #expect(store.home() == nil)
    }

    @Test
    func removeCleansBookmarkNameOrderAndHome() throws {
        let suite = "StacksTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = OpenLibraryStore(defaults: defaults)
        let idA = UUID()
        try store.save(makeTempFolder(), for: idA, name: "A")
        store.setOrder([idA])
        store.setHome(idA)

        store.remove(idA)

        #expect(throws: LibraryBookmarkError.self) { try store.resolve(idA) }
        #expect(store.order().isEmpty)
        #expect(store.home() == nil)
        #expect(store.names().isEmpty)
    }

    @Test
    func namesRoundtrip() throws {
        let suite = "StacksTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = OpenLibraryStore(defaults: defaults)
        let idA = UUID()
        try store.save(makeTempFolder(), for: idA, name: "NAS Books")

        #expect(store.names()[idA] == "NAS Books")
    }

    @Test
    func staleBookmarkIsFlagged() throws {
        let suite = "StacksTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = OpenLibraryStore(defaults: defaults)
        let libraryID = UUID()
        let folder = try makeTempFolder()
        try store.save(folder, for: libraryID, name: "Moved")

        // Move the folder so the bookmark no longer resolves to its original
        // location; the system flags the bookmark as stale.
        let moved = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: folder, to: moved)

        let resolved = try store.resolve(libraryID)
        #expect(resolved.isStale)
    }

    private func makeTempFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
