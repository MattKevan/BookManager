import AppKit
import StacksCore
import Foundation
import Observation

@MainActor
@Observable
final class LibrarySession {
    /// The browser view mode now lives on the connection (`BrowserViewMode`);
    /// this typealias keeps existing `LibrarySession.ViewMode` references
    /// (e.g. the toolbar picker) compiling until the hub rework.
    typealias ViewMode = BrowserViewMode

    enum State {
        case welcome
        case loading
        case loaded
        case failed(message: String)
    }

    /// What the file importer should do when it completes.
    enum PickerAction {
        case create, open, addBooks, calibre
    }

    /// Request presented to the file importer (menu, toolbar, or welcome screen).
    var pickerAction: PickerAction?
    var isPickerPresented = false

    /// A bookmarked library surfaced in the Open Recent menu.
    struct RecentLibraryEntry: Identifiable, Equatable {
        let id: UUID
        let url: URL
        var name: String { url.lastPathComponent }
    }

    /// Internal setter: the hub (`LibrarySession+Connection`) transitions
    /// this state machine when opening/closing libraries.
    var state: State = .welcome
    var lastError: String?
    var importReport: ImportReport?
    var inspectorPresented = false

    // Metadata enrichment state (home library)
    var metadataCandidates: [MetadataCandidate] = []
    /// Presented by the view; the review sheet binds to this.
    var metadataReviewPresented = false
    var metadataLookupError: String?
    var metadataBookID: UUID?
    var isFetchingMetadata = false
    var metadataService: MetadataLookupService?

    static let metadataUserAgent = "Stacks/1.0"
    var diagnosticsPresented = false

    // Calibre import wizard state
    var calibreSummary: CalibreLibrarySummary?
    var calibreBooks: [CalibreBookRecord] = []
    var calibreSelectedIDs = Set<Int>()
    var calibreImportReport: CalibreImportReport?
    var calibreImportInProgress = false
    var calibreSourcePath: String?

    let deviceID: UUID
    let bookmarks: LibraryBookmarkStore
    var activeSecurityURL: URL?
    var calibreSourceSecurityURL: URL?

    /// The home library connection — the hub's primary library. `connection`
    /// is a computed alias for `home` so existing home-scoped callers (the
    /// shims below, views) keep compiling until Task 5 routes them to the
    /// active library.
    var connection: LibraryConnection? { home }

    // Hub state: the home library, open peers, and the browser-context
    // selection. Stored here (not in the `+Connection` extension) because
    // Swift extensions cannot hold stored properties.
    var home: LibraryConnection? {
        get { _home }
        set { _home = newValue }
    }
    private var _home: LibraryConnection?
    var peers: [LibraryConnection] = []
    var activeLibraryID: UUID? {
        get { _activeLibraryID ?? home?.id }
        set { _activeLibraryID = newValue }
    }
    private var _activeLibraryID: UUID?

    // Device support: the connected-device store and the sidebar selection
    // bridging into it (selecting a device clears the library facet, and vice
    // versa is handled by `selectCategory`).
    let devices = DeviceManager()
    var selectedDeviceID: UUID? {
        get { devices.selectedDeviceID }
        set { devices.selectedDeviceID = newValue }
    }

    /// Selects a device in the sidebar; choosing a device clears the active
    /// library's facet so the detail area shows the device browser. The actual
    /// state transition (selection + book listing) happens in `DeviceManager.select`
    /// so selecting a device immediately loads its books.
    func selectDevice(_ id: UUID?) {
        if id != nil { activeLibrary?.facetNavigation.clear() }
        Task { await devices.select(id) }
    }

    init(
        deviceID: UUID = UUID(),
        bookmarks: LibraryBookmarkStore = LibraryBookmarkStore()
    ) {
        self.deviceID = deviceID
        self.bookmarks = bookmarks
        recentLibraries = Self.resolveRecents(bookmarks)
    }

