import Foundation
import StacksCore

// MARK: - Single-library opening

extension LibrarySession {
    /// The connection whose browser is currently shown. Nil only when nothing
    /// is open — a device selection clears `activeLibraryID`, so the context
    /// resolves to home in device mode.
    var activeLibrary: LibraryConnection? {
        guard let id = activeLibraryID else { return nil }
        return home?.id == id ? home : nil
    }

    /// The one open path: File > Open, Open Recent, Create New, and Change
    /// Home all land here. One library per instance — opening replaces the
    /// current home library (Open Recent switches it); a folder that is
    /// already open is selected instead of reopened. `fallbackToWelcome`
    /// preserves the launch auto-reopen behavior (missing or unopenable last
    /// library → welcome screen). Internal: `activate`
    /// (LibrarySession.swift) routes through it.
    func openRequested(
        at url: URL,
        fallbackToWelcome: Bool = false
    ) async {
        let manifestID: UUID
        do {
            manifestID = try LibraryLayout(root: url).readManifest().id
        } catch {
            handleOpenFailure(error, fallbackToWelcome: fallbackToWelcome, url: url)
            return
        }
        // Already open: select it (the toolbar Open path, a double-click on
        // the same folder, launch-reopen overlapping a manual open).
        if let home, home.id == manifestID {
            activeLibraryID = home.id
            state = .loaded
            return
        }
        // Dedupe against IN-FLIGHT opens too: `LibraryConnection(openAt:)`
        // rebuilds the catalog and syncs before returning, and the MainActor
        // is re-entrant across that await — a second open of the same folder
        // (Open Recent + Cmd+O, a double-click, launch-reopen overlapping a
        // manual open) would otherwise open a second connection and the last
        // one to finish would silently replace the first. Coalesce: the
        // in-flight open selects it when it completes.
        guard pendingOpenLibraryIDs.insert(manifestID).inserted else { return }
        defer { pendingOpenLibraryIDs.remove(manifestID) }
        // Fresh connection: security-scope the URL, open, then swap in.
        let accessed = url.startAccessingSecurityScopedResource()
        do {
            let connection = try await LibraryConnection(
                openAt: url, indexesDirectory: try Self.indexDirectory(), deviceID: deviceID
            )
            // Belt-and-braces re-validation: if the folder became the home
            // connection while this one was opening (any path that bypassed
            // the pending guard above), discard the fresh connection and
            // select the existing one instead of swapping a duplicate in.
            if let home, home.id == connection.id {
                connection.stop()
                if accessed { url.stopAccessingSecurityScopedResource() }
                activeLibraryID = home.id
                state = .loaded
                return
            }
            wire(connection)
            if accessed {
                activeSecurityURL?.stopAccessingSecurityScopedResource()
                activeSecurityURL = url
            }
            // Replace home. The old connection tears down (monitors stop);
            // its persistence entry is dropped so the open set stays one.
            let oldHome = home
            home?.stop()
            home = connection
            if let oldHome { openStore.remove(oldHome.id) }
            activeLibraryID = connection.id
            state = .loaded
            // The connection's init already refreshed; this post-wiring pass
            // guarantees a browse failure after open lands in `state = .failed`
            // (the init ran before the callbacks above were attached).
            await connection.refreshAll()

            // Persistence is best-effort AFTER the connection is committed. A
            // bookmark or open-store failure must not report a successfully
            // opened library as failed, orphan the wired connection, or leave
            // the state machine stuck in .loading — and the URL classes that
            // fail bookmark creation (non-security-scope-capable NAS/offline
            // volumes) are exactly the libraries the offline row exists for.
            do {
                try bookmarks.save(url, for: connection.id)
                recentLibraries = Self.resolveRecents(bookmarks)
                try openStore.save(url, for: connection.id, name: connection.name)
                openStore.setHome(connection.id)
                persistOpenOrder()
            } catch {
                lastError = "Library opened, but it could not be remembered for next launch: \(error.localizedDescription)"
            }
        } catch {
            if accessed { url.stopAccessingSecurityScopedResource() }
            handleOpenFailure(error, fallbackToWelcome: fallbackToWelcome, url: url)
        }
    }

    // MARK: - Wiring

    /// Attaches the session-side callbacks a fresh connection needs. Must run
    /// before the post-wiring refresh so browse failures surface through the
    /// session state machine (mirrors the pre-hub `activate` wiring).
    private func wire(_ connection: LibraryConnection) {
        connection.onLoadFailure = { [weak self] message in
            guard let self else { return }
            // A load failure takes over the screen only when nothing else is
            // open; otherwise it is a dialog so the main library stays visible.
            if self.home == nil {
                self.state = .failed(message: message)
            } else {
                self.lastError = message
            }
        }
        connection.onError = { [weak self] message in
            self?.lastError = message
        }
        connection.onSelectionChange = { [weak self] in
            guard let self else { return }
            Task { await self.devices.select(nil) }
        }
    }

    private func handleOpenFailure(
        _ error: Error,
        fallbackToWelcome: Bool,
        url: URL
    ) {
        if fallbackToWelcome {
            lastError = "Couldn’t reopen “\(url.lastPathComponent)”: \(error.localizedDescription)"
            state = .welcome
        } else {
            // A dialog, never a full-screen takeover: with a library open it
            // stays visible; with nothing open the welcome screen remains and
            // the alert explains the failure.
            lastError = error.localizedDescription
            if home == nil { state = .welcome }
        }
    }

    // MARK: - Persistence

    /// Persists the open library (the home entry, first) so launch reopens
    /// it. `openStore.remove` already cleans a closed library's position;
    /// this re-syncs after switches and closes.
    func persistOpenOrder() {
        openStore.setOrder(home.map { [$0.id] } ?? [])
    }
}
