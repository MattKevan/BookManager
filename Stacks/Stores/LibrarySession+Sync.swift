import AppKit
import StacksCore
import Foundation

// MARK: - Sync

extension LibrarySession {
    // MARK: - Sync

    /// The full sync sequence shared by the always-on monitor and the manual
    /// Sync Now button: drain the outbox, ingest changes made by other Macs,
    /// reconcile the book folders, refresh. Overlapping runs are coalesced.
    func runSyncSequence(manual: Bool) async {
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
    func startMonitor() async {
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
    func stopMonitor() {
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

    func refreshPendingSync() {
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
}

// MARK: - Diagnostics

extension LibrarySession {
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
}
