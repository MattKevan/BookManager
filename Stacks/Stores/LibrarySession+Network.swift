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
        guard !urls.isEmpty else { return }
        await remote.importFiles(urls: urls)
    }

    /// Downloads the selected remote books into the home library: each
    /// book's best format is fetched from the server and imported through
    /// the standard pipeline (metadata extraction + content-hash dedupe).
    func importSelectionFromRemote(_ remote: RemoteLibraryBrowser) async {
        guard let home else { return }
        var urls: [URL] = []
        for book in remote.selectionBooks {
            if let format = book.formats.first,
               let url = try? await remote.remote.downloadFormat(id: book.id, format: format.kind) {
                urls.append(url)
            }
        }
        guard !urls.isEmpty else { return }
        await importFiles(urls: urls)
        presentImportReport()
    }
}
