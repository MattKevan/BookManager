import StacksCore
import Foundation
import Observation

/// One discrete device operation currently running (or most recently shown).
/// Published by `DeviceManager` so the UI can show the current activity with
/// detail and progress, plus how many operations are queued behind it.
struct DeviceActivity: Identifiable, Equatable {
    enum Kind: Equatable {
        case scan, list, enrich, importBooks, send, eject
    }

    let id: UUID
    let title: String
    var detail: String?
    var progress: Double? // 0...1; nil = indeterminate
    let kind: Kind
}

/// Owns the connected-device state for the UI: scans for supported devices,
/// publishes the sidebar list, lists a selected device's books, downloads
/// device files for import, and ejects. All device I/O is async; the store
/// stays on the main actor and drives SwiftUI observation.
///
/// Every device operation runs through a SERIAL queue (`enqueue`): one
/// operation at a time, in order, with the current operation published as
/// `currentActivity` and the backlog as `pendingCount`. Serialization makes
/// the former ad-hoc "never run X while Y is in flight" flag guards largely
/// redundant and structurally eliminates the concurrency hazards (concurrent
/// enrichs, a monitor tick enumerating mid-transfer, a refresh interrupting
/// an import).
@MainActor
@Observable
final class DeviceManager {
    struct ConnectedDevice: Identifiable {
        let id: UUID
        let name: String
        let info: DeviceInfo
        let profile: any DeviceProfile
        let transport: any DeviceTransport
    }

    private(set) var devices: [ConnectedDevice] = []
    /// Internal setter: LibrarySession delegates its `selectedDeviceID`
    /// property here so the sidebar selection binding can write through it.
    var selectedDeviceID: UUID?
    private(set) var deviceBooks: [DeviceBookRecord] = []
    private(set) var isScanning = false
    private(set) var isListing = false
    /// True while a transfer (import download or send-to-device) is in flight;
    /// the detection tick skips while set so it can never interrupt a transfer.
    private(set) var isTransferring = false
    /// True while a per-book enrich download is in flight; the detection tick
    /// (and any stray scan) skips while set so the bus is never enumerated
    /// mid-transfer.
    private var isEnriching = false
    /// Last device-layer error (connection, listing, transfer, eject).
    /// Settable by views so import failures can surface on the device screen.
    var deviceError: String?
    /// The most recent send-to-device run; presented by the send-report sheet.
    private(set) var sendReport: SendReport?
    var sendReportPresented = false

    // MARK: - Activity queue

    /// The operation currently running, if any. `detail`/`progress` are
    /// updated by the running operation as it progresses.
    private(set) var currentActivity: DeviceActivity?
    /// How many operations are queued behind the current one.
    private(set) var pendingCount = 0
    /// The titles of queued operations, in FIFO order (for the activity
    /// popover's queued list). Kept as a stored property so the popover's
    /// observation updates when the backlog changes.
    private(set) var pendingTitles: [String] = []

    /// True when the queue is non-empty (current op running or ops queued).
    var isBusy: Bool { currentActivity != nil || pendingCount > 0 }

    /// A human-readable connection-status line for the device UI.
    var connectionStatus: String {
        if let error = deviceError { return error }
        if isScanning { return "Scanning for devices…" }
        if let device = selectedDevice ?? devices.first { return "\(device.name) — connected" }
        return "Not connected"
    }

    private struct PendingOp: Sendable {
        let title: String
        let kind: DeviceActivity.Kind
        let work: @MainActor () async -> Void
        let resume: @MainActor () -> Void
    }

    private var pendingOps: [PendingOp] = []
    private var isProcessingOp = false

