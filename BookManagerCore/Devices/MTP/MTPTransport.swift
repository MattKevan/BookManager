import Foundation
import SwiftMTPAsync

/// Errors surfaced by `MTPTransport`, mapped from the library's typed `MTPError`
/// so the app sees stable, readable messages.
public enum MTPTransportError: Error, LocalizedError, Equatable {
    case notInitialized
    case notConnected
    case noDeviceAttached
    case deviceNotFound
    case storageUnavailable
    case folderNotFound(String)
    case fileNotFound(String)
    case operationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notInitialized: "MTP library not initialized"
        case .notConnected: "Device is not connected"
        case .noDeviceAttached: "No device is attached"
        case .deviceNotFound: "Matching device not found"
        case .storageUnavailable: "No storage available on the device"
        case .folderNotFound(let path): "Folder not found on device: \(path)"
        case .fileNotFound(let path): "File not found on device: \(path)"
        case .operationFailed(let message): message
        }
    }
}

/// Discovers MTP devices and builds `MTPTransport` instances for them.
public struct MTPTransportFactory: Sendable {
    public init() {}

    /// Enumerates attached MTP devices. Returns an empty array when none are
    /// attached (never throws for a missing device).
    public func candidates() async throws -> [DeviceInfo] {
        try MTPRuntime.ensureInitialized()
        let devices = try MTP.detectDevices()
        return devices.map {
            DeviceInfo(
                name: $0.product.isEmpty ? "MTP Device" : $0.product,
                vendorID: $0.vendorId.rawValue,
                productID: $0.productId.rawValue
            )
        }
    }

    /// Builds a transport for a detected device. The transport re-detects and
    /// opens the matching device on `connect()`.
    public func makeTransport(for info: DeviceInfo) throws -> any DeviceTransport {
        MTPTransport(vendorID: info.vendorID, productID: info.productID)
    }
}

