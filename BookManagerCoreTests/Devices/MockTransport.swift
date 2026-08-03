import BookManagerCore
import Foundation

actor MockTransport: DeviceTransport {
    static let deviceInfo = DeviceInfo(name: "Mock Kindle", vendorID: 0x1949, productID: 0x9023)

    private var storage: [String: Data] = [:]
    private(set) var ejected = false
    /// Names of every file downloaded via `download(_:to:)` — lets tests assert
    /// the fast browse path performs no downloads.
    private(set) var downloadedNames: [String] = []
    private var forcedError: Error?

    func add(fileNamed name: String, data: Data, in folder: DeviceFolder = DeviceFolder(path: "Documents")) {
        storage["\(folder.path)/\(name)"] = data
    }

    func fileData(named name: String, in folder: DeviceFolder = DeviceFolder(path: "Documents")) -> Data? {
        storage["\(folder.path)/\(name)"]
    }

    func uploadedFiles() -> [String: Data] { storage }

    func uploadError(_ error: Error) { forcedError = error }

    func connect() async throws -> DeviceInfo { Self.deviceInfo }

    func listFiles(in folder: DeviceFolder) async throws -> [DeviceFile] {
        storage.keys
            .filter { $0.hasPrefix("\(folder.path)/") }
            .map { key in
                let name = String(key.dropFirst("\(folder.path)/".count))
                return DeviceFile(name: name, path: key, size: Int64(storage[key]?.count ?? 0))
            }
            .sorted { $0.name < $1.name }
    }

    func download(_ file: DeviceFile, to destination: URL) async throws {
        guard let data = storage[file.path] else { throw DeviceTransportError.fileNotFound(file.path) }
        downloadedNames.append(file.name)
        try data.write(to: destination)
    }

    func upload(_ source: URL, to folder: DeviceFolder, as filename: String) async throws {
        if let forcedError { throw forcedError }
        let data = try Data(contentsOf: source)
        storage["\(folder.path)/\(filename)"] = data
    }

    func eject() async throws { ejected = true }
    func disconnect() async throws {}
}

enum DeviceTransportError: Error, Equatable {
    case fileNotFound(String)
}