    /// Appends an operation to the serial queue and waits until it completes.
    /// Callers (public device methods) await the whole operation. The queue is
    /// strictly FIFO and serial: the drain runs the head operation to
    /// completion before starting the next. Internal cross-calls between
    /// operations must use the `performX` methods directly — never `enqueue`
    /// from inside a queued operation (that would deadlock on the queue).
    private func enqueue(
        _ title: String,
        kind: DeviceActivity.Kind,
        _ work: @escaping @MainActor () async -> Void
    ) async {
        await withCheckedContinuation { continuation in
            pendingOps.append(PendingOp(
                title: title, kind: kind, work: work,
                resume: { continuation.resume() }
            ))
            pendingCount = pendingOps.count
            pendingTitles = pendingOps.map(\.title)
            Task { @MainActor in await self.drainQueue() }
        }
    }

    private func drainQueue() async {
        guard !isProcessingOp, !pendingOps.isEmpty else { return }
        isProcessingOp = true
        let op = pendingOps.removeFirst()
        pendingCount = pendingOps.count
        pendingTitles = pendingOps.map(\.title)
        currentActivity = DeviceActivity(
            id: UUID(), title: op.title, detail: nil, progress: nil, kind: op.kind
        )
        await op.work()
        currentActivity = nil
        isProcessingOp = false
        op.resume()
        await drainQueue()
    }

    private let registry = DeviceRegistry()
    private let factory = MTPKitTransportFactory()
    /// Local per-device listing cache (Application Support): shows the last
    /// listing instantly on re-select or relaunch (zero device I/O); the fresh
    /// MTPKit refresh replaces it within ~1s.
    private let localCache = LocalDeviceCache(directory: DeviceManager.deviceCacheDirectory)

    /// Background detection tick (started lazily from the first scan): keeps
    /// the sidebar honest as devices arrive/leave. Session-innocent under the
    /// reuse model — it never disconnects or reconnects anything.
    private var monitorTask: Task<Void, Never>?
    /// The parsed device-side `metadata.calibre` cache for the selected
    /// device, if one exists. Fetched on browse; written back on send so
    /// Calibre and Stacks stay in sync. MainActor-confined.
    private var metadataCache: CalibreCache?

    /// The connected device the sidebar currently has selected, if any.
    var selectedDevice: ConnectedDevice? {
        guard let id = selectedDeviceID else { return nil }
        return devices.first { $0.id == id }
    }

    // MARK: - Operations

    /// Sends the given requests to the selected device's Documents folder via
    /// its transport, using the device profile's format support and the
    /// identity converter (v1: native-format copy only). `noCompatible` items
    /// (books with no supported stored format, resolved by the caller) are
    /// appended to the report so the user sees an explicit row for every
    /// selected book. Stores the report and presents it.
    func send(_ requests: [SendRequest], noCompatible: [SendItem] = []) async {
        await enqueue("Sending to device…", kind: .send) { [weak self] in
            await self?.performSend(requests, noCompatible: noCompatible)
        }
    }

    private func performSend(_ requests: [SendRequest], noCompatible: [SendItem]) async {
        guard let device = selectedDevice else { return }
        currentActivity?.detail = requests.count == 1 ? "1 book" : "\(requests.count) books"
        isTransferring = true
        defer { isTransferring = false }
        let service = DeviceSendService(transport: device.transport)
        let rawItems = await service.send(
            requests, profile: device.profile, converter: IdentityConverter()
        )
        await updateDeviceCache(afterSending: requests, items: rawItems, to: device)
        var items = rawItems
        items.append(contentsOf: noCompatible)
        sendReport = SendReport(items: items)
        sendReportPresented = true
    }

