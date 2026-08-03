import BookManagerCore
import Foundation
import Observation

/// Owns the connected-device state for the UI: scans for supported devices,
/// publishes the sidebar list, lists a selected device's books, downloads
/// device files for import, and ejects. All device I/O is async; the store
/// stays on the main actor and drives SwiftUI observation.
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
    /// True while an import (device-file download phase) is in flight; drives
    /// the device-view progress banner.
    private(set) var isImporting = false
    /// Download-phase progress 0...1; nil when not importing.
    private(set) var importProgress: Double?
    /// Last device-layer error (connection, listing, transfer, eject).
    /// Settable by views so import failures can surface on the device screen.
    var deviceError: String?
    /// The most recent send-to-device run; presented by the send-report sheet.
    private(set) var sendReport: SendReport?
    var sendReportPresented = false

    private let registry = DeviceRegistry()
    private let factory = MTPTransportFactory()
    /// Background detection tick (started lazily from the first scan): keeps
    /// the sidebar honest as devices arrive/leave. Session-innocent under the
    /// reuse model — it never disconnects or reconnects anything.
    private var monitorTask: Task<Void, Never>?
    /// The parsed device-side `metadata.calibre` cache for the selected
    /// device, if one exists. Fetched on browse; written back on send so
    /// Calibre and Book Manager stay in sync. MainActor-confined.
    private var metadataCache: CalibreCache?

    /// The connected device the sidebar currently has selected, if any.
    var selectedDevice: ConnectedDevice? {
        guard let id = selectedDeviceID else { return nil }
        return devices.first { $0.id == id }
    }

    /// Sends the given requests to the selected device's Documents folder via
    /// its transport, using the device profile's format support and the
    /// identity converter (v1: native-format copy only). `noCompatible` items
    /// (books with no supported stored format, resolved by the caller) are
    /// appended to the report so the user sees an explicit row for every
    /// selected book. Stores the report and presents it.
    func send(_ requests: [SendRequest], noCompatible: [SendItem] = []) async {
        guard let device = selectedDevice else { return }
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
        let base = metadataCache ?? CalibreCache(jsonData: Data("[]".utf8))
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
    /// device — sessions are never churned. libmtp's documented model is to
    /// hold a device session until unplug (devices can hang after disconnect
    /// and require a replug), so a candidate whose `info` already matches a
    /// connected device is reused as-is: no disconnect, no reconnect, no new
    /// session. Only genuinely new devices get a fresh connect; devices no
    /// longer on the bus are released and removed. Per-candidate isolation: a
    /// candidate that fails to connect (e.g. mid re-enumeration) is skipped,
    /// never aborting the whole scan. Stale sessions self-heal via the
    /// failure-triggered reconnect in `refreshBooks`, not via scan churn.
    func scanForDevices() async {
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
        let candidates = (try? await factory.candidates()) ?? []
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
                let connected = try await transport.connect()
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
        guard !isScanning, !isListing, !isTransferring, !isEnriching else { return }
        // While a device is connected, never enumerate at all — the held
        // session IS the device's presence proof (Calibre's model). Repeated
        // idle enumeration disturbed the device and dropped the link ~30s
        // after the app went idle, while a probe holding the session alone
        // survived 120s+ idle with zero drops. Arrivals are still detected
        // when nothing is connected (devices.isEmpty); removals while
        // connected surface through the op-failure path in `refreshBooks`.
        guard devices.isEmpty else { return }
        await scanForDevices()
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
        guard let id = selectedDeviceID,
              let device = devices.first(where: { $0.id == id }) else { return }
        deviceError = nil
        isListing = true
        defer { isListing = false }
        do {
            deviceBooks = try await DeviceBookScanner(transport: device.transport)
                .list(in: device.profile.bookFolder)
            await applyDeviceCache(to: device)
        } catch {
            // The Kindle re-enumerates on the USB bus; a session held from an
            // earlier scan can go stale between the scan and the click, so the
            // listing fails with a connection error. Remove the stale device
            // from `devices` FIRST (so the reuse-by-info scan doesn't
            // resurrect the stale session), release it, then re-detect with a
            // fresh connection and retry once before surfacing the error.
            let info = device.info
            devices.removeAll { $0.id == device.id }
            try? await device.transport.disconnect()
            await scanForDevices()
            guard let fresh = devices.first(where: { $0.info == info }) else {
                deviceError = "Device disconnected — try scanning again"
                return
            }
            selectedDeviceID = fresh.id
            do {
                deviceBooks = try await DeviceBookScanner(transport: fresh.transport)
                    .list(in: fresh.profile.bookFolder)
                await applyDeviceCache(to: fresh)
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
        guard let id = selectedDeviceID,
              let device = devices.first(where: { $0.id == id }),
              !record.isEnriched,
              let index = deviceBooks.firstIndex(where: { $0.id == record.id }),
              !deviceBooks[index].isEnriched else { return }
        // Guard the detection tick (and any stray scan) away from the download:
        // enumeration mid-transfer drops the connection (hardware-reproduced).
        isEnriching = true
        defer { isEnriching = false }
        let current = deviceBooks[index]
        let result: DeviceBookRecord
        if let enriched = try? await DeviceBookScanner(transport: device.transport)
            .enrich(current) {
            result = enriched
        } else {
            result = DeviceBookRecord(
                file: current.file, title: current.title, authors: [],
                format: current.format, isDRM: false, isEnriched: true
            )
        }
        // Re-check by id: the listing may have been replaced or the row
        // enriched by another call while the download ran.
        guard let freshIndex = deviceBooks.firstIndex(where: { $0.id == record.id }),
              !deviceBooks[freshIndex].isEnriched else { return }
        deviceBooks[freshIndex] = result
    }

    /// Downloads the given device files into a fresh temp directory and
    /// returns the local URLs for the import pipeline. The per-file loop is
    /// inlined (rather than delegating to `DeviceImportService`) so the
    /// progress banner can report book N of M; the core service remains for
    /// tests and stays behaviorally identical.
    func download(_ files: [DeviceFile]) async throws -> [URL] {
        guard let id = selectedDeviceID,
              let device = devices.first(where: { $0.id == id }) else {
            throw DeviceManagerError.noDeviceSelected
        }
        isTransferring = true
        isImporting = true
        importProgress = files.isEmpty ? 1 : 0
        defer {
            isTransferring = false
            isImporting = false
            importProgress = nil
        }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var urls: [URL] = []
        for (index, file) in files.enumerated() {
            let destination = directory.appending(path: file.name)
            try await device.transport.download(file, to: destination)
            urls.append(destination)
            importProgress = Double(index + 1) / Double(files.count)
        }
        return urls
    }

    func eject(_ id: UUID) async {
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

enum DeviceManagerError: Error {
    case noDeviceSelected
}
