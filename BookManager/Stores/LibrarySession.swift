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
    private(set) var pendingSyncCount = 0

    /// Undecodable change files moved to the library quarantine by the last
    /// ingest — surfaced in Diagnostics so nothing silently disappears.
    private(set) var quarantinedChanges: [URL] = []
    /// Read-only gate: the library folder is known unreachable, so editing is
    /// disabled until a reconnect succeeds (approved read-only-when-offline
    /// amendment). Transient mid-session write failures still stage to the
    /// outbox via `saveOffline`.
    private(set) var isLibraryUnavailable = false
    /// True while a sync sequence (drain + ingest + reconcile) is running.
    private(set) var isSyncing = false
    /// The last reconciliation pass's findings — surfaced in Diagnostics so
    /// re-pointed folders and forked conflicts are never silent.
    private(set) var reconciliationReport: ReconciliationReport?
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
    var inspectorPresented = false
    /// True while a grid marquee drag is in flight; suppresses the inspector's
    /// click-driven auto-show so a mid-drag single selection doesn't pop it open.
    var isMarqueeSelecting = false
    var selection = Set<UUID>()
    /// The anchor for ⇧-click range selection in the grid. Ignored by the
    /// table view (which manages its own selection semantics natively).
    private(set) var selectionAnchor: UUID?
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
    private var calibreSourceSecurityURL: URL?
    private var syncState: SyncState?
    private var monitor: LibraryMonitor?
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
        selectedFacet = nil
        searchText = ""
        missingFiles = []
        viewMode = .table
        inspectorPresented = false
        isMarqueeSelecting = false
        importReport = nil
        inspectorBook = nil
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

    /// Stops the Calibre source's security-scoped access and clears all wizard
    /// state. Called when the wizard disappears (Cancel, Done, or Escape);
    /// idempotent.
    func cancelCalibreImport() {
        stopCalibreAccess()
        calibreSummary = nil
        calibreBooks = []
        calibreSelectedIDs = []
        calibreImportReport = nil
        calibreImportInProgress = false
        calibreSourcePath = nil
    }

    private func stopCalibreAccess() {
        calibreSourceSecurityURL?.stopAccessingSecurityScopedResource()
        calibreSourceSecurityURL = nil
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
        // The folder comes from SwiftUI's fileImporter and is security-scoped:
        // the sandbox denies every read of the source (including the
        // metadata.db snapshot copy inside CalibreReader.open) until the scope
        // is started. Hold it for the whole wizard — the import copies book
        // files from this folder later.
        stopCalibreAccess()
        if url.startAccessingSecurityScopedResource() {
            calibreSourceSecurityURL = url
        }
        defer {
            // The wizard never appears on the failure paths: release the scope.
            if calibreSummary == nil { stopCalibreAccess() }
        }
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
            // The source is no longer read after the import completes; a
            // failed import keeps the scope so the wizard's retry can read it.
            stopCalibreAccess()
        } catch {
            lastError = error.localizedDescription
        }
        await refreshAll()
    }

    // MARK: - Editing

    func saveEdit(_ edit: BookEdit, for id: UUID) async {
        guard let repository else { return }
        guard !isLibraryUnavailable else {
            lastError = "Library unavailable — the library becomes editable again once it reconnects."
            return
        }
        do {
            let updated = try await repository.updateBook(id: id, edit: edit)
            inspectorBook = updated
        } catch {
            // The library folder may be unreachable (volume unmounted, cloud
            // folder offline): queue the edit to the durable outbox and keep
            // the catalog current so browsing reflects it. If even the offline
            // path fails, surface the original error.
            await saveOffline(edit, for: id, originalError: error)
        }
        refreshPendingSync()
        await refreshAll()
    }

    private func saveOffline(_ edit: BookEdit, for id: UUID, originalError: Error) async {
        guard let repository, let syncState else {
            lastError = originalError.localizedDescription
            return
        }
        var book = books.first { $0.id == id }
        if book == nil {
            book = try? await repository.book(id: id)
        }
        guard let book else {
            lastError = originalError.localizedDescription
            return
        }
        do {
            let (changes, resolved) = try OfflineBookEdit.apply(
                edit, to: book.snapshot, deviceID: deviceID
            )
            var clock = HybridLogicalClock(nodeID: deviceID)
            for change in changes {
                _ = try syncState.outbox.stage(
                    change: change, bookID: id, deviceID: deviceID, clock: clock.tick()
                )
            }
            let updated = try await repository.upsertResolved(
                resolved, bookID: id, baseSnapshot: book.snapshot, changes: changes
            )
            inspectorBook = updated
        } catch {
            lastError = originalError.localizedDescription
        }
    }

    // MARK: - Sync

    /// The full sync sequence shared by the always-on monitor and the manual
    /// Sync Now button: drain the outbox, ingest changes made by other Macs,
    /// reconcile the book folders, refresh. Overlapping runs are coalesced.
    private func runSyncSequence(manual: Bool) async {
        guard let repository, let syncState else { return }
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        await ensureLibraryFilesDownloaded()
        do {
            let engine = await repository.syncEngine(state: syncState)
            _ = try await engine.drainOutbox()
            let report = try await engine.ingest()
            quarantinedChanges = report.quarantined
        } catch {
            lastError = error.localizedDescription
        }
        do {
            let reconciler = await repository.reconciler()
            reconciliationReport = try await reconciler.reconcile()
        } catch {
            lastError = error.localizedDescription
        }
        refreshLibraryAvailability()
        if isLibraryUnavailable {
            // Read-only: stop the monitor so it does not hammer a dead library.
            stopMonitor()
        } else if monitor == nil {
            await startMonitor()
        }
        refreshPendingSync()
        await refreshAll()
    }

    /// Manual affordance (toolbar button, app activation via
    /// `reconnectIfNeeded`): runs the full sync sequence.
    func syncNow() async {
        await runSyncSequence(manual: true)
    }

    /// Starts the always-on monitor. FSEvents on local volumes; periodic
    /// polling on network/cloud roots where events are unreliable. Idempotent;
    /// the first ingest + reconcile happens in `activate` before this runs.
    private func startMonitor() async {
        guard monitor == nil else { return }
        guard let repository, let syncState, !isLibraryUnavailable else { return }
        let capabilities = LibraryRootCapabilities.probe(repository.root)
        let source: any SyncEventSource
        if capabilities.isNetworkMount || capabilities.isUbiquitous {
            source = PollingSource(interval: .seconds(60)) { [weak self] in
                Task { await self?.monitorEvent() }
            }
        } else {
            source = FSEventSource(root: repository.root) { [weak self] in
                Task { await self?.monitorEvent() }
            }
        }
        let monitor = LibraryMonitor(
            eventSource: source,
            periodic: .seconds(60),
            debounce: .seconds(1),
            onChange: { [weak self] in await self?.runSyncSequence(manual: false) },
            onPeriodic: { [weak self] in await self?.runSyncSequence(manual: true) }
        )
        self.monitor = monitor
        await monitor.start()
    }

    /// Stops and drops the monitor (library closed, or library unavailable).
    private func stopMonitor() {
        guard let monitor else { return }
        self.monitor = nil
        Task { await monitor.stop() }
    }

    /// Event-source hop: the source's closure runs on a background queue and
    /// hands the event to the actor, which debounces it.
    private func monitorEvent() async {
        guard let monitor else { return }
        await monitor.onEvent()
    }

    /// Lightweight reachability probe: the library root directory must be
    /// readable. False when unmounted/unreachable.
    func refreshLibraryAvailability() {
        guard let repository else { return }
        var isDirectory: ObjCBool = false
        isLibraryUnavailable = !FileManager.default.fileExists(
            atPath: repository.root.path, isDirectory: &isDirectory
        ) || !isDirectory.boolValue
    }

    /// Reconnect flow used on app activation: refresh availability, then sync.
    func reconnectIfNeeded() async {
        refreshLibraryAvailability()
        await syncNow()
    }

    private func refreshPendingSync() {
        pendingSyncCount = (try? syncState?.outbox.pendingCount()) ?? 0
    }

    /// iCloud Drive can leave library files as placeholders until requested;
    /// ingest must read real content, so request a download first. The wait is
    /// bounded (Task 4's `ensureDownloaded` loop is caller-bounded by design).
    private func ensureLibraryFilesDownloaded() async {
        guard let repository else { return }
        let capabilities = LibraryRootCapabilities.probe(repository.root)
        guard capabilities.isUbiquitous else { return }
        try? await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                await LibraryRootCapabilities.ensureDownloaded(repository.root)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                throw CancellationError()
            }
            try await group.next()
            group.cancelAll()
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
