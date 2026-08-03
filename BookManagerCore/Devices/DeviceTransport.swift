import Foundation

public struct DeviceFile: Sendable, Equatable, Identifiable {
    public let name: String
    public let path: String
    public let size: Int64

    public init(name: String, path: String, size: Int64) {
        self.name = name
        self.path = path
        self.size = size
    }

    public var id: String { path }
}

public struct DeviceFolder: Sendable, Equatable {
    public let path: String
    public init(path: String) { self.path = path }
}

public struct DeviceInfo: Sendable, Equatable {
    public let name: String
    public let vendorID: UInt16?
    public let productID: UInt16?

    public init(name: String, vendorID: UInt16?, productID: UInt16?) {
        self.name = name
        self.vendorID = vendorID
        self.productID = productID
    }
}

public protocol DeviceTransport: Sendable {
    func connect() async throws -> DeviceInfo
    func listFiles(in folder: DeviceFolder) async throws -> [DeviceFile]
    func download(_ file: DeviceFile, to destination: URL) async throws
    func upload(_ source: URL, to folder: DeviceFolder, as filename: String) async throws
    /// Downloads a file by path relative to the storage ROOT (device-level
    /// files like Calibre's `metadata.calibre` live at root, not inside a
    /// book folder).
    func download(atPath path: String, to destination: URL) async throws
    /// Uploads a file to the storage ROOT, replacing any existing file of the
    /// same name (MTP has no overwrite-by-name, so transports replace).
    func upload(atPath path: String, from source: URL) async throws
    func eject() async throws
    func disconnect() async throws
}
