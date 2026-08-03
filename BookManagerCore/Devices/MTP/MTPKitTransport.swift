import Foundation

/// Discovers MTP devices and builds `MTPKitTransport` instances backed by
/// MTPKit (pure Swift, native IOUSBHost — no libusb, no libmtp).
///
/// The app's default backend (libmtp/libusb was dropped — it is fragile on
/// macOS: "USBInterfaceOpen: another process" and "Unable to find interface
/// & endpoints of device" PANICs; MTPKit speaks MTP directly over IOUSBHost
/// and was measured ~10x faster with stable sessions on the Kindle).
public struct MTPKitTransportFactory: Sendable {
    public init() {}

    /// Enumerates attached MTP devices. MTPKit exposes no non-opening
    /// enumeration API, so this opens and immediately closes the first MTP
    /// device to read its identity. Spike limitation: a held-session or
    /// USB-watcher-driven model belongs to real integration (the app is not
    /// switched to this backend yet, so discovery cadence is not exercised).
    public func candidates() async -> [DeviceInfo] {
        guard let device = await MTPTransport.discover() else { return [] }
        let info = MTPKitTransport.deviceInfo(from: device)
        await device.close()
        return [info]
    }

    public func makeTransport(for info: DeviceInfo) -> any DeviceTransport {
        MTPKitTransport(info: info)
    }
}

