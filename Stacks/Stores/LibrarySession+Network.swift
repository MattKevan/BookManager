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
        } catch {
            if let remoteError = error as? RemoteLibrary.RemoteError,
               remoteError == .serverError(401) {
                credentialPrompt = discovered
            } else {
                lastError = "Couldn't connect to '\(discovered.name)': \(error.localizedDescription)"
            }
        }
    }

    /// Disconnects the remote and returns the browser context to the home
    /// library.
    func disconnectRemote() {
        remoteBrowser = nil
    }
}
