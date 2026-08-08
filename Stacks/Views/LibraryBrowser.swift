import AppKit
import Foundation
import StacksCore

/// Toolbar sort order for the library browser (Finder-style).
enum BrowserSortOrder: String, CaseIterable {
    case name
    case dateAdded
}

/// The browser-facing surface of an open library OR a connected remote
/// library. `LibraryConnection` (home) and `RemoteLibraryBrowser` conform;
/// grid/table/facet views are generic over it.
///
/// `repository` is nil for remote libraries — their covers come from the
/// server via `coverImage(for:)` (the default implementation routes through
/// the thumbnail cache for local libraries).
@MainActor
protocol LibraryBrowser: AnyObject {
    var id: UUID { get }
    var name: String { get }
    var repository: LibraryRepository? { get }
    var books: [IndexedBook] { get }
    var selection: Set<UUID> { get set }
    var selectionBooks: [IndexedBook] { get }
    var isMarqueeSelecting: Bool { get set }
    var isLibraryUnavailable: Bool { get }
    var facetNavigation: FacetNavigation { get set }
    var authors: [(value: String, count: Int)] { get }
    var series: [(value: String, count: Int)] { get }
    var tags: [(value: String, count: Int)] { get }
    var formats: [(value: String, count: Int)] { get }
    var metadataEditQueue: [IndexedBook]? { get set }
    var searchText: String { get set }
    var viewMode: BrowserViewMode { get set }
    /// Toolbar sort order (Name or Date added); applies in grid and table.
    var sortOrder: BrowserSortOrder { get set }
    /// Book ids awaiting delete confirmation (the grid's confirmation alert).
    var pendingDelete: Set<UUID>? { get set }
    func open(id: UUID) async
    func reveal(id: UUID) async
    func formatFileURL(for book: IndexedBook) -> URL?
    func requestDelete(ids: Set<UUID>)
    func delete(ids: Set<UUID>) async
    func restore(id: UUID) async
    func clearGridSelection()
    func selectCategory(_ type: FacetType?)
    func selectValue(_ value: String?)
    func selectInGrid(_ book: IndexedBook)
    func refreshBooks() async
    /// The cover image for a book — the thumbnail cache for local libraries,
    /// a server fetch for remotes.
    func coverImage(for book: IndexedBook) async -> NSImage?
}

extension LibraryBrowser {
    /// Default: the local thumbnail pipeline (covers + format files on disk).
    func coverImage(for book: IndexedBook) async -> NSImage? {
        guard let repository else { return nil }
        return await ThumbnailCache.shared.thumbnail(for: book, repository: repository)
    }
}

extension LibraryConnection: LibraryBrowser {}
