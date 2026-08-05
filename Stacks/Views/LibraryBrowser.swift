import Foundation
import StacksCore

/// The browser-facing surface of an open library. `LibraryConnection` (home and
/// peers) conforms; grid/table/facet views are generic over it.
///
/// `repository` is part of the surface because the cover tile needs it for
/// thumbnails (`ThumbnailCache.thumbnail(for:repository:)` resolves cover.jpg
/// and format files against the library root). Every conformer is a full
/// connection, so the dependency is structural, not incidental.
@MainActor
protocol LibraryBrowser: AnyObject {
    var id: UUID { get }
    var name: String { get }
    var repository: LibraryRepository { get }
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
    func open(id: UUID) async
    func reveal(id: UUID) async
    func formatFileURL(for book: IndexedBook) -> URL?
    func requestDelete(ids: Set<UUID>)
    func clearGridSelection()
    func selectCategory(_ type: FacetType?)
    func selectValue(_ value: String?)
    func selectInGrid(_ book: IndexedBook)
    func refreshBooks() async
}

extension LibraryConnection: LibraryBrowser {}
