import Foundation

public protocol DeviceProfile: Sendable {
    var id: String { get }
    var displayName: String { get }
    /// Lowercase file extensions, highest priority first (used by SendPlan).
    var supportedFormats: [String] { get }
    var bookFolder: DeviceFolder { get }
    func matches(_ info: DeviceInfo) -> Bool
}

public struct KindlePaperwhite12Profile: DeviceProfile {
    public let id = "kindle-paperwhite-12"
    public let displayName = "Kindle Paperwhite"
    public let supportedFormats = ["epub", "pdf", "azw3", "txt"]
    public let bookFolder = DeviceFolder(path: "Documents")

    public init() {}

    public func matches(_ info: DeviceInfo) -> Bool {
        info.vendorID == 0x1949 // Amazon
    }
}
