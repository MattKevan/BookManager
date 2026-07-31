import BookManagerCore
import Foundation
import Observation

@MainActor
@Observable
final class LibrarySession {
    enum State {
        case welcome
        case loading
        case loaded(name: String, books: [IndexedBook])
        case failed(message: String)
    }

    private(set) var state: State = .welcome
    private(set) var repository: LibraryRepository?
    var searchText = "" {
        didSet { Task { await refresh() } }
    }

    private let deviceID: UUID
    private let bookmarks: LibraryBookmarkStore
    private var activeSecurityURL: URL?

    init(
        deviceID: UUID = UUID(),
        bookmarks: LibraryBookmarkStore = LibraryBookmarkStore()
    ) {
        self.deviceID = deviceID
        self.bookmarks = bookmarks
    }

    func createLibrary(at url: URL) async {
        await activate(url: url, create: true)
    }

    func openLibrary(at url: URL) async {
        await activate(url: url, create: false)
    }

    func closeLibrary() {
        activeSecurityURL?.stopAccessingSecurityScopedResource()
        activeSecurityURL = nil
        repository = nil
        state = .welcome
    }

    func refresh() async {
        guard let repository else { return }
        do {
            let books = searchText.isEmpty
                ? try await repository.books()
                : try await repository.search(searchText)
            state = .loaded(name: repository.root.lastPathComponent, books: books)
        } catch {
            state = .failed(message: error.localizedDescription)
        }
    }

    private func activate(url: URL, create: Bool) async {
        state = .loading
        let accessed = url.startAccessingSecurityScopedResource()

        do {
            let indexes = try Self.indexDirectory()
            let repository: LibraryRepository
            if create {
                repository = try await .create(
                    at: url,
                    indexesDirectory: indexes,
                    deviceID: deviceID
                )
            } else {
                repository = try await .open(
                    at: url,
                    indexesDirectory: indexes,
                    deviceID: deviceID
                )
            }
            try bookmarks.save(url, for: repository.manifest.id)
            activeSecurityURL?.stopAccessingSecurityScopedResource()
            activeSecurityURL = accessed ? url : nil
            self.repository = repository
            await refresh()
        } catch {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
            state = .failed(message: error.localizedDescription)
        }
    }

    private static func indexDirectory() throws -> URL {
        let root = URL.applicationSupportDirectory
            .appending(path: "Book Manager", directoryHint: .isDirectory)
            .appending(path: "Indexes", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
