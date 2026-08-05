import AppKit
import StacksCore
import Foundation

/// Live Calibre activity surfaced in the toolbar activity popover — the scan
/// phases while the source is read, then per-book import progress with the
/// current book and the last outcome. Enough detail to see the import is
/// advancing, not frozen.
struct CalibreImportActivity: Equatable {
    enum Phase: Equatable {
        case scanning(CalibreScanPhase)
        case importing(completed: Int, total: Int)
    }

    let phase: Phase
    /// Book currently being processed (import only).
    let currentTitle: String?
    /// Outcome after a book is decided; nil while processing.
    let detail: String?

    /// 0...1 determinate progress; nil during the scan (indeterminate).
    var progress: Double? {
        if case .importing(let completed, let total) = phase, total > 0 {
            return Double(completed) / Double(total)
        }
        return nil
    }

    /// Headline shown above the progress.
    var title: String {
        switch phase {
        case .scanning(.copyingDatabase): "Copying Calibre database…"
        case .scanning(.readingBooks): "Reading Calibre books…"
        case .importing(let completed, let total): "Importing \(completed) of \(total)"
        }
    }
}

// MARK: - Calibre wizard lifecycle

extension LibrarySession {
    /// Stops the Calibre source's security-scoped access and clears all wizard
    /// state. Called when the wizard disappears (Cancel, Done, or Escape);
    /// idempotent.
    func cancelCalibreImport() {
        stopCalibreAccess()
        try? calibreReader?.close()
        calibreReader = nil
        calibreSummary = nil
        calibreBooks = []
        calibreSelectedIDs = []
        calibreImportReport = nil
        calibreImportInProgress = false
        calibreImportProgress = nil
        calibreActivity = nil
        lastCalibreLiveRefresh = nil
        calibreSourcePath = nil
    }

    func stopCalibreAccess() {
        calibreSourceSecurityURL?.stopAccessingSecurityScopedResource()
        calibreSourceSecurityURL = nil
    }
}

// MARK: - Import, send to device, Calibre import

extension LibrarySession {
    // MARK: - Import

    func importFiles(urls: [URL]) async {
        guard let repository = connection?.repository else { return }
        let service = ImportService(layout: .init(root: repository.root))
        do {
            importReport = try await service.importFiles(urls, into: repository)
        } catch {
            importReport = ImportReport(items: [
                ImportItem(sourceURL: urls.first ?? URL(fileURLWithPath: "/"), kind: .epub, status: .failed(error.localizedDescription))
            ])
        }
        await refreshAll()
        // Enrich freshly imported books that are missing authors/tags, when
        // the preference is on. Runs off the import's critical path so the
        // report feedback is not delayed by network lookups.
        if AppSettings.automaticallyFetchMissingMetadata() {
            let importedIDs = (importReport?.imported ?? []).compactMap { item -> UUID? in
                if case let .imported(id) = item.status { return id }
                return nil
            }
            if !importedIDs.isEmpty {
                Task { await self.enrichBooksMissingMetadata(importedIDs) }
            }
        }
    }

    // MARK: - Library transfers (copy to home / copy to library / drag-drop)

    /// Resolves the selected books' first stored format file and imports them
    /// into the target library through the standard pipeline (staged,
    /// content-hash dedup, report). Transfers are copies between two different
    /// libraries — never a merge.
    private func importBooks(
        _ books: [IndexedBook],
        from source: LibraryConnection,
        into target: LibraryConnection
    ) async {
        var urls: [URL] = []
        for book in books {
            if let url = source.formatFileURL(for: book) { urls.append(url) }
        }
        guard !urls.isEmpty else { return }
        let service = ImportService(layout: .init(root: target.repository.root))
        do {
            importReport = try await service.importFiles(urls, into: target.repository)
        } catch {
            importReport = ImportReport(items: [
                ImportItem(sourceURL: urls.first ?? URL(fileURLWithPath: "/"), kind: .epub,
                           status: .failed(error.localizedDescription))
            ])
        }
        await target.refreshBooks()
    }

    /// Peer context: copy the peer's selection into home (download direction).
    func copySelectionFromPeerToHome(_ peer: LibraryConnection) async {
        guard let home else { return }
        await importBooks(peer.selectionBooks, from: peer, into: home)
        presentImportReport()
    }

    /// Home context: copy the home selection into the chosen peer (upload
    /// direction — writes book files + CRDT changes into the peer's folder,
    /// which any other instance connected to it ingests on its next sync).
    func copyHomeSelection(to peer: LibraryConnection) async {
        guard let home else { return }
        await importBooks(home.selectionBooks, from: home, into: peer)
        presentImportReport()
    }

    /// Raw-file import into a specific library (drag-drop onto a peer row, or
    /// the library browser drop handler). Same pipeline as Add Books, targeted
    /// at the target's repository.
    func importFiles(into target: LibraryConnection, urls: [URL]) async {
        guard !urls.isEmpty else { return }
        let service = ImportService(layout: .init(root: target.repository.root))
        do {
            importReport = try await service.importFiles(urls, into: target.repository)
        } catch {
            importReport = ImportReport(items: [
                ImportItem(sourceURL: urls.first ?? URL(fileURLWithPath: "/"), kind: .epub,
                           status: .failed(error.localizedDescription))
            ])
        }
        await target.refreshBooks()
        presentImportReport()
    }