/// `DeviceTransport` implementation backed by libmtp (via the `SwiftMTPAsync`
/// package). All I/O runs on this actor; every library call lives in this file.
///
/// Folder/file lookups search **every storage** on the device, not just a
/// preferred one — Kindle MTP models can expose `Documents` from a storage
/// whose description doesn't hint at "Kindle"/"Internal".
public actor MTPTransport: DeviceTransport {
    private let vendorID: UInt16?
    private let productID: UInt16?
    private var session: MTPSession?

    public init(vendorID: UInt16?, productID: UInt16?) {
        self.vendorID = vendorID
        self.productID = productID
    }

    // MARK: - DeviceTransport

    public func connect() async throws -> DeviceInfo {
        do {
            try MTPRuntime.ensureInitialized()
        } catch {
            throw MTPTransportError.operationFailed(Self.message(error))
        }
        guard let detected = Self.detectFirst(vendorID: vendorID, productID: productID) else {
            throw MTPTransportError.noDeviceAttached
        }
        var raw = detected
        let newSession: MTPSession
        do {
            newSession = try MTPSession(opening: &raw)
        } catch {
            throw MTPTransportError.operationFailed(Self.message(error))
        }
        session = newSession
        guard !(await newSession.storages()).isEmpty else {
            throw MTPTransportError.storageUnavailable
        }
        let name = newSession.friendlyName
            ?? newSession.modelName
            ?? newSession.manufacturerName
            ?? detected.product
        return DeviceInfo(
            name: name.isEmpty ? "MTP Device" : name,
            vendorID: vendorID,
            productID: productID
        )
    }

    public func listFiles(in folder: DeviceFolder) async throws -> [DeviceFile] {
        guard session != nil else { throw MTPTransportError.notConnected }
        do {
            guard let (storage, dir) = try await folderInfo(folder) else {
                throw MTPTransportError.folderNotFound(folder.path)
            }
            let children = try await storage.contents(of: dir.folder ?? .root)
            return children
                .filter { !$0.isDirectory }
                .map {
                    DeviceFile(name: $0.name, path: "\(folder.path)/\($0.name)", size: Int64($0.size))
                }
                .sorted { $0.name < $1.name }
        } catch let error as MTPTransportError {
            throw error
        } catch {
            throw MTPTransportError.operationFailed(Self.message(error))
        }
    }

    public func download(_ file: DeviceFile, to destination: URL) async throws {
        guard session != nil else { throw MTPTransportError.notConnected }
        do {
            let (storage, info) = try await fileInfo(file)
            try await storage.download(info.id, to: destination) { _, _ in .continue }
        } catch let error as MTPTransportError {
            throw error
        } catch {
            throw MTPTransportError.operationFailed(Self.message(error))
        }
    }

    public func upload(_ source: URL, to folder: DeviceFolder, as filename: String) async throws {
        guard session != nil else { throw MTPTransportError.notConnected }
        do {
            guard let (storage, dir) = try await folderInfo(folder) else {
                throw MTPTransportError.folderNotFound(folder.path)
            }
            try await storage.upload(from: source, to: dir.folder ?? .root, as: filename)
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
        // Dropping the session releases the libmtp device handle
        // (LIBMTP_Release_Device runs in the wrapper's deinit).
        session = nil
    }

    public func download(atPath path: String, to destination: URL) async throws {
        guard session != nil else { throw MTPTransportError.notConnected }
        do {
            let name = (path as NSString).lastPathComponent
            guard let (storage, info) = try await rootFileInfo(name) else {
                throw MTPTransportError.fileNotFound(path)
            }
            try await storage.download(info.id, to: destination) { _, _ in .continue }
        } catch let error as MTPTransportError {
            throw error
        } catch {
            throw MTPTransportError.operationFailed(Self.message(error))
        }
    }

    public func upload(atPath path: String, from source: URL) async throws {
        guard session != nil else { throw MTPTransportError.notConnected }
        do {
            let name = (path as NSString).lastPathComponent
            // MTP has no overwrite-by-name (objects are id-keyed), so a plain
            // upload of a same-named file would leave a duplicate and the next
            // read could hit the stale one. Replace: delete the existing root
            // file (on whatever storage holds it), then upload fresh.
            if let (storage, existing) = try await rootFileInfo(name) {
                try await storage.delete(existing.id)
                try await storage.upload(from: source, to: .root, as: name)
                return
            }
            guard let storage = await storages().first else {
                throw MTPTransportError.storageUnavailable
            }
            try await storage.upload(from: source, to: .root, as: name)
        } catch let error as MTPTransportError {
            throw error
        } catch {
            throw MTPTransportError.operationFailed(Self.message(error))
        }
    }


    // MARK: - Helpers

    private func storages() async -> [Storage] {
        guard let session else { return [] }
        return await session.storages()
    }

    /// Finds `folder` across all storages (by path, then by root-children
    /// directory name). Returns the storage it lives on and its FileInfo.
    private func folderInfo(_ folder: DeviceFolder) async throws -> (storage: Storage, info: FileInfo)? {
        for storage in await storages() {
            if let resolved = try await storage.resolvePath(folder.path), resolved.isDirectory {
                return (storage, resolved)
            }
            let root = (try? await storage.contents(of: .root)) ?? []
            // Kindle exposes the book folder as lowercase "documents" at the
            // storage root; compare case-insensitively against the canonical
            // profile folder name ("Documents").
            if let dir = root.first(where: {
                $0.isDirectory && $0.name.caseInsensitiveCompare(folder.path) == .orderedSame
            }) {
                return (storage, dir)
            }
        }
        return nil
    }

    /// Finds a file at the storage ROOT across all storages (case-insensitive
    /// name match) — used for device-level files like `metadata.calibre`.
    private func rootFileInfo(_ name: String) async throws -> (storage: Storage, info: FileInfo)? {
        for storage in await storages() {
            let root = (try? await storage.contents(of: .root)) ?? []
            if let match = root.first(where: {
                !$0.isDirectory && $0.name.caseInsensitiveCompare(name) == .orderedSame
            }) {
                return (storage, match)
            }
        }
        return nil
    }

    /// Finds `file` across all storages (by path, then by walking its
    /// containing folder).
    private func fileInfo(_ file: DeviceFile) async throws -> (storage: Storage, info: FileInfo) {
        for storage in await storages() {
            if let resolved = try await storage.resolvePath(file.path) {
                return (storage, resolved)
            }
        }
        // URL(fileURLWithPath:) prepends a leading slash ("Documents" →
        // "/Documents") that never matches the device folder; NSString keeps
        // the path relative so folderInfo can match it case-insensitively.
        let containing = (file.path as NSString).deletingLastPathComponent
        if let (storage, dir) = try await folderInfo(DeviceFolder(path: containing)) {
            let children = (try? await storage.contents(of: dir.folder ?? .root)) ?? []
            if let match = children.first(where: { !$0.isDirectory && $0.name == file.name }) {
                return (storage, match)
            }
        }
        throw MTPTransportError.fileNotFound(file.path)
    }

    private static func detectFirst(vendorID: UInt16?, productID: UInt16?) -> DetectedDevice? {
        guard let devices = try? MTP.detectDevices() else { return nil }
        return devices.first { device in
            let vendorMatches = vendorID == nil || device.vendorId.rawValue == vendorID
            let productMatches = productID == nil || device.productId.rawValue == productID
            return vendorMatches && productMatches
        } ?? devices.first
    }

    private static func message(_ error: Error) -> String {
        if let mtp = error as? MTPError {
            switch mtp {
            case .alreadyInitialized: return "MTP library already initialized"
            case .notInitialized: return "MTP library not initialized"
            case .noDeviceAttached: return "No device attached"
            case .connectionFailed: return "USB connection failed"
            case .storageFull: return "Device storage full"
            case .objectNotFound: return "Object not found on device"
            case .operationFailed(let message): return message
            case .pathNotFound(let path): return "Path not found on device: \(path)"
            case .notFileURL(let url): return "Not a file URL: \(url)"
            case .moveNotSupported: return "Device does not support move"
            case .cancelled: return "Operation cancelled"
            case .deviceDisconnected: return "Device disconnected"
            }
        }
        return error.localizedDescription
    }
}

/// One-time initialization of the libmtp wrapper, safe to call repeatedly
/// (the library throws `.alreadyInitialized` on double-init).
enum MTPRuntime {
    static func ensureInitialized() throws(MTPError) {
        if MTP.isInitialized { return }
        do {
            try MTP.initialize()
        } catch .alreadyInitialized {
            // Benign race with another caller initializing concurrently.
        }
    }
}
