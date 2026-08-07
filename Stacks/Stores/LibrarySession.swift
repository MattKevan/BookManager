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
    /// Fraction (0...1) of the selected books decided by the import loop.
    var calibreImportProgress: Double?
    /// Live Calibre activity (scan phases, per-book import progress) for the
    /// toolbar activity popover.
    var calibreActivity: CalibreImportActivity?
    /// Throttle timestamp for live library refreshes during a Calibre import.
    var lastCalibreLiveRefresh: Date?
    var calibreSourcePath: String?
    /// The library the Calibre import will land in — the library that was
    /// active when the source folder was chosen. Captured at scan start
    /// because the scan runs while the window is still interactive (only the
    /// wizard that follows is modal), so the user could switch libraries
    /// mid-scan.
    /// The in-flight Calibre import (started by the wizard's Import button).
    /// Held so `cancelCalibreImport` can actually stop the import instead of
    /// just dismissing the wizard while books keep being written.
    var calibreImportTask: Task<Void, Never>?

    let deviceID: UUID
    let bookmarks: LibraryBookmarkStore
    var activeSecurityURL: URL?
    var calibreSourceSecurityURL: URL?
    /// The still-open Calibre snapshot reader while the import wizard is
    /// active; the import fetches deferred blob covers from it per book.
    var calibreReader: CalibreReader?

    /// The home library connection — the hub's primary library. `connection`
    /// is a computed alias for `home` so existing home-scoped callers (the
    /// shims below, views) keep compiling until Task 5 routes them to the
    /// active library.
    var connection: LibraryConnection? { home }

    /// The connected remote library (Plan 4): when non-nil, the browser
    /// context shows it instead of the home library. One remote at a time.
    var remoteBrowser: RemoteLibraryBrowser? {
        get { _remoteBrowser }
        set { _remoteBrowser = newValue }
    }
    private var _remoteBrowser: RemoteLibraryBrowser?
    /// The library awaiting credentials: non-nil while the credential prompt
    /// sheet is presented (ContentView binds `.sheet(item:)` to it).
    var credentialPrompt: DiscoveredLibrary? {
        get { _credentialPrompt }
        set { _credentialPrompt = newValue }
    }
    private var _credentialPrompt: DiscoveredLibrary?
    /// Non-nil while the "Connect to Server…" sheet is presented.
    var connectToServerPresented: Bool {
        get { _connectToServerPresented }
        set { _connectToServerPresented = newValue }
    }
    private var _connectToServerPresented = false

    /// The current browser surface: the remote when connected, else the
    /// active library. Grid/table/facet views are generic over it.
    var browser: LibraryBrowser? { remoteBrowser ?? activeLibrary }

    // The open library (single-library model) and the browser-context
    // selection. Stored here (not in the `+Connection` extension) because
    // Swift extensions cannot hold stored properties.
    var home: LibraryConnection? {
        get { _home }
        set {
            // Sharing binds to the home library's repository; switching or
            // closing home must tear the server down (the new library would
            // otherwise be served under the old journal).
            if newValue?.id != _home?.id, sharing.isSharing {
                Task { await sharing.stop() }
            }
            _home = newValue
        }
    }
    private var _home: LibraryConnection?
    /// The library from the persisted open set that failed to reopen
    /// (offline NAS, missing volume, unresolvable bookmark). Populated by
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
        discovery.start()
    }

    /// Bonjour browser for the Shared sidebar section. Runs for the app's
    /// lifetime; `stop()` is a no-op at deinit (the process owns the socket).
    let discovery = LibraryDiscovery()

    /// The in-process library server + Bonjour advertising (Settings →
    /// Sharing). Lifecycle follows the home library and the share toggle.
    let sharing = SharingService()

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

    /// Reopens the persisted library at launch: the saved home entry becomes
    /// the home library (extra order entries written by pre-single-library
    /// builds are ignored — one library per instance). A library whose
    /// bookmark cannot be resolved or whose folder is unreachable becomes an
    /// offline row (Retry available when a path is recoverable). The welcome
    /// screen appears when nothing is persisted or the reopen failed. No-op
    /// when a library is already loaded (the window reappeared mid-session).
    func reopenLibraries() async {
        guard home == nil else { return }
        let order = openStore.order()
        guard let homeID = order.first else {
            state = .welcome
            return
        }
        // A previously-opened library exists: show the loading spinner, never
        // the welcome screen, while it reopens (openRequested flips to
        // `.loaded` when ready; the failure paths below fall back).
        state = .loading
        guard let resolved = try? openStore.resolve(homeID) else {
            // Unresolvable bookmark (missing/corrupt data): no URL to retry —
            // a name-only offline row lets the user Remove it.
            offlinePeers.append(OfflineLibrary(
                id: homeID,
                name: openStore.names()[homeID] ?? "Library",
                url: nil,
                isHome: true
            ))
            state = .welcome
            return
        }
        await openRequested(at: resolved.url, fallbackToWelcome: true)
        if !isConnected(homeID) {
            offlinePeers.append(OfflineLibrary(
                id: homeID,
                name: openStore.names()[homeID] ?? resolved.url.lastPathComponent,
                url: resolved.url,
                isHome: true
            ))
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
        await openRequested(at: url)
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

    /// Whether `libraryID` is the open connection.
    private func isConnected(_ libraryID: UUID) -> Bool {
        home?.id == libraryID
    }

    /// Closes the library: tears down the connection and the session's
    /// transient state, returning to the welcome screen.
    func closeLibrary() async {
        let closedHomeID = home?.id
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
        openStore.setHome(nil)
        persistOpenOrder()
    }

    // MARK: - Activation

    private func activate(url: URL, create: Bool, fallbackToWelcome: Bool = false) async {
        // Opening owns everything: create writes the library skeleton first,
        // then both paths route through `openRequested` — one library per
        // instance, so opening replaces the current home. The loading state
        // only applies when nothing is open yet — creating while a library is
        // open must not blank the main content.
        if home == nil { state = .loading }
        do {
            if create {
                _ = try await LibraryRepository.create(
                    at: url, indexesDirectory: try Self.indexDirectory(), deviceID: deviceID
                )
            }
        await openRequested(
            at: url,
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
        get { browser?.selection ?? [] }
        set { browser?.selection = newValue }
    }
    var selectionBooks: [IndexedBook] { browser?.selectionBooks ?? [] }
    var searchText: String {
        get { browser?.searchText ?? "" }
        set { browser?.searchText = newValue }
    }
    // Status shims for the pre-network UI. The single-writer model removes
    // shared-FS availability/sync state; the network slice re-adds live
    // connection status.
    var isLibraryUnavailable: Bool { false }
    var isSyncing: Bool { false }
    var pendingSyncCount: Int { 0 }
    var rebuildProgress: Double? { connection?.rebuildProgress }
    var isRebuilding: Bool { connection?.isRebuilding ?? false }
    var cancelFlag: RebuildCancelFlag { connection?.cancelFlag ?? RebuildCancelFlag() }
    var isMarqueeSelecting: Bool {
        get { connection?.isMarqueeSelecting ?? false }
        set { connection?.isMarqueeSelecting = newValue }
    }
    var metadataEditQueue: [IndexedBook]? {
        get { browser?.metadataEditQueue }
        set { browser?.metadataEditQueue = newValue }
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
    func rebuildIndex() async { await connection?.rebuildIndex() }
    func cancelRebuild() { connection?.cancelRebuild() }
    func reloadDiagnostics() async { await connection?.reloadDiagnostics() }
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
