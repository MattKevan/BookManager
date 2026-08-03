import Foundation

/// Errors surfaced by the MTP transports (MTPKit backend), mapped from the
/// library's typed errors so the app sees stable, readable messages.
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
