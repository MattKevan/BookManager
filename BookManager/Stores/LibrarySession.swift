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

    private(set) var state: State = .welcome
    private(set) var repository: LibraryRepository?
    /// Metadata edits queued locally because the library folder is unreachable;
    /// cleared when `syncNow` drains the outbox.
    var pendingSyncCount = 0

    /// Rebuild progress (0...1) while `isRebuilding`; nil otherwise.
    var rebuildProgress: Double?
    /// True while the Diagnostics rebuild is running (drives the progress UI).
    var isRebuilding = false
    let cancelFlag = RebuildCancelFlag()

    /// Undecodable change files moved to the library quarantine by the last
    /// ingest — surfaced in Diagnostics so nothing silently disappears.
    var quarantinedChanges: [URL] = []
    /// Read-only gate: the library folder is known unreachable, so editing is
    /// disabled until a reconnect succeeds (approved read-only-when-offline
    /// amendment). Transient mid-session write failures still stage to the
    /// outbox via `saveOffline`.
    var isLibraryUnavailable = false
    /// True while a sync sequence (drain + ingest + reconcile) is running.
    var isSyncing = false
    /// The last reconciliation pass's findings — surfaced in Diagnostics so
    /// re-pointed folders and forked conflicts are never silent.
    var reconciliationReport: ReconciliationReport?
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
    var viewMode: ViewMode = .grid
    var inspectorPresented = false
    /// True while a grid marquee drag is in flight; suppresses the inspector's
    /// click-driven auto-show so a mid-drag single selection doesn't pop it open.
    var isMarqueeSelecting = false
    var selection = Set<UUID>()
    /// The anchor for ⇧-click range selection in the grid. Ignored by the
    /// table view (which manages its own selection semantics natively).
    private(set) var selectionAnchor: UUID?
    /// Sidebar + middle-column navigation state (which category is active,
    /// which value is chosen). Drives the 3-column browser.
    var facetNavigation = FacetNavigation()

    // Device support: the connected-device store and the sidebar selection
    // bridging into it (selecting a device clears the library facet, and vice
    // versa is handled by `selectCategory`).
    let devices = DeviceManager()
    var selectedDeviceID: UUID? {
        get { devices.selectedDeviceID }
        set { devices.selectedDeviceID = newValue }
    }

    /// Selects a device in the sidebar; choosing a device clears the library
    /// facet so the detail area shows the device browser. The actual state
    /// transition (selection + book listing) happens in `DeviceManager.select`
    /// so selecting a device immediately loads its books.
    func selectDevice(_ id: UUID?) {
        if id != nil { facetNavigation.clear() }
        Task { await devices.select(id) }
    }

    private(set) var books: [IndexedBook] = []
    private(set) var authors: [(value: String, count: Int)] = []
    private(set) var series: [(value: String, count: Int)] = []
    private(set) var tags: [(value: String, count: Int)] = []
    private(set) var formats: [(value: String, count: Int)] = []
    private(set) var deletedBooks: [IndexedBook] = []
    /// Book ids awaiting delete confirmation; nil when nothing is pending.
    /// Set by `requestDelete`, consumed by the confirmation alert, then
    /// cleared before `delete(ids:)` runs.
    var pendingDelete: Set<UUID>?
    var missingFiles: [(book: IndexedBook, filename: String)] = []
    var importReport: ImportReport?
    /// Books queued for the metadata editor. The editor steps through them
    /// (Book 1 of N with Prev/Next) when more than one is set; nil closes it.
    /// Populated from `selectionBooks` (or `[book]` for single-book callers).
    var metadataEditQueue: [IndexedBook]?

    /// The library books backing the current selection, in catalog order —
    /// the order the batch metadata editor walks its “1 of N” queue in.
    var selectionBooks: [IndexedBook] {
        books.filter { selection.contains($0.id) }
    }

    // Metadata enrichment state
    var metadataCandidates: [MetadataCandidate] = []
    /// Presented by the view; the review sheet binds to this.
    var metadataReviewPresented = false
    var metadataLookupError: String?
    var metadataBookID: UUID?
    var isFetchingMetadata = false
    var metadataService: MetadataLookupService?

    static let metadataUserAgent = "BookManager/1.0"
    var diagnosticsPresented = false

    // Calibre import wizard state
    var calibreSummary: CalibreLibrarySummary?
    var calibreBooks: [CalibreBookRecord] = []
    var calibreSelectedIDs = Set<Int>()
    var calibreImportReport: CalibreImportReport?
    var calibreImportInProgress = false
    var calibreSourcePath: String?

    let deviceID: UUID
    private let bookmarks: LibraryBookmarkStore
    private var activeSecurityURL: URL?
    var calibreSourceSecurityURL: URL?
    var syncState: SyncState?
    var monitor: LibraryMonitor?
    private var searchTask: Task<Void, Never>?

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
    private(set) var recentLibraries: [RecentLibraryEntry]

    private static func resolveRecents(_ bookmarks: LibraryBookmarkStore) -> [RecentLibraryEntry] {
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

    func closeLibrary() {
        searchTask?.cancel()
        searchTask = nil
        activeSecurityURL?.stopAccessingSecurityScopedResource()
        activeSecurityURL = nil
        stopCalibreAccess()
        stopMonitor()
        repository = nil
        syncState = nil
        pendingSyncCount = 0
        quarantinedChanges = []
        isLibraryUnavailable = false
        isSyncing = false
        reconciliationReport = nil
        state = .welcome
        books = []
        deletedBooks = []
        selection = []
        selectionAnchor = nil
        pendingDelete = nil
        facetNavigation.clear()
        searchText = ""
        missingFiles = []
        viewMode = .grid
        inspectorPresented = false
        isMarqueeSelecting = false
        importReport = nil
        metadataEditQueue = nil
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
    }

    // MARK: - Activation

    private func activate(url: URL, create: Bool, fallbackToWelcome: Bool = false) async {
        // A mid-session library switch (Cmd+O, Open Recent, Cmd+N) reaches
        // activate without closeLibrary: stop the old library's monitor so it
        // never watches the old root against the new library. Idempotent; the
        // runSyncSequence tail rebuilds the monitor for the new root.
        stopMonitor()
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
            recentLibraries = Self.resolveRecents(bookmarks)
            syncState = try SyncState(root: Self.syncRoot(), libraryID: repository.manifest.id)
            activeSecurityURL?.stopAccessingSecurityScopedResource()
            activeSecurityURL = accessed ? url : nil
            self.repository = repository
            state = .loaded
            isLibraryUnavailable = false
            refreshPendingSync()
            await refreshAll()
            // Ingest-on-open: pull changes made by other Macs and reconcile the
            // folders before the always-on monitor starts (startMonitor is
            // idempotent — runSyncSequence may already have started it).
            await runSyncSequence(manual: false)
            await startMonitor()
        } catch {
            if accessed { url.stopAccessingSecurityScopedResource() }
            if fallbackToWelcome {
                // Auto-reopen on launch: a missing or unopenable last library
                // drops back to the open/create screen instead of the failure
                // screen, with an explanation.
                lastError = "Couldn’t reopen “\(url.lastPathComponent)”: \(error.localizedDescription)"
                state = .welcome
            } else {
                state = .failed(message: error.localizedDescription)
            }
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
            if let facet = facetNavigation.activeFacet {
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

    /// Sidebar click on a facet category (Authors/Series/Tags/Formats).
    /// `nil` selects All Books. Selecting any library view deselects a
    /// connected device — the two selection domains are mutually exclusive.
    func selectCategory(_ type: FacetType?) {
        Task { await devices.select(nil) }
        facetNavigation.selectCategory(type)
        Task { await refreshBooks() }
    }

    /// Middle-column click on a specific value. Re-clicking the same value
    /// toggles it off, back to all books.
    func selectValue(_ value: String?) {
        facetNavigation.selectValue(value)
        Task { await refreshBooks() }
    }

    /// macOS grid-click semantics: plain click replaces, ⌘ toggles, ⇧ selects
    /// the anchor→clicked range. Reads the modifier flags at gesture time.
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

    /// Empty-space click: clear the selection and the range anchor.
    func clearGridSelection() {
        selection = []
        selectionAnchor = nil
    }

    private static func syncRoot() throws -> URL {
        let root = URL.applicationSupportDirectory
            .appending(path: "Book Manager", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func indexDirectory() throws -> URL {
        let root = URL.applicationSupportDirectory
            .appending(path: "Book Manager", directoryHint: .isDirectory)
            .appending(path: "Indexes", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

// MARK: - Delete / restore, Open / reveal

extension LibrarySession {
    // MARK: - Delete / restore

    /// Asks for confirmation before deleting the given books: stores the ids
    /// in `pendingDelete` for the confirmation alert. The actual `delete(ids:)`
    /// runs only after the user confirms.
    func requestDelete(ids: Set<UUID>) {
        guard !ids.isEmpty, !isLibraryUnavailable else { return }
        pendingDelete = ids
    }

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
}

/// Lock-protected boolean so the repository's synchronous `cancelled` closure
/// (called from the repository actor) can read the MainActor session's cancel
/// request without a data race (a stale read only delays cancellation by one
/// book — benign for a rebuild-cancel flag).
final class RebuildCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var requested: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
