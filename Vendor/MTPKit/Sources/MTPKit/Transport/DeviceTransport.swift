import Foundation

// MARK: - Models

/// How a transport reaches the device. Lets the UI badge connections and lets us
/// pick behaviour (e.g. event-driven vs polling) without leaking protocol details.
public enum TransportKind: String, Sendable {
    case usbMTP
    case wireless
    case mock
}

/// A storage volume on the device (e.g. internal storage, SD card).
///
/// `id` is an opaque, transport-specific token. For MTP it is the StorageID
/// rendered as a string; for a future wireless backend it might be a mount path.
/// Keeping it opaque is what lets `DeviceTransport` stay transport-agnostic.
public struct StorageInfo: Identifiable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var capacityBytes: Int64
    public var freeBytes: Int64

    public init(id: String, name: String, capacityBytes: Int64, freeBytes: Int64) {
        self.id = id
        self.name = name
        self.capacityBytes = capacityBytes
        self.freeBytes = freeBytes
    }

    public var usedBytes: Int64 { max(0, capacityBytes - freeBytes) }
}

/// A file or folder on the device. `id` and `parentID` are opaque tokens with the
/// same meaning as `StorageInfo.id`. A `nil` `parentID` means the node lives at the
/// root of its storage.
public struct FileNode: Identifiable, Hashable, Sendable {
    public let id: String
    public let storageID: String
    public let parentID: String?
    public var name: String
    public var isDirectory: Bool
    public var size: Int64
    public var modifiedDate: Date?
    /// Lowercased file extension when known (e.g. "jpg", "mp4"). Used for icon/kind.
    public var fileExtension: String?

    public init(
        id: String,
        storageID: String,
        parentID: String?,
        name: String,
        isDirectory: Bool,
        size: Int64 = 0,
        modifiedDate: Date? = nil,
        fileExtension: String? = nil
    ) {
        self.id = id
        self.storageID = storageID
        self.parentID = parentID
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modifiedDate = modifiedDate
        self.fileExtension = fileExtension
    }
}

/// A real-time change reported by the device (or simulated by the mock).
///
/// MTP devices emit these over the interrupt endpoint; some Android devices are
/// unreliable, so `reloadNeeded` is the catch-all hint that lets a transport say
/// "something under here changed, re-list it" without enumerating exact deltas.
public enum DeviceChange: Sendable {
    case added(FileNode)
    case removed(id: String)
    case changed(FileNode)
    case storagesChanged
    case reloadNeeded(parentID: String?, storageID: String)
}

/// Progress for a single in-flight transfer. Reported incrementally during
/// `download`/`upload` so the UI can show a determinate bar and throughput.
public struct TransferProgress: Sendable {
    public var fileName: String
    public var completedBytes: Int64
    public var totalBytes: Int64

    public init(fileName: String, completedBytes: Int64, totalBytes: Int64) {
        self.fileName = fileName
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
    }

    public var fractionCompleted: Double {
        totalBytes > 0 ? min(1, Double(completedBytes) / Double(totalBytes)) : 0
    }
}

public enum TransportError: Error, Sendable {
    case notConnected
    case notFound(id: String)
    case notADirectory(id: String)
    case operationFailed(String)
    case cancelled
}

public typealias ProgressHandler = @Sendable (TransferProgress) -> Void

// MARK: - DeviceTransport

/// The single abstraction every connection type implements. The UI and view models
/// talk only to this protocol, so a USB/MTP backend and a future wireless/ADB
/// backend are interchangeable. All methods are `async` because the underlying I/O
/// (USB bulk transfers, network) is inherently asynchronous and serialized.
public protocol DeviceTransport: Sendable {
    /// Stable identifier for this connected device (for sidebar identity, reconnection).
    var id: String { get }
    /// Human-readable name shown in the sidebar (e.g. "Pixel 8").
    var displayName: String { get }
    var kind: TransportKind { get }

    /// Volumes available on the device.
    func storages() async throws -> [StorageInfo]

    /// List the immediate children of `parentID` within `storageID`. Pass `parentID == nil`
    /// to list the storage root.
    func listChildren(of parentID: String?, in storageID: String) async throws -> [FileNode]

    /// Fetch fresh metadata for a single node (used after change events that only carry an id).
    func metadata(for id: String) async throws -> FileNode

    /// Stream the node's bytes to `destinationURL`, reporting progress.
    func download(_ id: String, to destinationURL: URL, progress: @escaping ProgressHandler) async throws

    /// Stream a local file onto the device under `parentID`/`storageID`, reporting progress.
    /// Returns the newly created node.
    @discardableResult
    func upload(
        localURL: URL,
        as name: String,
        toParent parentID: String?,
        in storageID: String,
        progress: @escaping ProgressHandler
    ) async throws -> FileNode

    @discardableResult
    func createDirectory(named name: String, inParent parentID: String?, in storageID: String) async throws -> FileNode

    func delete(_ id: String) async throws

    @discardableResult
    func rename(_ id: String, to newName: String) async throws -> FileNode

    func move(_ id: String, toParent newParentID: String?, in storageID: String) async throws

    /// Real-time change feed. A single consumer (the active browser view model) iterates this.
    var changes: AsyncStream<DeviceChange> { get }
}

public extension DeviceTransport {
    /// Cheap "what handles are in this folder" query used by the polling fallback to
    /// detect device-side adds/removes without fetching full metadata for every child.
    /// Default maps over `listChildren`; transports can override with something cheaper.
    func childIDs(of parentID: String?, in storageID: String) async throws -> Set<String> {
        Set(try await listChildren(of: parentID, in: storageID).map(\.id))
    }
}
