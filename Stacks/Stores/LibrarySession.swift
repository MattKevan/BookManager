import AppKit
import StacksCore
import Foundation
import Observation

/// A library that was open last session but could not be reopened (offline
/// NAS, missing volume, unresolvable bookmark). Rendered as a flat sidebar row
/// in the Libraries section with Retry/Remove. Not a `LibraryConnection` — a
/// connection requires an opened repository, so unreachable libraries are
/// tracked separately.
struct OfflineLibrary: Identifiable {
    let id: UUID
    let name: String
    /// Nil when the bookmark itself is unresolvable (no path to retry).
    let url: URL?
    /// Whether it was the home library when the session closed — Retry uses
    /// this to re-open it as home (unless a home already exists, in which
    /// case it joins as a peer).
    let isHome: Bool
}

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
        case open, addBooks, calibre, changeHome
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
    /// Set by `presentImportReport()` when the system notification is not
    /// authorized; the import-report sheet binds to this so any view (peer
    /// toolbar, context menu) can present the transfer report.
    var importReportPresented = false
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

    /// Libraries from the persisted open set that failed to reopen (offline
    /// NAS, missing volume, unresolvable bookmark). Populated by
    /// `reopenLibraries`; Retry/Remove act on them directly.
    var offlinePeers: [OfflineLibrary] = []

    /// Persists the open set (bookmarks, order, home designation, names) so
    /// launch can reopen exactly what the user had open. Separate from
    /// `bookmarks` (Open Recent). Internal (like `bookmarks`) so the hub
    /// extension in `LibrarySession+Connection.swift` can read it.
    let openStore = OpenLibraryStore()
    var activeLibraryID: UUID? {
        get { _activeLibraryID ?? home?.id }
        set { _activeLibraryID = newValue }
    }
    private var _activeLibraryID: UUID?

    /// Library ids with an open currently in flight (manifest read passed,
    /// connection not yet appended). Guards `openRequested` against creating
    /// two connections for the same folder when a second open overlaps the
    /// slow catalog rebuild + sync inside `LibraryConnection(openAt:)`.
    /// Internal (not `private`) so the hub extension in
    /// `LibrarySession+Connection.swift` can read it.
    var pendingOpenLibraryIDs: Set<UUID> = []

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
        if id != nil {
            // Device mode: the browser context returns to home — clearing
            // activeLibraryID makes `activeLibrary` resolve to home while a
            // device is selected, so the home toolbar cluster (Add Books),
            // search, and sync bindings stay correct over the device listing.
            // Deselecting returns to home; a peer's facet state is preserved
            // on its connection, just not auto-restored.
            activeLibraryID = nil
            activeLibrary?.facetNavigation.clear()
        }
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

    /// Create New Library: NSSavePanel lets the user choose WHERE the library
    /// lives and NAME its folder. The open-panel flow this replaces could only
    /// pick an existing folder — it either created the library inside an
    /// arbitrary folder or hit `libraryAlreadyExists`. The panel returns
    /// <location>/<name>; the folder is created by `LibraryRepository.create`.
    func createNewLibrary() {
        let panel = NSSavePanel()
        panel.title = "Create New Library"
        panel.prompt = "Create"
        panel.nameFieldStringValue = "My Library"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await createLibrary(at: url) }
    }

    func createLibrary(at url: URL) async {
        // A library owns its folder: refuse to create inside an existing
        // non-empty folder; the already-a-library case surfaces as Core's
        // readable `libraryAlreadyExists` error.
        if FileManager.default.fileExists(atPath: url.path) {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            if !contents.isEmpty {
                lastError = "“\(url.lastPathComponent)” already exists and is not empty. Choose a new library name."
                return
            }
        }
        await activate(url: url, create: true)
    }
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

    /// Reopens the persisted open set at launch: the home library first (as
    /// home), then each peer, in the saved order. Libraries whose bookmark
    /// cannot be resolved or whose folder is unreachable become offline rows
    /// (Retry available when a path is recoverable). The welcome screen
    /// appears when nothing is persisted or every entry failed. No-op when a
    /// library is already loaded (the window reappeared mid-session).
    func reopenLibraries() async {
        guard home == nil else { return }
        let order = openStore.order()
        guard !order.isEmpty else {
            state = .welcome
            return
        }
        // The persisted order's FIRST entry is the home library
        // (`persistOpenOrder` always writes home first). Deriving home from
        // the order — not from `openStore.home()`, which can be stale or
        // missing in stores written by earlier builds — guarantees the
        // default library reopens as home and never lands in the Libraries
        // (peers) section on relaunch.
        let homeID = order.first
        for libraryID in order {
            guard let resolved = try? openStore.resolve(libraryID) else {
                // Unresolvable bookmark (missing/corrupt data): no URL to
                // retry — a name-only offline row lets the user Remove it.
                offlinePeers.append(OfflineLibrary(
                    id: libraryID,
                    name: openStore.names()[libraryID] ?? "Library",
                    url: nil,
                    isHome: libraryID == homeID
                ))
                continue
            }
            await openRequested(
                at: resolved.url,
                intent: (libraryID == homeID) ? .home : .peer,
                fallbackToWelcome: libraryID == homeID
            )
            if !isConnected(libraryID) {
                offlinePeers.append(OfflineLibrary(
                    id: libraryID,
                    name: openStore.names()[libraryID] ?? resolved.url.lastPathComponent,
                    url: resolved.url,
                    isHome: libraryID == homeID
                ))
            }
        }
        // A failed home with surviving peers: promote the first peer so the
        // session is loaded (the failed home stays as an offline row).
        if home == nil, !peers.isEmpty {
            await promoteNextPeerToHome()
        }
        // Heal a stale/missing home() designation so the store agrees with
        // the order (order.first is authoritative).
        if openStore.home() != homeID { openStore.setHome(homeID) }
        if home == nil, offlinePeers.isEmpty {
            state = .welcome
        }
    }

    /// Retries opening an offline library with its saved intent (home when it
    /// was home and no home exists yet; the open policy dedupes and handles
    /// the role). The offline row is dropped when the library is connected.
    func retryOffline(_ offline: OfflineLibrary) async {
        guard let url = offline.url else { return }
        await openRequested(at: url, intent: offline.isHome ? .home : .peer)
        if isConnected(offline.id) {
            offlinePeers.removeAll { $0.id == offline.id }
        }
    }

    /// Drops an offline library from the sidebar and forgets it (removes its
    /// bookmark so it is not reopened next launch).
    func removeOffline(_ offline: OfflineLibrary) {
        openStore.remove(offline.id)
        offlinePeers.removeAll { $0.id == offline.id }
    }

    /// Whether `libraryID` is an open connection (home or peer).
    private func isConnected(_ libraryID: UUID) -> Bool {
        home?.id == libraryID || peers.contains { $0.id == libraryID }
    }

    /// Closes the active connection: a peer is dropped by itself; closing
    /// home tears down the session's transient state, promotes the next peer
    /// (or returns to the welcome screen when none remain).
    func closeLibrary() async {
        let closedHomeID = home?.id
        if let active = activeLibrary, active !== home {
            await closePeer(active)
            return
        }
        home?.stop()
        home = nil
        if let closedHomeID { openStore.remove(closedHomeID) }
        activeSecurityURL?.stopAccessingSecurityScopedResource()
        activeSecurityURL = nil
        stopCalibreAccess()
        state = .welcome
        inspectorPresented = false
        importReport = nil
        importReportPresented = false
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
        // Record the promoted home (or none) so the store stays accurate for
        // the next launch; the order re-follows the live set.
        openStore.setHome(home?.id)
        persistOpenOrder()
    }

    // MARK: - Activation

    private func activate(url: URL, create: Bool, fallbackToWelcome: Bool = false) async {
        // The hub owns opening: create writes the library skeleton first, then
        // both paths route through `openRequested` — the first library becomes
        // home, every later open becomes a peer (never switches home). The
        // loading state only applies when nothing is open yet — creating while
        // a library is open must not blank the main content.
        if home == nil { state = .loading }
        do {
            if create {
                _ = try await LibraryRepository.create(
                    at: url, indexesDirectory: try Self.indexDirectory(), deviceID: deviceID
                )
            }
            // Create always targets home (Cmd+Shift+N / Settings Create New):
            // a folder already open as a peer role-swaps via makeHomeExisting.
            // Plain open becomes home only while no home exists; otherwise it
            // adds a peer (never switches home).
            let intent: OpenIntent = create ? .home : ((home == nil) ? .home : .peer)
            await openRequested(
                at: url,
                intent: intent,
                fallbackToWelcome: fallbackToWelcome
            )
        } catch {
            // Only the create step throws here; `openRequested` handles its own
            // failures (including the fallbackToWelcome path). Errors surface
            // as a dialog (lastError), never a full-screen takeover.
            if fallbackToWelcome {
                lastError = "Couldn’t reopen “\(url.lastPathComponent)”: \(error.localizedDescription)"
                state = .welcome
            } else {
                lastError = error.localizedDescription
                if home == nil { state = .welcome }
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
    var libraryRoot: URL? { repository?.root }

    func refreshAll() async { await connection?.refreshAll() }
    func refreshFacets() async { await connection?.refreshFacets() }
    func refreshDeleted() async { await connection?.refreshDeleted() }
    func selectCategory(_ type: FacetType?) {
        // Selecting a home facet makes home the browser context (a sidebar
        // click on a Library-section row switches back from a peer or device).
        activeLibraryID = home?.id
        connection?.selectCategory(type)
    }
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