/// `DeviceTransport` implementation backed by MTPKit (native IOUSBHost).
/// All I/O runs on this actor; every MTPKit call lives in this file.
///
/// Folder/file lookups search **every storage** via one-level root-children
/// enumeration (case-insensitive directory/file name match) — mirrors the
/// libmtp backend, which deliberately avoids full object-tree walks
/// (~7-15s per walk on Kindle MTP, measured).
public actor MTPKitTransport: DeviceTransport {
    private let requestedInfo: DeviceInfo?
    private var device: MTPTransport?

    public init(info: DeviceInfo?) {
        self.requestedInfo = info
    }

    // MARK: - DeviceTransport

    public func connect() async throws -> DeviceInfo {
        if let device {
            return Self.deviceInfo(from: device)
        }
        guard let found = await MTPTransport.discover() else {
            throw MTPTransportError.noDeviceAttached
        }
        let info = Self.deviceInfo(from: found)
        if let requested = requestedInfo {
            let vendorMatches = requested.vendorID.map { $0 == info.vendorID } ?? true
            let productMatches = requested.productID.map { $0 == info.productID } ?? true
            guard vendorMatches && productMatches else {
                // MTPKit has no deinit: its event-reader thread holds the
                // session and the USB interface stays claimed until close()
                // — leaking it here would make every later connect() fail
                // with interface-in-use.
                await found.close()
                throw MTPTransportError.deviceNotFound
            }
        }
        do {
            _ = try await found.storages()
        } catch {
            await found.close()
            throw MTPTransportError.operationFailed(Self.message(error))
        }
        device = found
        return info
    }

    public func listFiles(in folder: DeviceFolder) async throws -> [DeviceFile] {
        guard let device else { throw MTPTransportError.notConnected }
        do {
            guard let (storage, dir) = try await folderInfo(folder, on: device) else {
                throw MTPTransportError.folderNotFound(folder.path)
            }
            let children = try await device.listChildren(of: dir.id, in: storage.id)
            return children
                .filter { !$0.isDirectory }
                .map {
                    DeviceFile(name: $0.name, path: "\(folder.path)/\($0.name)", size: $0.size)
                }
                .sorted { $0.name < $1.name }
        } catch let error as MTPTransportError {
            throw error
        } catch {
            throw MTPTransportError.operationFailed(Self.message(error))
        }
    }

    public func download(_ file: DeviceFile, to destination: URL) async throws {
        guard let device else { throw MTPTransportError.notConnected }
        do {
            let (_, node) = try await fileInfo(file, on: device)
            try await device.download(node.id, to: destination) { _ in }
        } catch let error as MTPTransportError {
            throw error
        } catch {
            throw MTPTransportError.operationFailed(Self.message(error))
        }
    }

    public func upload(_ source: URL, to folder: DeviceFolder, as filename: String) async throws {
        guard let device else { throw MTPTransportError.notConnected }
        do {
            guard let (storage, dir) = try await folderInfo(folder, on: device) else {
                throw MTPTransportError.folderNotFound(folder.path)
            }
            try await device.upload(localURL: source, as: filename, toParent: dir.id, in: storage.id) { _ in }
        } catch let error as MTPTransportError {
            throw error
        } catch {
            throw MTPTransportError.operationFailed(Self.message(error))
        }
    }

    public func download(atPath path: String, to destination: URL) async throws {
        guard let device else { throw MTPTransportError.notConnected }
        do {
            let name = (path as NSString).lastPathComponent
            guard let (_, node) = try await rootFileInfo(name, on: device) else {
                throw MTPTransportError.fileNotFound(path)
            }
            try await device.download(node.id, to: destination) { _ in }
        } catch let error as MTPTransportError {
            throw error
        } catch {
            throw MTPTransportError.operationFailed(Self.message(error))
        }
    }

    public func upload(atPath path: String, from source: URL) async throws {
        guard let device else { throw MTPTransportError.notConnected }
        do {
            let name = (path as NSString).lastPathComponent
            // MTP has no overwrite-by-name (objects are id-keyed), so replace:
            // delete the existing root file (on whatever storage holds it),
            // then upload fresh at that storage's root.
            if let (storage, existing) = try await rootFileInfo(name, on: device) {
                try await device.delete(existing.id)
                try await device.upload(localURL: source, as: name, toParent: nil, in: storage.id) { _ in }
                return
            }
            guard let storage = try? await device.storages().first else {
                throw MTPTransportError.storageUnavailable
            }
            try await device.upload(localURL: source, as: name, toParent: nil, in: storage.id) { _ in }
        } catch let error as MTPTransportError {
            throw error
        } catch {
            throw MTPTransportError.operationFailed(Self.message(error))
        }
    }

    public func eject() async throws {
        try await disconnect()
    }

    public func disconnect() async throws {
        if let device {
            await device.close()
            self.device = nil
        }
    }

    // MARK: - Helpers

    /// Finds `folder` across all storages by one-level root-children
    /// enumeration (case-insensitive directory name). Mirrors the libmtp
    /// backend; Kindle exposes the book folder as lowercase "documents".
    private func folderInfo(
        _ folder: DeviceFolder,
        on device: MTPTransport
    ) async throws -> (storage: StorageInfo, dir: FileNode)? {
        let storages = (try? await device.storages()) ?? []
        for storage in storages {
            let root = (try? await device.listChildren(of: nil, in: storage.id)) ?? []
            if let dir = root.first(where: {
                $0.isDirectory && $0.name.caseInsensitiveCompare(folder.path) == .orderedSame
            }) {
                return (storage, dir)
            }
        }
        return nil
    }

    /// Finds a file at the storage ROOT across all storages (case-insensitive
    /// name match) — for device-level files like Calibre's `metadata.calibre`.
    private func rootFileInfo(
        _ name: String,
        on device: MTPTransport
    ) async throws -> (storage: StorageInfo, file: FileNode)? {
        let storages = (try? await device.storages()) ?? []
        for storage in storages {
            let root = (try? await device.listChildren(of: nil, in: storage.id)) ?? []
            if let match = root.first(where: {
                !$0.isDirectory && $0.name.caseInsensitiveCompare(name) == .orderedSame
            }) {
                return (storage, match)
            }
        }
        return nil
    }

    /// Finds `file` by walking its containing folder (one-level listings only).
    private func fileInfo(
        _ file: DeviceFile,
        on device: MTPTransport
    ) async throws -> (storage: StorageInfo, node: FileNode) {
        // NSString keeps the path relative ("Documents/x.mobi" → "Documents")
        // so folderInfo can match it case-insensitively; URL would prepend "/".
        let containing = (file.path as NSString).deletingLastPathComponent
        if let (storage, dir) = try await folderInfo(DeviceFolder(path: containing), on: device) {
            let children = (try? await device.listChildren(of: dir.id, in: storage.id)) ?? []
            if let match = children.first(where: { !$0.isDirectory && $0.name == file.name }) {
                return (storage, match)
            }
        }
        throw MTPTransportError.fileNotFound(file.path)
    }

    /// MTPKit's device id is `"usb-%04x-%04x"` (vendor, product); the registry
    /// matches on vendor, so parse it back out.
    static func parsedVendorProduct(_ id: String) -> (vendor: UInt16, product: UInt16)? {
        let parts = id.split(separator: "-")
        guard parts.count == 3, parts[0] == "usb",
              let vendor = UInt16(parts[1], radix: 16),
              let product = UInt16(parts[2], radix: 16) else {
            return nil
        }
        return (vendor, product)
    }

    static func deviceInfo(from device: MTPTransport) -> DeviceInfo {
        let ids = parsedVendorProduct(device.id)
        let name = device.displayName.isEmpty ? "MTP Device" : device.displayName
        return DeviceInfo(name: name, vendorID: ids?.vendor, productID: ids?.product)
    }

    static func message(_ error: Error) -> String {
        if let transport = error as? TransportError {
            switch transport {
            case .notConnected: return "Device is not connected"
            case .notFound(let id): return "Object not found on device: \(id)"
            case .notADirectory(let id): return "Not a directory: \(id)"
            case .operationFailed(let message): return message
            case .cancelled: return "Operation cancelled"
            }
        }
        return error.localizedDescription
    }
}
