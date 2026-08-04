import AppKit
import BookManagerCore
import Foundation

// MARK: - Calibre wizard lifecycle

extension LibrarySession {
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

    func stopCalibreAccess() {
        calibreSourceSecurityURL?.stopAccessingSecurityScopedResource()
        calibreSourceSecurityURL = nil
    }
}

// MARK: - Import, send to device, Calibre import

extension LibrarySession {
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
        facetNavigation.clear()
        await devices.select(deviceID)
        await sendFiles(urls: urls)
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
}
