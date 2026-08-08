import Foundation
import StacksCore

// MARK: - Remote library connections (Plan 4)

extension LibrarySession {

    /// Connects to a discovered library: creates the remote browser, pulls
    /// once, and makes it the browser context. Anonymous by default; when the
    /// server demands basic auth (401) and stored credentials exist, retries
    /// with them, otherwise surfaces the credential prompt.
    func connect(to discovered: DiscoveredLibrary, credential: RemoteLibrary.Credential? = nil) async {
        // Stored credentials from a previous session: retry before prompting.
        var effective = credential
        if effective == nil, let stored = RemoteCredentials.load(for: discovered.id) {
            effective = RemoteLibrary.Credential(username: stored.username, password: stored.password)
        }
        do {
            let remote = try RemoteLibraryBrowser(discovered: discovered, credential: effective)
            try await remote.refreshBooks()
            // Dedupe: an already-connected server is just re-selected.
            if let existing = remotes.first(where: { $0.id == remote.id }) {
                selectRemote(existing.id)
            } else {
                remotes.append(remote)
                selectRemote(remote.id)
            }
        } catch {
            if let remoteError = error as? RemoteLibrary.RemoteError,
               remoteError == .serverError(401) {
                credentialPrompt = discovered
            } else {
                lastError = "Couldn't connect to '\(discovered.name)': \(error.localizedDescription)"
            }
        }
    }

    /// Manual host:port connection (the Shared section's "Connect to
    /// Server…"): probes `/api/identity` to validate the server and adopt
    /// its real name, then connects through the standard flow — stored
    /// credentials, 401 → credential prompt, offline queue.
    func connectManual(host: String, port: Int, username: String?, password: String?) async {
        var discovered = DiscoveredLibrary(manualHost: host, port: port)
        let credential = username.map { RemoteLibrary.Credential(username: $0, password: password ?? "") }
        do {
            let probe = try RemoteLibrary(configuration: .init(
                baseURL: discovered.baseURL,
                credential: credential,
                queueDirectory: RemoteLibraryBrowser.queueDirectory(libraryID: discovered.id)
            ))
            let identity = try await probe.fetchIdentity()
            discovered.name = identity.name
        } catch let error as RemoteLibrary.RemoteError {
            if case .serverError(401) = error {
                // Passworded server: the connect flow prompts for credentials.
            } else {
                lastError = "Couldn't connect to \(host):\(port): \(error.localizedDescription)"
                return
            }
        } catch {
            lastError = "Couldn't connect to \(host):\(port): \(error.localizedDescription)"
            return
        }
        await connect(to: discovered, credential: credential)
    }

    /// Disconnects a remote (default: the active one) and returns the
    /// browser context to the home library. The server stays listed in the
    /// sidebar while it advertises.
    func disconnectRemote(_ id: UUID? = nil) {
        let target = id ?? activeRemoteID
        guard let target else { return }
        if activeRemoteID == target { activeRemoteID = nil }
        remotes.removeAll { $0.id == target }
    }
}


// MARK: - Server transfer activity (toolbar popover)

/// Live upload/download progress shown in the toolbar activity popover —
/// same Safari-Downloads style as device and Calibre activity.
struct ServerTransferActivity: Equatable {
    enum Direction: Equatable {
        case upload, download
    }

    let direction: Direction
    let serverName: String
    let completed: Int
    let total: Int
    let currentTitle: String?
    /// Per-book failures (title + message); empty when everything landed.
    var failures: [String] = []

    var progress: Double? {
        total > 0 ? Double(completed) / Double(total) : nil
    }

    var title: String {
        switch direction {
        case .upload: "Uploading to \(serverName)"
        case .download: "Downloading from \(serverName)"
        }
    }

    var headlineSymbol: String {
        switch direction {
        case .upload: "arrow.up.doc"
        case .download: "arrow.down.doc"
        }
    }
}

extension LibrarySession {
    /// Uploads book files to a connected server with per-book progress in
    /// the toolbar popover. Unreachable pushes queue durably (counted as
    /// delivered — the offline queue lands them) and hard failures are
    /// collected for the popover.
    func uploadFiles(urls: [URL], to remote: RemoteLibraryBrowser) async {
        guard !urls.isEmpty else { return }
        var failures: [String] = []
        serverTransferActivity = ServerTransferActivity(
            direction: .upload, serverName: remote.name, completed: 0, total: urls.count, currentTitle: nil
        )
        await remote.importFiles(
            urls: urls,
            progress: { [weak self] completed, total, title in
                self?.serverTransferActivity = ServerTransferActivity(
                    direction: .upload, serverName: remote.name,
                    completed: completed, total: total, currentTitle: title, failures: failures
                )
            },
            onFailure: { [weak self] message in
                failures.append(message)
                if var activity = self?.serverTransferActivity {
                    activity.failures = failures
                    self?.serverTransferActivity = activity
                }
            }
        )
    }

    /// Downloads the selected remote books into the home library: each
    /// book's best format is fetched from the server and imported through
    /// the standard pipeline (metadata extraction + content-hash dedupe).
    /// Per-book progress in the toolbar popover; the import report sheet
    /// covers the home-side results.
    func importSelectionFromRemote(_ remote: RemoteLibraryBrowser) async {
        guard let home else { return }
        let books = remote.selectionBooks
        guard !books.isEmpty else { return }
        var failures: [String] = []
        var urls: [URL] = []
        serverTransferActivity = ServerTransferActivity(
            direction: .download, serverName: remote.name, completed: 0, total: books.count, currentTitle: nil
        )
        for (index, book) in books.enumerated() {
            serverTransferActivity = ServerTransferActivity(
                direction: .download, serverName: remote.name,
                completed: index, total: books.count, currentTitle: book.title, failures: failures
            )
            if let format = book.formats.first,
               let url = try? await remote.remote.downloadFormat(id: book.id, format: format.kind) {
                urls.append(url)
            } else {
                failures.append("\(book.title): download failed")
            }
        }
        serverTransferActivity = ServerTransferActivity(
            direction: .download, serverName: remote.name,
            completed: books.count, total: books.count, currentTitle: nil, failures: failures
        )
        await importFiles(urls: urls)
        presentImportReport()
    }
}

// MARK: - Book transfers between home and remote servers

extension LibrarySession {
    /// Uploads the home library's selected books to a connected server
    /// (Kindle-style "send to server"): each book's first stored format is
    /// pushed as an addBook command with staged bytes; the server becomes
    /// the writer. The remote browser refreshes to show the arrivals.
    func sendSelectionToServer(_ remote: RemoteLibraryBrowser) async {
        guard let home else { return }
        var urls: [URL] = []
        for book in home.selectionBooks {
            if let url = home.formatFileURL(for: book) {
                urls.append(url)
            }
        }
        await uploadFiles(urls: urls, to: remote)
    }
}
