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

    /// Rebuild progress (0...1) while `isRebuilding`; nil otherwise.
    private(set) var rebuildProgress: Double?
    /// True while the Diagnostics rebuild is running (drives the progress UI).
    private(set) var isRebuilding = false
    private let cancelFlag = RebuildCancelFlag()

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

    // Device support: the connected-device store and the sidebar selection
    // bridging into it (selecting a device clears the library facet, and vice
    // versa is handled by `selectFacet`).
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
        if id != nil { selectedFacet = nil }
        Task { await devices.select(id) }
    }

    private(set) var books: [IndexedBook] = []
    private(set) var authors: [(value: String, count: Int)] = []
    private(set) var series: [(value: String, count: Int)] = []
    private(set) var tags: [(value: String, count: Int)] = []
    private(set) var formats: [(value: String, count: Int)] = []
    private(set) var deletedBooks: [IndexedBook] = []
    private(set) var missingFiles: [(book: IndexedBook, filename: String)] = []
    var importReport: ImportReport?
    var inspectorBook: IndexedBook?

    // Metadata enrichment state
    private(set) var metadataCandidates: [MetadataCandidate] = []
    /// Presented by the view; the review sheet binds to this.
    var metadataReviewPresented = false
    private(set) var metadataLookupError: String?
    private(set) var metadataBookID: UUID?
    private(set) var isFetchingMetadata = false
    private var metadataService: MetadataLookupService?

    private static let metadataUserAgent = "BookManager/1.0"
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

    // MARK: - Send to device

    /// Resolves each selected book's best stored format file (in the selected
    /// device's format-priority order) and sends them to the device. Books
    /// with no supported stored format get an explicit "no compatible format"
    /// row in the send report.
    func sendSelectionToDevice() async {
        guard let repository else { return }
        let folder = BookFolder(layout: .init(root: repository.root))
        let selectedBooks = books.filter { selection.contains($0.id) }
        var requests: [SendRequest] = []
        var noCompatible: [SendItem] = []
        for book in selectedBooks {
            var hasSupportedFormat = false
            for format in devices.selectedDevice?.profile.supportedFormats ?? [] {
                guard let record = book.formats.first(where: { $0.kind.lowercased() == format }) else {
                    continue
                }
                let url = await folder.formatFileURL(relativePath: book.relativePath, filename: record.filename)
                if FileManager.default.fileExists(atPath: url.path) {
                    requests.append(SendRequest(title: book.title, sourceURL: url, format: format))
                    hasSupportedFormat = true
                    break
                }
            }
            if !hasSupportedFormat {
                noCompatible.append(SendItem(title: book.title, status: .noCompatibleFormat))
            }
        }
        await devices.send(requests, noCompatible: noCompatible)
    }

    /// Sends files dropped onto a sidebar device row (Finder-style drag). Each
    /// URL is sent as-is when its extension is a format the device accepts;
    /// unsupported formats surface as "no compatible format" in the report.
    func sendFiles(urls: [URL]) async {
        var requests: [SendRequest] = []
        for url in urls {
            let format = url.pathExtension.lowercased()
            guard !format.isEmpty else { continue }
            requests.append(SendRequest(
                title: url.deletingPathExtension().lastPathComponent,
                sourceURL: url,
                format: format
            ))
        }
        await devices.send(requests)
    }

    /// The first existing format file for a book, used to make library rows
    /// draggable (drag onto a device row sends that file). Computed directly
    /// from the layout (pure path math, mirrors `BookFolder.formatFileURL`) so
    /// the synchronous drag handler needs no actor hop.
    func formatFileURL(for book: IndexedBook) -> URL? {
        guard let repository else { return nil }
        let root = LibraryLayout(root: repository.root).root
        for format in book.formats {
            let url = root
                .appending(path: book.relativePath, directoryHint: .isDirectory)
                .appending(path: format.filename)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    /// Loads a file URL from a drag/drop item provider. Shared by the library
    /// drop handler and the sidebar device-row drop handler.
    static func loadURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadTransferable(type: URL.self) { result in
                continuation.resume(returning: try? result.get())
            }
        }
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

    func saveEdit(_ edit: BookEdit, coverData: Data?, for id: UUID) async {
        guard let repository else { return }
        guard !isLibraryUnavailable else {
            lastError = "Library unavailable — the library becomes editable again once it reconnects."
            return
        }
        do {
            let updated = try await repository.updateBook(id: id, edit: edit)
            // Best-effort cover: a failure must not undo the metadata save.
            // NOTE: `inspectorBook` is deliberately NOT reassigned here — the
            // editor sheet's presentation is owned by its callers (onSave/
            // onCancel set it to nil to dismiss); reassigning it on save would
            // re-present the sheet. The updated book reaches the UI via
            // `refreshAll()` → `session.books`.
            if let coverData {
                do {
                    _ = try await repository.updateCover(coverData: coverData, for: id)
                } catch {
                    lastError = "Metadata saved; cover update failed: \(error.localizedDescription)"
                }
            }
        } catch {
            // The library folder may be unreachable (volume unmounted, cloud
            // folder offline): queue the edit to the durable outbox and keep
            // the catalog current so browsing reflects it. If even the offline
            // path fails, surface the original error. Covers require the
            // library, so the offline path never takes cover data.
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
            // Same contract as `saveEdit`: do NOT reassign `inspectorBook`
            // (it would re-present the dismissed editor sheet).
        } catch {
            lastError = originalError.localizedDescription
        }
    }

    // MARK: - Metadata enrichment

    /// The metadata lookup service, created once (sources: OpenLibrary then
    /// Google Books). Shared by the inspector's fetch and the editor's
    /// review-first fetch.
    private func lookupService() -> MetadataLookupService {
        if let existing = metadataService {
            return existing
        }
        let client = URLSessionMetadataHTTPClient()
        let registry = MetadataRegistry(sources: [
            OpenLibrarySource(client: client, userAgent: Self.metadataUserAgent),
            GoogleBooksSource(client: client, userAgent: Self.metadataUserAgent),
        ])
        let created = MetadataLookupService(registry: registry)
        metadataService = created
        return created
    }

    private func lookupResult(for book: IndexedBook) async throws -> MetadataLookupResult {
        let query = MetadataLookupQuery(
            isbn: book.identifiers["isbn"], title: book.title, authors: book.authors
        )
        return try await lookupService().lookup(query)
    }

    /// Looks up metadata for a book (ISBN-first, then title+author) and either
    /// auto-applies a high-confidence candidate or presents the review sheet.
    func fetchMetadata(for bookID: UUID) async {
        guard let repository, !isFetchingMetadata else { return }
        guard let book = books.first(where: { $0.id == bookID }) else { return }
        metadataLookupError = nil
        isFetchingMetadata = true
        defer { isFetchingMetadata = false }
        do {
            let result = try await lookupResult(for: book)
            if let autoApply = result.autoApply {
                await applyMetadataCandidate(autoApply, for: bookID, auto: true)
            } else if !result.candidates.isEmpty {
                metadataCandidates = result.candidates
                metadataBookID = bookID
                metadataReviewPresented = true
            } else {
                metadataLookupError = "No metadata found."
            }
        } catch {
            metadataLookupError = error.localizedDescription
        }
    }

    /// Returns candidates for the editor's review-first fetch. Never applies —
    /// even a high-confidence candidate comes back as a candidate so the user
    /// can decide per field. Errors surface via `metadataLookupError`.
    func lookupMetadataCandidates(for bookID: UUID) async -> [MetadataCandidate] {
        guard let repository else { return [] }
        guard let book = books.first(where: { $0.id == bookID }) else { return [] }
        do {
            let result = try await lookupResult(for: book)
            if let autoApply = result.autoApply {
                return [autoApply]
            }
            return result.candidates
        } catch {
            metadataLookupError = error.localizedDescription
            return []
        }
    }

    /// Applies a chosen candidate with missing-fields-only semantics — existing
    /// values are never clobbered — and downloads the cover (bounded) when the
    /// book has none. `auto` suppresses the review-sheet cleanup (nothing to
    /// clear on the auto-apply path).
    func applyMetadataCandidate(_ candidate: MetadataCandidate, for bookID: UUID, auto: Bool = false) async {
        defer {
            if !auto {
                metadataCandidates = []
                metadataBookID = nil
                metadataReviewPresented = false
            }
        }
        guard let repository else { return }
        guard let book = books.first(where: { $0.id == bookID }) else { return }

        var edit = BookEdit()
        var changed = false
        if book.title.isEmpty, !candidate.title.isEmpty {
            edit.title = candidate.title
            changed = true
        }
        if book.authors.isEmpty, !candidate.authors.isEmpty {
            edit.authors = candidate.authors
            changed = true
        }
        if book.publisher == nil, let publisher = candidate.publisher, !publisher.isEmpty {
            edit.publisher = .set(publisher)
            changed = true
        }
        if book.publicationDate == nil, let date = candidate.publicationDate {
            edit.publicationDate = .set(date)
            changed = true
        }
        if book.identifiers["isbn"] == nil, let isbn = candidate.isbn {
            edit.identifiers = book.identifiers.merging(["isbn": isbn]) { _, new in new }
            changed = true
        }
        if changed {
            do {
                _ = try await repository.updateBook(id: bookID, edit: edit)
            } catch {
                lastError = error.localizedDescription
            }
        }

        if book.coverHash == nil, let coverURL = candidate.coverURL {
            do {
                let client = URLSessionMetadataHTTPClient()
                let request = URLRequest(url: coverURL)
                let data = try await withThrowingTaskGroup(of: Data.self) { group in
                    group.addTask { try await client.data(from: request) }
                    group.addTask {
                        try await Task.sleep(for: .seconds(10))
                        throw CancellationError()
                    }
                    guard let data = try await group.next() else {
                        throw CancellationError()
                    }
                    group.cancelAll()
                    return data
                }
                _ = try await repository.updateCover(coverData: data, for: bookID)
            } catch {
                // Best-effort: a cover download failure must not undo the metadata apply.
                metadataLookupError = "Metadata applied; cover download failed."
            }
        }
        await refreshAll()
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
        isRebuilding = true
        rebuildProgress = 0
        defer {
            isRebuilding = false
            rebuildProgress = nil
            cancelFlag.requested = false
        }
        do {
            try await repository.rebuildCatalog(
                progress: { [weak self] value in
                    Task { @MainActor in
                        self?.rebuildProgress = value
                    }
                },
                cancelled: { [cancelFlag] in cancelFlag.requested }
            )
        } catch LibraryRepositoryError.rebuildCancelled {
            lastError = "Rebuild cancelled."
        } catch {
            lastError = error.localizedDescription
        }
        await refreshAll()
    }

    func cancelRebuild() {
        cancelFlag.requested = true
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

/// Lock-protected boolean so the repository's synchronous `cancelled` closure
/// (called from the repository actor) can read the MainActor session's cancel
/// request without a data race (a stale read only delays cancellation by one
/// book — benign for a rebuild-cancel flag).
private final class RebuildCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var requested: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
