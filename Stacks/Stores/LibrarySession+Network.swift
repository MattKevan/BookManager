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
            remoteBrowser = remote
            isRemoteContext = true
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

    /// Disconnects the remote and returns the browser context to the home
    /// library.
    func disconnectRemote() {
        remoteBrowser = nil
        isRemoteContext = false
    }
}
