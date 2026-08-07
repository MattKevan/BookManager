import Foundation
import StacksCore

// MARK: - Remote library connections (Plan 4)

extension LibrarySession {
    /// Connects to a discovered library: creates the remote browser, pulls
    /// once, and makes it the browser context. Anonymous for v1 — passworded
    /// servers surface a connection error (client-side credential prompt is a
    /// follow-up).
    func connect(to discovered: DiscoveredLibrary) async {
        do {
            let remote = try RemoteLibraryBrowser(discovered: discovered, credential: nil)
            try await remote.refreshBooks()
            remoteBrowser = remote
        } catch {
            lastError = "Couldn't connect to '\(discovered.name)': \(error.localizedDescription)"
        }
    }

    /// Disconnects the remote and returns the browser context to the home
    /// library.
    func disconnectRemote() {
        remoteBrowser = nil
    }
}
