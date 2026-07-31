import Foundation
import Testing
@testable import BookManagerCore

@Suite
struct LibraryBookmarkStoreTests {
    @Test
    func storesAndResolvesBookmarkByLibraryID() throws {
        let suite = "BookManagerTests.\(UUID().uuidString)"
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
}
