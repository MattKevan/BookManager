import AppKit
import Foundation
import Observation
import StacksCore

/// A connected remote library, browsed over the sync protocol. The grid,
/// table, and facet views are generic over `LibraryBrowser`, so a remote
/// behaves like a local library — except covers come from the server and
/// edits/opens go over the network. Read-only metadata editing of remote
/// books is a follow-up; browse, open, and delete are live.
@MainActor
@Observable
final class RemoteLibraryBrowser: LibraryBrowser {
    let id: UUID
    var name: String
    let remote: RemoteLibrary

    var repository: LibraryRepository? { nil }

    private var remoteBooks: [IndexedBook] = []
    var pendingDelete: Set<UUID>?
    var isLibraryUnavailable: Bool { false }
    var selection = Set<UUID>()
    var selectionAnchor: UUID?
    var isMarqueeSelecting = false
    var facetNavigation = FacetNavigation()
    var searchText = ""
    var viewMode: BrowserViewMode = .grid
    var metadataEditQueue: [IndexedBook]? = nil

    /// Commands waiting in the durable offline queue (badge in the Shared
    /// sidebar row).
    func pendingCount() async -> Int {
        await remote.pendingOfflineCount()
    }

    private var coverCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 512
        return cache
    }()

    init(discovered: DiscoveredLibrary, credential: RemoteLibrary.Credential?) throws {
        id = discovered.id
        name = discovered.name
        remote = try RemoteLibrary(configuration: .init(
            baseURL: discovered.baseURL,
            credential: credential,
            queueDirectory: Self.queueDirectory(libraryID: discovered.id)
        ))
    }

    /// The durable offline-queue location for this remote library.
    static func queueDirectory(libraryID: UUID) -> URL {
        URL.applicationSupportDirectory
            .appending(path: "Stacks", directoryHint: .isDirectory)
            .appending(path: "remote-queues", directoryHint: .isDirectory)
            .appending(path: libraryID.uuidString, directoryHint: .isDirectory)
    }

    // MARK: - LibraryBrowser

    var books: [IndexedBook] { remoteBooks }
    var selectionBooks: [IndexedBook] { books.filter { selection.contains($0.id) } }

    var authors: [(value: String, count: Int)] { facetCounts(.author) }
    var series: [(value: String, count: Int)] { facetCounts(.series) }
    var tags: [(value: String, count: Int)] { facetCounts(.tag) }
    var formats: [(value: String, count: Int)] { facetCounts(.format) }

    private func facetCounts(_ type: FacetType) -> [(value: String, count: Int)] {
        let live = remoteBooks.filter { !$0.isDeleted }
        var counts: [String: Int] = [:]
        switch type {
        case .author:
            for book in live { for author in book.authors { counts[author, default: 0] += 1 } }
        case .series:
            for book in live { if let series = book.series, !series.isEmpty { counts[series, default: 0] += 1 } }
        case .tag:
            for book in live { for tag in book.tags { counts[tag, default: 0] += 1 } }
        case .format:
            for book in live { for format in book.formats { counts[format.kind, default: 0] += 1 } }
        }
        return counts.map { (value: $0.key, count: $0.value) }
            .sorted { $0.value.localizedCaseInsensitiveCompare($1.value) == .orderedAscending }
    }

    func refreshBooks() async {
        try? await remote.pull()
        remoteBooks = await remote.books()
    }

    func open(id: UUID) async {
        guard let book = await remote.book(id: id),
              let format = book.formats.first else { return }
        do {
            let url = try await remote.downloadFormat(id: id, format: format.kind.lowercased())
            NSWorkspace.shared.open(url)
        } catch {
            // Surfaced via a session error in a follow-up; silently ignored v1.
        }
    }

    func reveal(id: UUID) async {
        await open(id: id)
    }

    func formatFileURL(for book: IndexedBook) -> URL? {
        nil // remote drag-out is a follow-up
    }

    func requestDelete(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        pendingDelete = ids
    }

    func delete(ids: Set<UUID>) async {
        for id in ids {
            _ = try? await remote.push(ClientCommand(id: UUID(), op: .deleteBook(.init(bookID: id))))
        }
        selection.removeAll()
        await refreshBooks()
    }

    func restore(id: UUID) async {
        _ = try? await remote.push(ClientCommand(id: UUID(), op: .restoreBook(.init(bookID: id))))
        await refreshBooks()
    }

    func clearGridSelection() {
        selection = []
        selectionAnchor = nil
    }

    func selectCategory(_ type: FacetType?) {
        facetNavigation.selectCategory(type)
        Task { await refreshBooks() }
    }

    func selectValue(_ value: String?) {
        facetNavigation.selectValue(value)
        Task { await refreshBooks() }
    }

    func selectInGrid(_ book: IndexedBook) {
        let flags = NSEvent.modifierFlags
        let modifier: GridSelectionModifier = flags.contains(.command)
            ? .command
            : (flags.contains(.shift) ? .shift : .none)
        let result = GridSelectionSemantics.applying(
            click: book.id,
            modifier: modifier,
            anchor: selectionAnchor,
            visible: books.map(\.id),
            selection: selection
        )
        selection = result.selection
        if let anchor = result.anchor {
            selectionAnchor = anchor
        }
    }

    func coverImage(for book: IndexedBook) async -> NSImage? {
        if let cached = coverCache.object(forKey: book.id.uuidString as NSString) {
            return cached
        }
        guard book.coverHash != nil,
              let data = try? await remote.downloadCover(id: book.id),
              let image = NSImage(data: data) else {
            return nil
        }
        coverCache.setObject(image, forKey: book.id.uuidString as NSString)
        return image
    }
}