    /// Posts a system notification for the completed import; falls back to the
    /// import-report sheet (`importReportPresented`) when notifications are
    /// not authorized. Moved from ContentView so any view can trigger it.
    func presentImportReport() {
        guard let report = importReport else { return }
        Task {
            if await !SystemNotifier.postImportCompletion(report: report) {
                importReportPresented = true
            }
        }
    }

    // MARK: - Send to device

    /// Resolves each selected book's best stored format file (in the selected
    /// device's format-priority order) and sends them to the device. Books
    /// with no supported stored format get an explicit "no compatible format"
    /// row in the send report.
    func sendSelectionToDevice() async {
        guard let repository = connection?.repository else { return }
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
                    requests.append(SendRequest(title: book.title, authors: book.authors, sourceURL: url, format: format))
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

    /// Finder-style drag from a sidebar device row: clear the library
    /// selection, select the target device, then send the dropped files.
    /// Awaiting the device selection ensures the send targets the right
    /// device.
    func sendDroppedFiles(urls: [URL], to deviceID: UUID) async {
        // Mutate the connection's facet state in place — the session shim
        // returns a copy, so a plain `facetNavigation.clear()` would be dropped.
        connection?.facetNavigation.clear()
        await devices.select(deviceID)
        await sendFiles(urls: urls)
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

        // Scan off the main actor: CalibreReader.open copies the whole
        // metadata.db (Calibre embeds cover blobs — hundreds of MB for large
        // libraries) and books() hydrates every cover, both far too heavy for
        // the main thread (the old synchronous path beachballed). Only the
        // state assignment below hops back to the main actor. Activity is
        // surfaced through the toolbar popover so the scan's progress is
        // visible.
        calibreActivity = CalibreImportActivity(
            phase: .scanning(.copyingDatabase), currentTitle: nil, detail: nil
        )
        let scanned: CalibreScanResult?
        do {
            scanned = try await Task.detached(priority: .userInitiated) {
                try CalibreLibraryScanner.scan(libraryURL: url) { [weak self] phase in
                    Task { @MainActor in
                        self?.calibreActivity = CalibreImportActivity(
                            phase: .scanning(phase), currentTitle: nil, detail: nil
                        )
                    }
                }
            }.value
        } catch {
            lastError = error.localizedDescription
            calibreSummary = nil
            calibreBooks = []
            calibreSourcePath = nil
            calibreActivity = nil
            calibreReader = nil
            return
        }
        // The reader stays open so the import can fetch deferred blob covers
        // (coverData(for:)); it is closed on cancel or after a successful import.
        calibreReader = scanned?.reader
        calibreSummary = scanned?.summary
        calibreBooks = scanned?.books ?? []
        calibreSelectedIDs = Set((scanned?.books ?? []).map(\.calibreID))
        calibreImportReport = nil
        calibreSourcePath = url.standardizedFileURL.path
        calibreActivity = nil
    }

    func importCalibre() async {
        guard let repository = connection?.repository, let summary = calibreSummary,
              let sourcePath = calibreSourcePath else { return }
        calibreImportInProgress = true
        calibreImportProgress = 0
        lastCalibreLiveRefresh = nil
        defer {
            calibreImportInProgress = false
            calibreImportProgress = nil
            calibreActivity = nil
        }
        let service = CalibreImportService(layout: .init(root: repository.root))
        // The scan deferred blob covers; the import fetches them per book from
        // the still-open reader (a Sendable value — captured directly so the
        // background call does not touch the main actor).
        let reader = calibreReader
        do {
            calibreImportReport = try await service.importBooks(
                calibreBooks,
                from: sourcePath,
                libraryID: summary.libraryID,
                selection: Array(calibreSelectedIDs),
                into: repository,
                progress: { [weak self] update in
                    Task { @MainActor in
                        guard let self else { return }
                        self.calibreImportProgress = update.fraction
                        self.calibreActivity = CalibreImportActivity(
                            phase: .importing(completed: update.completed, total: update.total),
                            currentTitle: update.currentTitle,
                            detail: update.detail
                        )
                        self.scheduleCalibreLiveRefresh()
                    }
                },
                coverProvider: { [reader] calibreID in
                    try reader?.coverData(for: calibreID)
                }
            )
            // The source is no longer read after the import completes; a
            // failed import keeps the scope and reader so the wizard's retry
            // can read it.
            stopCalibreAccess()
            try? calibreReader?.close()
            calibreReader = nil
        } catch {
            lastError = error.localizedDescription
        }
        await refreshAll()
    }

    /// Live library updates during the import: refresh the visible books at
    /// most every half second, so the browser fills in as books land without
    /// re-reading the whole catalog on every book.
    private func scheduleCalibreLiveRefresh() {
        let now = Date()
        if let last = lastCalibreLiveRefresh, now.timeIntervalSince(last) < 0.5 {
            return
        }
        lastCalibreLiveRefresh = now
        Task { await connection?.refreshBooks() }
    }
}
