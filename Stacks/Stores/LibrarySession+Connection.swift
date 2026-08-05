import Foundation
import StacksCore

// MARK: - Hub: home library + open peer libraries

extension LibrarySession {
    /// The connection whose browser is currently shown: home or an open peer.
    /// Nil only when nothing is open — a device selection clears
    /// `activeLibraryID`, so the context resolves to home in device mode.
    var activeLibrary: LibraryConnection? {
        guard let id = activeLibraryID else { return nil }
        if let home, home.id == id { return home }
        return peers.first { $0.id == id }
    }

    // MARK: - Opening

    /// File > Open and Open Recent land here: the first library becomes home;
    /// every later one becomes a peer (never switches home).
    func openLibraryAsPeer(at url: URL) async {
        await openRequested(at: url, intent: (home == nil) ? .home : .peer)
    }

    /// Settings > Change Home lands here (Task 8 UI); the policy already
    /// handles the role-swap when the target is an open peer.
    func openLibraryAsHome(at url: URL) async {
        await openRequested(at: url, intent: .home)
    }

    /// The single open path: dedupe against open connections via
    /// `LibraryOpenPolicy`, then open a fresh connection (or select/swap the
    /// existing one). `fallbackToWelcome` preserves the launch auto-reopen
    /// behavior (missing or unopenable last library → welcome screen).
    /// Internal: `activate` (LibrarySession.swift) routes through it.
    func openRequested(
        at url: URL,
        intent: OpenIntent,
        fallbackToWelcome: Bool = false
    ) async {
        let manifestID: UUID
        do {
            manifestID = try LibraryLayout(root: url).readManifest().id
        } catch {
            handleOpenFailure(error, intent: intent, fallbackToWelcome: fallbackToWelcome, url: url)
            return
        }
        let existing = ([home] + peers).compactMap { $0 }
            .map { ExistingLibrary(id: $0.id, isHome: $0 === home) }
        switch LibraryOpenPolicy.resolve(existing: existing, manifestID: manifestID, intent: intent) {
        case .selectExisting(let id):
            activeLibraryID = id
            if let peer = peers.first(where: { $0.id == id }) {
                peer.facetNavigation.clear()
                await peer.refreshBooks()
            }
            state = .loaded
            return
        case .makeHomeExisting(let id):
            changeHome(to: id)
            state = .loaded
            return
        case .openNew:
            break
        }
        // Fresh connection: security-scope the URL, open, then append.
        let accessed = url.startAccessingSecurityScopedResource()
        do {
            let connection = try await LibraryConnection(
                openAt: url, indexesDirectory: try Self.indexDirectory(), deviceID: deviceID
            )
            wire(connection)
            if accessed {
                activeSecurityURL?.stopAccessingSecurityScopedResource()
                activeSecurityURL = url
            }
            try bookmarks.save(url, for: connection.id)
            recentLibraries = Self.resolveRecents(bookmarks)
            if intent == .home, home == nil {
                home = connection
            } else {
                peers.append(connection)
            }
            try openStore.save(url, for: connection.id, name: connection.name)
            if home === connection { openStore.setHome(connection.id) }
            persistOpenOrder()
            activeLibraryID = connection.id
            state = .loaded
            // The connection's init already refreshed; this post-wiring pass
            // guarantees a browse failure after open lands in `state = .failed`
            // (the init ran before the callbacks above were attached).
            await connection.refreshAll()
        } catch {
            if accessed { url.stopAccessingSecurityScopedResource() }
            handleOpenFailure(error, intent: intent, fallbackToWelcome: fallbackToWelcome, url: url)
        }
    }

    // MARK: - Closing / role swap

    /// Closes one open peer: full teardown, removal from the list, and the
    /// browser context re-points at home (or promotes a peer when home is
    /// gone — defensive; home is normally present whenever peers exist).
    func closePeer(_ peer: LibraryConnection) async {
        peer.stop()
        peers.removeAll { $0.id == peer.id }
        openStore.remove(peer.id)
        if activeLibraryID == peer.id { activeLibraryID = home?.id }
        if home == nil { await promoteNextPeerToHome() }
    }

    /// Role swap: the peer becomes home, the old home becomes a peer. No-op
    /// when `libraryID` is already home or names no open peer. Minimal safe
    /// behavior for Task 4 (reached via `openLibraryAsHome`'s
    /// makeHomeExisting policy path); Task 8 completes persistence
    /// (`OpenLibraryStore`) and the Make Home UI.
    func changeHome(to libraryID: UUID) {
        guard libraryID != home?.id else { return }
        guard let peer = peers.first(where: { $0.id == libraryID }) else { return }
        peers.removeAll { $0.id == libraryID }
        if let oldHome = home {
            peers.insert(oldHome, at: 0)
        }
        home = peer
        activeLibraryID = libraryID
    }

    /// When the home connection is closed and peers remain, the first peer
    /// becomes home; when none remain, the welcome screen returns. Minimal
    /// safe behavior for Task 4 (no persistence); Task 8 completes it.
    func promoteNextPeerToHome() async {
        if let first = peers.first {
            peers.removeAll { $0.id == first.id }
            home = first
            activeLibraryID = first.id
            state = .loaded
        } else if home == nil {
            state = .welcome
        }
    }

    // MARK: - Wiring

    /// Attaches the session-side callbacks a fresh connection needs. Must run
    /// before the post-wiring refresh so browse failures surface through the
    /// session state machine (mirrors the pre-hub `activate` wiring).
    private func wire(_ connection: LibraryConnection) {
        connection.onLoadFailure = { [weak self] message in
            self?.state = .failed(message: message)
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
        intent: OpenIntent,
        fallbackToWelcome: Bool,
        url: URL
    ) {
        if fallbackToWelcome {
            lastError = "Couldn’t reopen “\(url.lastPathComponent)”: \(error.localizedDescription)"
            state = .welcome
        } else if intent == .home && home == nil {
            state = .failed(message: error.localizedDescription)
        } else {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Persistence

    /// Persists the current open-set order (home first) so launch can reopen
    /// the same set. `openStore.remove` already cleans a closed library's
    /// position; this re-syncs after role changes and home closes.
    func persistOpenOrder() {
        openStore.setOrder(([home?.id] + peers.map(\.id)).compactMap { $0 })
    }

    // MARK: - Sidebar selection routing

    /// Routes a sidebar sub-section click to the target library: home rows
    /// arrive here through `selectCategory`; peer rows carry the peer's id.
    /// Sets the browser context, clears device selection, applies the
    /// sub-section to that library's facet navigation, and refreshes it.
    func selectLibrarySubsection(_ item: (UUID, LibrarySubsection)) {
        let (libraryID, subsection) = item
        let connection = ([home] + peers).compactMap { $0 }.first { $0.id == libraryID }
        guard let connection else { return }
        activeLibraryID = libraryID
        Task { await devices.select(nil) }
        switch subsection {
        case .allBooks:
            connection.facetNavigation.clear()
        case let .category(type):
            connection.facetNavigation.selectCategory(type)
        }
        Task { await connection.refreshBooks() }
    }

    // MARK: - Drag-drop import into a peer

    /// Resolves dropped file URLs and imports them into `peer` via the
    /// existing import pipeline (Finder-style drag onto a peer sidebar row).
    func importDroppedFiles(providers: [NSItemProvider], into peer: LibraryConnection) async {
        var urls: [URL] = []
        for provider in providers {
            if let url = await LibrarySession.loadURL(from: provider) {
                urls.append(url)
            }
        }
        guard !urls.isEmpty else { return }
        await importFiles(into: peer, urls: urls)
    }
}