    func createLibrary(at url: URL) async { await activate(url: url, create: true) }
    func openLibrary(at url: URL) async { await activate(url: url, create: false) }
    func openLibrary(at url: URL, fallbackToWelcome: Bool) async {
        await activate(url: url, create: false, fallbackToWelcome: fallbackToWelcome)
    }

    /// Asks the file importer to run `action` (from a menu, toolbar, or the
    /// welcome screen).
    func present(_ action: PickerAction) {
        pickerAction = action
        isPickerPresented = true
    }

    /// Bookmarked libraries with their resolved URLs, newest first. Stored so
    /// the Open Recent menu observes refreshes; updated whenever a library is
    /// opened or closed.
    var recentLibraries: [RecentLibraryEntry]

    static func resolveRecents(_ bookmarks: LibraryBookmarkStore) -> [RecentLibraryEntry] {
        bookmarks.recentLibraries().compactMap { entry in
            guard let resolved = try? bookmarks.resolve(entry.id) else { return nil }
            return RecentLibraryEntry(id: entry.id, url: resolved.url)
        }
    }

    /// Opens the most recently used library at launch. Falls back to the
    /// welcome (open/create) screen when there is no bookmark, it cannot be
    /// resolved, or the library can no longer be opened. No-op when a library
    /// is already loaded (e.g. the window reappeared mid-session).
    func openMostRecentLibrary() async {
        guard repository == nil else { return }
        guard let id = bookmarks.mostRecentlyOpenedLibraryID(),
              let resolved = try? bookmarks.resolve(id) else {
            state = .welcome
            return
        }
        await openLibrary(at: resolved.url, fallbackToWelcome: true)
    }

    /// Closes the active connection: a peer is dropped by itself; closing
    /// home tears down the session's transient state, promotes the next peer
    /// (or returns to the welcome screen when none remain).
    func closeLibrary() async {
        if let active = activeLibrary, active !== home {
            await closePeer(active)
            return
        }
        home?.stop()
        home = nil
        activeSecurityURL?.stopAccessingSecurityScopedResource()
        activeSecurityURL = nil
        stopCalibreAccess()
        state = .welcome
        inspectorPresented = false
        importReport = nil
        metadataCandidates = []
        metadataReviewPresented = false
        metadataLookupError = nil
        metadataBookID = nil
        isFetchingMetadata = false
        metadataService = nil
        lastError = nil
        calibreSummary = nil
        calibreBooks = []
        calibreSelectedIDs = []
        calibreImportReport = nil
        calibreImportInProgress = false
        calibreSourcePath = nil
        pickerAction = nil
        isPickerPresented = false
        recentLibraries = Self.resolveRecents(bookmarks)
        await promoteNextPeerToHome()
    }

    // MARK: - Activation

    private func activate(url: URL, create: Bool, fallbackToWelcome: Bool = false) async {
        // The hub owns opening: create writes the library skeleton first, then
        // both paths route through `openRequested` — the first library becomes
        // home, every later open becomes a peer (never switches home).
        state = .loading
        do {
            if create {
                _ = try await LibraryRepository.create(
                    at: url, indexesDirectory: try Self.indexDirectory(), deviceID: deviceID
                )
            }
            await openRequested(
                at: url,
                intent: (home == nil) ? .home : .peer,
                fallbackToWelcome: fallbackToWelcome
            )
        } catch {
            // Only the create step throws here; `openRequested` handles its own
            // failures (including the fallbackToWelcome path).
            if fallbackToWelcome {
                lastError = "Couldn’t reopen “\(url.lastPathComponent)”: \(error.localizedDescription)"
                state = .welcome
            } else {
                state = .failed(message: error.localizedDescription)
            }
        }
    }