    /// Extends the device's `metadata.calibre` cache with the books that were
    /// just sent (path from the sanitized upload filename, size from the source
    /// file, title/authors from the request), then writes the merged cache
    /// back to the device root. Best-effort: cache and write failures degrade
    /// silently. Only runs on send (per-book enrich is too chatty at ~24s per
    /// MTP op); when the device has no cache yet, a fresh one is seeded from
    /// the sent books so Calibre sees them with correct metadata.
    private func updateDeviceCache(
        afterSending requests: [SendRequest],
        items: [SendItem],
        to device: ConnectedDevice
    ) async {
        guard requests.count == items.count else { return }
        var updates: [CalibreCacheEntry] = []
        for (request, item) in zip(requests, items) {
            guard case .sent(let format) = item.status else { continue }
            let filename = DeviceSendService.filename(for: request, format: format)
            let attrs = try? FileManager.default.attributesOfItem(atPath: request.sourceURL.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            updates.append(CalibreCacheEntry(
                lpath: "\(device.profile.bookFolder.path)/\(filename)",
                size: size,
                title: request.title,
                authors: request.authors,
                mime: nil,
                pages: nil
            ))
        }
        guard !updates.isEmpty else { return }
        // Only extend a cache this session actually READ. When the browse-time
        // download failed (or never ran) `metadataCache` is nil — seeding an
        // empty cache here and uploading it would REPLACE the device's real
        // metadata.calibre, losing Calibre's metadata for every other book on
        // the device. A device with no cache gets no seed (Calibre still reads
        // sent books directly); the cache appears after its first successful
        // browse download.
        guard let base = metadataCache else { return }
        let data = base.mergedData(updating: updates, adding: [])
        let scratch = cacheScratchURL(for: device)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let file = scratch.appending(path: "metadata.calibre")
        guard (try? data.write(to: file)) != nil else { return }
        guard (try? await device.transport.upload(atPath: "metadata.calibre", from: file)) != nil else {
            return
        }
        metadataCache = CalibreCache(jsonData: data)
    }

    /// Re-enumerates the USB bus and keeps ONE held session per connected
    /// device — sessions are never churned. The MTP model is to hold a device
    /// session until unplug (some devices can hang after disconnect and
    /// require a replug — libmtp documented this caveat), so a candidate whose
    /// `info` already matches a connected device is reused as-is: no
    /// disconnect, no reconnect, no new session. Only genuinely new devices
    /// get a fresh connect; devices no longer on the bus are released and
    /// removed. Per-candidate isolation: a candidate that fails to connect
    /// (e.g. mid re-enumeration) is skipped, never aborting the whole scan.
    /// Stale sessions self-heal via the failure-triggered reconnect in
    /// `refreshBooks`, not via scan churn.
    func scanForDevices() async {
        await enqueue("Scanning for devices…", kind: .scan) { [weak self] in
            await self?.performScan()
        }
    }

    private func performScan() async {
        // Serialize scans: `isScanning` is set synchronously before any await,
        // so a second call (activation scan + user refresh) returns immediately
        // instead of opening a second MTP session. Also never enumerate while
        // an MTP operation is in flight (stray callers: app activation can fire
        // this mid-enrich; enumeration disturbs the held session). isListing is
        // deliberately excluded: refreshBooks' failure-retry re-enumerates with
        // the flag set, after its listing op has already thrown — no transfer
        // is in flight at that point, and the retry MUST enumerate to recover.
        guard !isScanning, !isTransferring, !isEnriching else { return }
        // Start the detection tick once, from the first scan.
        if monitorTask == nil {
            monitorTask = Task { [weak self] in
                await self?.monitorLoop()
            }
        }
        isScanning = true
        defer { isScanning = false }
        deviceError = nil
        let candidates = await factory.candidates()
        var kept: [ConnectedDevice] = []
        for info in candidates {
            guard registry.resolve(info) != nil else { continue }
            // Reuse the held session when this device is already connected.
            if let existing = devices.first(where: { $0.info == info }) {
                kept.append(existing)
                continue
            }
            do {
                let transport = try factory.makeTransport(for: info)
                let connected = try await connectWithRetry(transport)
                guard let profile = registry.resolve(connected) else { continue }
                kept.append(ConnectedDevice(
                    id: UUID(), name: connected.name, info: connected,
                    profile: profile, transport: transport
                ))
            } catch {
                // Device unreachable at this instant — skip it, keep scanning.
                continue
            }
        }
        // Release sessions for devices that are no longer on the bus (the one
        // legitimate release: the device is gone).
        for old in devices where !kept.contains(where: { $0.id == old.id }) {
            try? await old.transport.disconnect()
        }
        devices = kept
        if let selected = selectedDeviceID, !devices.contains(where: { $0.id == selected }) {
            selectedDeviceID = nil
            deviceBooks = []
        }
    }

    /// Opens the transport's MTP session with bounded retries. MTP open
    /// failures from interface contention (another app, or the Image Capture
    /// daemon (icdd), holding the interface — libmtp's "LIBMTP PANIC: Unable
    /// to find interface & endpoints of device" class) are documented as
    /// transient and usually clear on a fresh attempt, so retry a few times
    /// with short backoff before giving up on the candidate. Never reaches
    /// already-connected devices: the reuse-by-info path above returns first,
    /// so this only ever opens genuinely new (or freshly re-enumerated)
    /// sessions.
    private func connectWithRetry(_ transport: any DeviceTransport) async throws -> DeviceInfo {
        var lastError: (any Error)?
        for delay in [
            Duration.milliseconds(500),
            Duration.milliseconds(1000),
            Duration.milliseconds(2000)
        ] {
            do {
                return try await transport.connect()
            } catch {
                lastError = error
                // Swallow sleep cancellation: if the scan is being torn down a
                // final attempt is harmless, and never bubbling up keeps the
                // per-candidate isolation intact.
                try? await Task.sleep(for: delay)
            }
        }
        throw lastError ?? DeviceManagerError.connectFailed
    }

    /// Detection loop: re-scans the bus every 10s so the sidebar reflects
    /// device arrival/removal without user action. With the reuse model a tick
    /// is cheap (no session ops when nothing changed) and session-innocent.
    private func monitorLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(10))
            await tick()
        }
    }

    private func tick() async {
        // Never enumerate the bus while a device operation is in flight:
        // libusb enumeration mid-transfer disturbs the held MTP session and
        // drops the connection (hardware-reproduced: clicking a book to enrich
        // downloaded it ~8s while the 10s tick fired, and the device reset).
        // The queue's activity state is the authoritative gate; the legacy
        // flags are kept as belt-and-braces during the transition.
        guard currentActivity == nil, pendingOps.isEmpty,
              !isScanning, !isListing, !isTransferring, !isEnriching else { return }
        // Calibre-exact idle model: with a device connected the tick does
        // NOTHING — the held session is the connection's maintenance (a probe
        // holding the session alone survived 120s+ idle, and idle enumeration
        // dropped the link ~30s after the app went idle). There is no
        // keepalive: swift-mtp's storages() is memory-cached (no USB traffic),
        // so a "keepalive ping" was inert dead code. Drops surface on the next
        // real operation via refreshBooks' failure-retry + the error state.
        if devices.isEmpty {
            // No connected device: enumerate to detect arrivals. Safe — nothing
            // is claimed, so nothing can be disturbed. Runs directly (not via
            // the queue) so background scans don't accumulate queue entries.
            await performScan()
        }
    }

    func select(_ id: UUID?) async {
        // Re-selecting the same device keeps the current listing (MTP scans
        // are slow). Deselecting KEEPS the listing cached in memory so
        // returning to the device shows it instantly instead of re-reading
        // the bus; the listing is only refreshed when there is none (first
        // selection, or after the selected device vanished and reconnected —
        // `scanForDevices` clears deviceBooks in that case).
        guard id != selectedDeviceID || deviceBooks.isEmpty else { return }
        selectedDeviceID = id
        if id != nil && deviceBooks.isEmpty { await refreshBooks() }
    }

    func refreshBooks() async {
        await enqueue("Listing books…", kind: .list) { [weak self] in
            await self?.performRefresh()
        }
    }

    private func performRefresh() async {
        guard let id = selectedDeviceID,
              let device = devices.first(where: { $0.id == id }) else { return }
        // Instant display from the local cache (zero device I/O). The fresh
        // listing below replaces it within ~1s; if the refresh fails, the
        // cached listing stays so the view is never empty.
        if deviceBooks.isEmpty,
           let snapshot = try? localCache.load(key: localCacheKey(for: device)) {
            deviceBooks = snapshot.records.map { $0.asDeviceBookRecord() }
        }
        deviceError = nil
        isListing = true
        defer { isListing = false }
        do {
            deviceBooks = try await DeviceBookScanner(transport: device.transport)
                .list(in: device.profile.bookFolder)
            await applyDeviceCache(to: device)
            saveLocalCache(for: device)
        } catch {
            // The Kindle re-enumerates on the USB bus; a session held from an
            // earlier scan can go stale between the scan and the click, so the
            // listing fails with a connection error. Remove the stale device
            // from `devices` FIRST (so the reuse-by-info scan doesn't
            // resurrect the stale session), release it, then re-detect with a
            // fresh connection and retry once before surfacing the error.
            // Uses `performScan` directly — this retry is inside a queued op,
            // and re-entering the queue here would deadlock.
            let info = device.info
            devices.removeAll { $0.id == device.id }
            try? await device.transport.disconnect()
            await performScan()
            guard let fresh = devices.first(where: { $0.info == info }) else {
                deviceError = "Device disconnected — try scanning again"
                return
            }
            selectedDeviceID = fresh.id
            do {
                deviceBooks = try await DeviceBookScanner(transport: fresh.transport)
                    .list(in: fresh.profile.bookFolder)
                await applyDeviceCache(to: fresh)
                saveLocalCache(for: fresh)
                deviceError = nil
            } catch {
                deviceError = error.localizedDescription
            }
        }
    }

    /// Fetches the device's `metadata.calibre` cache (one root-level download)
    /// and applies it to the current listing: cache hits render instantly with
    /// real titles/authors/DRM and skip the lazy per-row enrich. Best-effort —
    /// no cache on the device degrades to the plain filename listing.
    private func applyDeviceCache(to device: ConnectedDevice) async {
        let scratch = cacheScratchURL(for: device)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let file = scratch.appending(path: "metadata.calibre")
        guard (try? await device.transport.download(atPath: "metadata.calibre", to: file)) != nil,
              let data = try? Data(contentsOf: file) else {
            metadataCache = nil
            return
        }
        let cache = CalibreCache(jsonData: data)
        metadataCache = cache
        if !cache.entries.isEmpty {
            deviceBooks = DeviceBookScanner(transport: device.transport)
                .apply(cache: cache, to: deviceBooks)
        }
    }

    /// Per-device scratch directory holding the downloaded `metadata.calibre`.
    private func cacheScratchURL(for device: ConnectedDevice) -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "bookmanager-cache-\(device.id.uuidString)", directoryHint: .isDirectory)
    }

    /// Lazily fetches full metadata (real title/authors/DRM flag) for one book
    /// by downloading + parsing it, replacing the record in place. Browse shows
    /// the fast filename list; this runs only for the user-selected row (each
    /// MTP op on the Kindle costs ~24s, so the full-pass alternative takes
    /// ~71 minutes for a 178-book device). On failure, degrades to the
    /// filename-only record marked enriched so the UI stops retrying.
    func enrich(_ record: DeviceBookRecord) async {
        await enqueue("Loading book details…", kind: .enrich) { [weak self] in
            await self?.performEnrich(record)
        }
    }

    private func performEnrich(_ record: DeviceBookRecord) async {
        guard let id = selectedDeviceID,
              let device = devices.first(where: { $0.id == id }),
              !record.isEnriched,
              let index = deviceBooks.firstIndex(where: { $0.id == record.id }),
              !deviceBooks[index].isEnriched else { return }
        currentActivity?.detail = record.title
        // Guard the detection tick (and any stray scan) away from the download:
        // enumeration mid-transfer drops the connection (hardware-reproduced).
        isEnriching = true
        defer { isEnriching = false }
        let current = deviceBooks[index]
        let result: DeviceBookRecord
        do {
            result = try await DeviceBookScanner(transport: device.transport).enrich(current)
        } catch {
            // Transport failure (device removed, stale session — the reconnect
            // story this screen already has): surface it and keep the record
            // UN-enriched. Degrading to a fake enriched record here would
            // poison the row with filename-title metadata and stop the UI
            // offering a retry until the next full refresh.
            deviceError = "Couldn't read book details: \(error.localizedDescription)"
            return
        }
        // Re-check by id: the listing may have been replaced or the row
        // enriched by another call while the download ran.
        guard let freshIndex = deviceBooks.firstIndex(where: { $0.id == record.id }),
              !deviceBooks[freshIndex].isEnriched else { return }
        deviceBooks[freshIndex] = result
    }

    /// Downloads the given device files into a fresh temp directory and
    /// returns the local URLs for the import pipeline, then hands them to the
    /// `convert` closure (the library import/conversion phase). The whole
    /// import runs as ONE queued operation so the activity strip shows the
    /// download phase ("Book N of M") and the conversion phase, and no other
    /// device operation can interleave. On download failure the error surfaces
    /// on the device screen.
    /// Returns `true` only when the convert phase actually ran (downloads
    /// succeeded AND `convert` was invoked). `false` when the download failed
    /// or the selected device vanished before the op started — callers must
    /// not present an import report in those cases.
    func importBooks(
        _ files: [DeviceFile],
        then convert: @escaping @MainActor ([URL]) async -> Void
    ) async -> Bool {
        var didConvert = false
        await enqueue("Importing books…", kind: .importBooks) { [weak self] in
            guard let self, let device = self.selectedDevice else { return }
            let directory = FileManager.default.temporaryDirectory
                .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                // Every failure path (download error, cancelled op) leaves the
                // partial downloads behind — sweep the temp dir on exit.
                defer { try? FileManager.default.removeItem(at: directory) }
                var urls: [URL] = []
                for (index, file) in files.enumerated() {
                    self.currentActivity?.detail = "Book \(index + 1) of \(files.count)"
                    self.currentActivity?.progress = Double(index + 1) / Double(files.count)
                    let destination = directory.appending(path: file.name)
                    try await device.transport.download(file, to: destination)
                    urls.append(destination)
                }
                self.currentActivity?.detail = "Converting to library format…"
                self.currentActivity?.progress = nil
                await convert(urls)
                didConvert = true
            } catch {
                self.deviceError = error.localizedDescription
            }
        }
        return didConvert
    }

    enum DeviceManagerError: Error {
        case connectFailed
    }

    func eject(_ id: UUID) async {
        await enqueue("Ejecting…", kind: .eject) { [weak self] in
            await self?.performEject(id)
        }
    }

    private func performEject(_ id: UUID) async {
        guard let device = devices.first(where: { $0.id == id }) else { return }
        do {
            try await device.transport.eject()
            devices.removeAll { $0.id == id }
            if selectedDeviceID == id {
                selectedDeviceID = nil
                deviceBooks = []
                metadataCache = nil
                try? FileManager.default.removeItem(at: cacheScratchURL(for: device))
            }
        } catch {
            deviceError = error.localizedDescription
        }
    }
}

// MARK: - Local listing cache helpers

private extension DeviceManager {
    /// Persists the current listing (after the device-side `metadata.calibre`
    /// cache is applied, so real titles/authors/DRM survive a relaunch) for
    /// instant display next time. Best-effort.
    func saveLocalCache(for device: ConnectedDevice) {
        try? localCache.save(LocalDeviceSnapshot(
            key: localCacheKey(for: device),
            records: deviceBooks.map { LocalCachedBook(record: $0) },
            savedAt: Date()
        ))
    }

    /// Cache key derives from vendor/product ids (DeviceInfo has no serial;
    /// single-device reality). Numeric, so sanitization is a safety net.
    func localCacheKey(for device: ConnectedDevice) -> String {
        "\(device.info.vendorID ?? 0)-\(device.info.productID ?? 0)"
    }

    static var deviceCacheDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appending(path: "Stacks/device-cache", directoryHint: .isDirectory)
    }
}
