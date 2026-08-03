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
    /// Last device-layer error (connection, listing, transfer, eject).
    /// Settable by views so import failures can surface on the device screen.
    var deviceError: String?
    /// The most recent send-to-device run; presented by the send-report sheet.
    private(set) var sendReport: SendReport?
    var sendReportPresented = false

    private let registry = DeviceRegistry()
    private let factory = MTPTransportFactory()

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
        let service = DeviceSendService(transport: device.transport)
        var items = await service.send(
            requests, profile: device.profile, converter: IdentityConverter()
        )
        items.append(contentsOf: noCompatible)
        sendReport = SendReport(items: items)
        sendReportPresented = true
    }

    /// Re-enumerates the USB bus, keeps devices the registry still resolves,
    /// connects new ones, and drops ones that vanished. Clears the selection
    /// if the selected device is gone.
    func scanForDevices() async {
        isScanning = true
        defer { isScanning = false }
        deviceError = nil
        do {
            let candidates = try await factory.candidates()
            var fresh: [ConnectedDevice] = []
            for info in candidates {
                guard registry.resolve(info) != nil else { continue }
                if let existing = devices.first(where: { $0.info == info }) {
                    fresh.append(existing)
                } else {
                    let transport = try factory.makeTransport(for: info)
                    let connected = try await transport.connect()
                    guard let profile = registry.resolve(connected) else { continue }
                    fresh.append(ConnectedDevice(
                        id: UUID(), name: connected.name, info: connected,
                        profile: profile, transport: transport
                    ))
                }
            }
            devices = fresh
            if let selected = selectedDeviceID, !devices.contains(where: { $0.id == selected }) {
                selectedDeviceID = nil
                deviceBooks = []
            }
        } catch {
            deviceError = error.localizedDescription
        }
    }

    func select(_ id: UUID?) async {
        // Re-selecting the same device keeps the current listing (MTP scans
        // are slow); deselecting clears it without a scan.
        guard id != selectedDeviceID || deviceBooks.isEmpty else { return }
        selectedDeviceID = id
        deviceBooks = []
        if id != nil { await refreshBooks() }
    }

    func refreshBooks() async {
        guard let id = selectedDeviceID,
              let device = devices.first(where: { $0.id == id }) else { return }
        deviceError = nil
        isListing = true
        defer { isListing = false }
        do {
            deviceBooks = try await DeviceBookScanner(transport: device.transport)
                .scan(in: device.profile.bookFolder)
        } catch {
            deviceError = error.localizedDescription
        }
    }

    /// Downloads the given device files into a fresh temp directory and
    /// returns the local URLs for the import pipeline.
    func download(_ files: [DeviceFile]) async throws -> [URL] {
        guard let id = selectedDeviceID,
              let device = devices.first(where: { $0.id == id }) else {
            throw DeviceManagerError.noDeviceSelected
        }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try await DeviceImportService(transport: device.transport).download(files, to: directory)
    }

    func eject(_ id: UUID) async {
        guard let device = devices.first(where: { $0.id == id }) else { return }
        do {
            try await device.transport.eject()
            devices.removeAll { $0.id == id }
            if selectedDeviceID == id { selectedDeviceID = nil; deviceBooks = [] }
        } catch {
            deviceError = error.localizedDescription
        }
    }
}

enum DeviceManagerError: Error {
    case noDeviceSelected
}