    static func indexDirectory() throws -> URL {
        let root = URL.applicationSupportDirectory
            .appending(path: "Stacks", directoryHint: .isDirectory)
            .appending(path: "Indexes", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // MARK: - Delegation shims (removed in the hub rework)

    /// Per-library state and behavior now live on `LibraryConnection`; these
    /// shims keep every existing caller (views, menus, extensions) compiling
    /// with identical behavior. Task 4 replaces them with the hub model.

    var repository: LibraryRepository? { connection?.repository }
    var books: [IndexedBook] { connection?.books ?? [] }
    var deletedBooks: [IndexedBook] { connection?.deletedBooks ?? [] }
    var missingFiles: [(book: IndexedBook, filename: String)] { connection?.missingFiles ?? [] }
    var facetNavigation: FacetNavigation { connection?.facetNavigation ?? FacetNavigation() }
    var selection: Set<UUID> {
        get { connection?.selection ?? [] }
        set { connection?.selection = newValue }
    }
    var selectionAnchor: UUID? { connection?.selectionAnchor }
    var selectionBooks: [IndexedBook] { connection?.selectionBooks ?? [] }
    var searchText: String {
        get { connection?.searchText ?? "" }
        set { connection?.searchText = newValue }
    }
    var isLibraryUnavailable: Bool { connection?.isLibraryUnavailable ?? false }
    var isSyncing: Bool { connection?.isSyncing ?? false }
    var pendingSyncCount: Int { connection?.pendingSyncCount ?? 0 }
    var syncState: SyncState? { connection?.syncState }
    var monitor: LibraryMonitor? { connection?.monitor }
    var quarantinedChanges: [URL] { connection?.quarantinedChanges ?? [] }
    var reconciliationReport: ReconciliationReport? { connection?.reconciliationReport }
    var rebuildProgress: Double? { connection?.rebuildProgress }
    var isRebuilding: Bool { connection?.isRebuilding ?? false }
    var cancelFlag: RebuildCancelFlag { connection?.cancelFlag ?? RebuildCancelFlag() }
    var isMarqueeSelecting: Bool {
        get { connection?.isMarqueeSelecting ?? false }
        set { connection?.isMarqueeSelecting = newValue }
    }
    var metadataEditQueue: [IndexedBook]? {
        get { connection?.metadataEditQueue }
        set { connection?.metadataEditQueue = newValue }
    }
    var pendingDelete: Set<UUID>? {
        get { connection?.pendingDelete }
        set { connection?.pendingDelete = newValue }
    }
    var libraryRoot: URL? { repository?.root }

    func refreshAll() async { await connection?.refreshAll() }
    func refreshFacets() async { await connection?.refreshFacets() }
    func refreshDeleted() async { await connection?.refreshDeleted() }
    func selectCategory(_ type: FacetType?) { connection?.selectCategory(type) }
    func requestDelete(ids: Set<UUID>) { connection?.requestDelete(ids: ids) }
    func delete(ids: Set<UUID>) async { await connection?.delete(ids: ids) }
    func restore(id: UUID) async { await connection?.restore(id: id) }
    func open(id: UUID) async { await connection?.open(id: id) }
    func reveal(id: UUID) async { await connection?.reveal(id: id) }
    func runSyncSequence(manual: Bool) async { await connection?.runSyncSequence(manual: manual) }
    func syncNow() async { await connection?.syncNow() }
    func startMonitor() async { await connection?.startMonitor() }
    func stopMonitor() { connection?.stopMonitor() }
    func refreshPendingSync() { connection?.refreshPendingSync() }
    func refreshLibraryAvailability() { connection?.refreshLibraryAvailability() }
    func reconnectIfNeeded() async { await connection?.reconnectIfNeeded() }
    func rebuildIndex() async { await connection?.rebuildIndex() }
    func cancelRebuild() { connection?.cancelRebuild() }
    func reloadDiagnostics() async { await connection?.reloadDiagnostics() }
    static func syncRoot() throws -> URL { try LibraryConnection.syncRoot() }
}

/// Lock-protected boolean so the repository's synchronous `cancelled` closure
/// (called from the repository actor) can read the MainActor connection's
/// cancel request without a data race (a stale read only delays cancellation
/// by one book — benign for a rebuild-cancel flag).
final class RebuildCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var requested: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
