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
final class RemoteLibraryBrowser: LibraryBrowser, Identifiable {
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
    var sortOrder: BrowserSortOrder = .name
    var metadataEditQueue: [IndexedBook]? = nil

    /// Commands waiting in the durable offline queue (badge in the Shared
    /// sidebar row).
    func pendingCount() async -> Int {
        await remote.pendingOfflineCount()
    }

    /// Uploads book files to the server: metadata is extracted from each
    /// file (title/authors/series/tags/…), the bytes staged, and an addBook
    /// command pushed — the server materializes the book. Unreachable pushes
    /// queue durably and land on reconnect.
    func importFiles(
        urls: [URL],
        progress: @escaping (Int, Int, String?) -> Void = { _, _, _ in },
        onFailure: @escaping (String) -> Void = { _ in }
    ) async {
        let total = urls.count
        var completed = 0
        for url in urls {
            guard let kind = MetadataExtractor.kind(for: url),
                  let data = try? Data(contentsOf: url) else { continue }
            let extracted = try? MetadataExtractor.extract(from: url, kind: kind)
            let title = extracted?.title ?? url.deletingPathExtension().lastPathComponent
            let filename = url.lastPathComponent
            let staged = JournalCommand.StagedFormat(
                kind: kind.rawValue,
                filename: filename,
                contentHash: BookFolder.contentHash(data),
                size: Int64(data.count),
                stagedName: filename
            )
            // The embedded cover rides along (staged like the format), so
            // uploaded books show a real cover instead of the placeholder.
            var stagedFiles = [filename: data]
            var cover: JournalCommand.StagedCover?
            if let coverData = try? MetadataExtractor.extractCover(from: url, kind: kind) {
                let coverName = "cover.jpg"
                cover = JournalCommand.StagedCover(
                    filename: coverName,
                    contentHash: BookFolder.contentHash(coverData),
                    stagedName: coverName
                )
                stagedFiles[coverName] = coverData
            }
            let addBook = JournalCommand.AddBook(
                bookID: UUID(),
                title: title,
                authors: extracted?.authors ?? [],
                series: extracted?.series,
                seriesIndex: extracted?.seriesIndex,
                tags: extracted?.tags ?? [],
                rating: nil,
                publisher: extracted?.publisher,
                publicationDate: extracted?.publicationDate,
                addedDate: .now,
                languages: extracted?.languages ?? [],
                identifiers: extracted?.identifiers ?? [:],
                comments: extracted?.comments,
                formats: [staged],
                cover: cover
            )
            progress(completed, total, title)
            let outcome = try? await remote.push(
                ClientCommand(id: UUID(), op: .addBook(addBook)),
                stagedFiles: stagedFiles
            )
            switch outcome {
            case .applied, .queued:
                // Applied now, or durably queued for reconnect — either way
                // the book is on its way; the Shared-row badge tracks queued.
                completed += 1
            case nil:
                onFailure("\(title): server rejected the upload")
            }
            progress(completed, total, title)
        }
        if completed > 0 {
            await refreshBooks()
        }
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

    /// Search + facet filtering applied client-side over the pulled books
    /// (the home library filters in SQL; the remote has only the pulled
    /// snapshot, so the same UX is a local filter).
    var books: [IndexedBook] {
        let filtered: [IndexedBook]
        if let facet = facetNavigation.activeFacet {
            filtered = remoteBooks.filter { book in
                switch facet.type {
                case .author: return book.authors.contains(facet.value)
                case .series: return book.series == facet.value
                case .tag: return book.tags.contains(facet.value)
                case .format: return book.formats.contains { $0.kind.lowercased() == facet.value.lowercased() }
                }
            }
        } else {
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            filtered = query.isEmpty ? remoteBooks : remoteBooks.filter {
                $0.title.lowercased().contains(query)
                    || $0.authors.contains { $0.lowercased().contains(query) }
                    || $0.tags.contains { $0.lowercased().contains(query) }
                    || ($0.series?.lowercased().contains(query) ?? false)
            }
        }
        switch sortOrder {
        case .name:
            return filtered.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .dateAdded:
            return filtered.sorted { ($0.addedMilliseconds ?? 0) > ($1.addedMilliseconds ?? 0) }
        }
    }
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

    /// Whether the server last answered a request. False once something
    /// fails unreachably — the sidebar shows the drop and edits queue
    /// offline until a successful refresh.
    var isConnected = true

    func refreshBooks() async {
        try? await refreshBooksThrowing()
    }

    /// The throwing variant: the connect flow needs the failure (401 →
    /// credential prompt, unreachable → error) instead of a silent empty
    /// library.
    func refreshBooksThrowing() async throws {
        do {
            try await remote.pull()
            isConnected = true
            remoteBooks = await remote.books()
        } catch {
            noteUnreachable(error)
            throw error
        }
    }

    /// Marks the connection dropped when the error is a network failure
    /// (server unreachable). HTTP errors mean the server is up — those are
    /// not a connection drop.
    func noteUnreachable(_ error: Error) {
        if let remoteError = error as? RemoteLibrary.RemoteError,
           case .unreachable = remoteError {
            isConnected = false
        }
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
