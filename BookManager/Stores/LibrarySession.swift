import AppKit
import BookManagerCore
import Foundation
import Observation

@MainActor
@Observable
final class LibrarySession {
    enum ViewMode: String, CaseIterable, Identifiable {
        case table, grid
        var id: String { rawValue }
    }

    enum State {
        case welcome
        case loading
        case loaded
        case failed(message: String)
    }

    private(set) var state: State = .welcome
    private(set) var repository: LibraryRepository?
    var searchText = "" {
        didSet {
            searchTask?.cancel()
            searchTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                await refreshBooks()
            }
        }
    }
    var lastError: String?
    var viewMode: ViewMode = .table
    var selection = Set<UUID>()
    var selectedFacet: FacetSelection?

    private(set) var books: [IndexedBook] = []
    private(set) var authors: [(value: String, count: Int)] = []
    private(set) var series: [(value: String, count: Int)] = []
    private(set) var tags: [(value: String, count: Int)] = []
    private(set) var formats: [(value: String, count: Int)] = []
    private(set) var deletedBooks: [IndexedBook] = []
    private(set) var missingFiles: [(book: IndexedBook, filename: String)] = []
    var importReport: ImportReport?
    var inspectorBook: IndexedBook?
    var diagnosticsPresented = false

    // Calibre import wizard state
    private(set) var calibreSummary: CalibreLibrarySummary?
    private(set) var calibreBooks: [CalibreBookRecord] = []
    var calibreSelectedIDs = Set<Int>()
    private(set) var calibreImportReport: CalibreImportReport?
    var calibreImportInProgress = false
    private(set) var calibreSourcePath: String?

    private let deviceID: UUID
    private let bookmarks: LibraryBookmarkStore
    private var activeSecurityURL: URL?
    private var searchTask: Task<Void, Never>?

    struct FacetSelection: Hashable {
        let type: FacetType
        let value: String
    }

    init(
        deviceID: UUID = UUID(),
        bookmarks: LibraryBookmarkStore = LibraryBookmarkStore()
    ) {
        self.deviceID = deviceID
        self.bookmarks = bookmarks
    }

    func createLibrary(at url: URL) async { await activate(url: url, create: true) }
    func openLibrary(at url: URL) async { await activate(url: url, create: false) }

    func closeLibrary() {
        searchTask?.cancel()
        searchTask = nil
        activeSecurityURL?.stopAccessingSecurityScopedResource()
        activeSecurityURL = nil
        repository = nil
        state = .welcome
        books = []
        deletedBooks = []
        selection = []
        selectedFacet = nil
        searchText = ""
        missingFiles = []
        viewMode = .table
        importReport = nil
        inspectorBook = nil
        lastError = nil
        calibreSummary = nil
        calibreBooks = []
        calibreSelectedIDs = []
        calibreImportReport = nil
        calibreImportInProgress = false
        calibreSourcePath = nil
    }

    // MARK: - Activation

    private func activate(url: URL, create: Bool) async {
        state = .loading
        let accessed = url.startAccessingSecurityScopedResource()
        do {
            let indexes = try Self.indexDirectory()
            let repository: LibraryRepository
            if create {
                repository = try await .create(at: url, indexesDirectory: indexes, deviceID: deviceID)
            } else {
                repository = try await .open(at: url, indexesDirectory: indexes, deviceID: deviceID)
            }
            try bookmarks.save(url, for: repository.manifest.id)
            activeSecurityURL?.stopAccessingSecurityScopedResource()
            activeSecurityURL = accessed ? url : nil
            self.repository = repository
            state = .loaded
            await refreshAll()
        } catch {
            if accessed { url.stopAccessingSecurityScopedResource() }
            state = .failed(message: error.localizedDescription)
        }
    }

    // MARK: - Loading

    func refreshAll() async {
        await refreshBooks()
        await refreshFacets()
        await refreshDeleted()
    }

    func refreshBooks() async {
        guard let repository else { return }
        do {
            if let facet = selectedFacet {
                books = try await repository.books(facetType: facet.type, value: facet.value)
            } else if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                books = try await repository.books()
            } else {
                // A malformed FTS5 query (unclosed quote, stray operator) must not
                // take down the loaded browser: on a search error, show no results
                // while keeping the library state intact.
                do {
                    books = try await repository.search(searchText)
                } catch {
                    books = []
                }
            }
        } catch {
            state = .failed(message: error.localizedDescription)
        }
    }

    func refreshFacets() async {
        guard let repository else { return }
        authors = (try? await repository.facetCounts(.author)) ?? []
        series = (try? await repository.facetCounts(.series)) ?? []
        tags = (try? await repository.facetCounts(.tag)) ?? []
        formats = (try? await repository.facetCounts(.format)) ?? []
    }

    func refreshDeleted() async {
        deletedBooks = (try? await repository?.deletedBooks()) ?? []
    }

    // MARK: - Facets and search

    func selectFacet(_ facet: FacetSelection?) {
        selectedFacet = (facet == selectedFacet) ? nil : facet
        Task { await refreshBooks() }
    }

    // MARK: - Import

    func importFiles(urls: [URL]) async {
        guard let repository else { return }
        let service = ImportService(layout: .init(root: repository.root))
        do {
            importReport = try await service.importFiles(urls, into: repository)
        } catch {
            importReport = ImportReport(items: [
                ImportItem(sourceURL: urls.first ?? URL(fileURLWithPath: "/"), kind: .epub, status: .failed(error.localizedDescription))
            ])
        }
        await refreshAll()
    }

    // MARK: - Calibre import

    func selectCalibreLibrary(at url: URL) async {
        let reader: CalibreReader
        do {
            reader = try CalibreReader.open(libraryURL: url)
        } catch {
            lastError = error.localizedDescription
            calibreSummary = nil
            calibreBooks = []
            calibreSourcePath = nil
            return
        }
        defer { try? reader.close() }
        do {
            let summary = try reader.summary()
            let books = try reader.books()
            calibreSummary = summary
            calibreBooks = books
            calibreSelectedIDs = Set(books.map(\.calibreID))
            calibreImportReport = nil
            calibreSourcePath = url.standardizedFileURL.path
        } catch {
            lastError = error.localizedDescription
            calibreSummary = nil
            calibreBooks = []
            calibreSourcePath = nil
        }
    }

    func importCalibre() async {
        guard let repository, let summary = calibreSummary,
              let sourcePath = calibreSourcePath else { return }
        calibreImportInProgress = true
        defer { calibreImportInProgress = false }
        let service = CalibreImportService(layout: .init(root: repository.root))
        do {
            calibreImportReport = try await service.importBooks(
                calibreBooks,
                from: sourcePath,
                libraryID: summary.libraryID,
                selection: Array(calibreSelectedIDs),
                into: repository
            )
        } catch {
            lastError = error.localizedDescription
        }
        await refreshAll()
    }

    // MARK: - Editing

    func saveEdit(_ edit: BookEdit, for id: UUID) async {
        guard let repository else { return }
        do {
            let updated = try await repository.updateBook(id: id, edit: edit)
            inspectorBook = updated
            await refreshAll()
        } catch {
            state = .failed(message: error.localizedDescription)
        }
    }

    // MARK: - Delete / restore

    func delete(ids: Set<UUID>) async {
        guard let repository else { return }
        for id in ids {
            do {
                try await repository.deleteBook(id: id)
            } catch {
                lastError = error.localizedDescription
            }
        }
        selection.removeAll()
        await refreshAll()
    }

    func restore(id: UUID) async {
        guard let repository else { return }
        do {
            _ = try await repository.restoreBook(id: id)
        } catch {
            lastError = error.localizedDescription
        }
        await refreshAll()
    }

    // MARK: - Open / reveal

    func open(id: UUID) async {
        guard let repository else { return }
        do {
            guard let url = try await repository.formatFileURL(id: id) else { return }
            NSWorkspace.shared.open(url)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func reveal(id: UUID) async {
        guard let repository else { return }
        do {
            guard let url = try await repository.bookFolderURL(id: id) else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            lastError = error.localizedDescription
        }
    }

    var libraryRoot: URL? {
        repository?.root
    }

    // MARK: - Diagnostics

    func rebuildIndex() async {
        guard let repository else { return }
        do {
            try await repository.rebuildCatalog()
        } catch {
            lastError = error.localizedDescription
        }
        await refreshAll()
    }

    func reloadDiagnostics() async {
        guard let repository else { return }
        missingFiles = (try? await repository.missingFormatFiles()) ?? []
        await refreshDeleted()
    }

    private static func indexDirectory() throws -> URL {
        let root = URL.applicationSupportDirectory
            .appending(path: "Book Manager", directoryHint: .isDirectory)
            .appending(path: "Indexes", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
