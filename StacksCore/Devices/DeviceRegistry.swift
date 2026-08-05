import Foundation

public struct DeviceRegistry: Sendable {
    private let profiles: [any DeviceProfile]

    public init(profiles: [any DeviceProfile] = [KindlePaperwhite12Profile()]) {
        self.profiles = profiles
    }

    public func resolve(_ info: DeviceInfo) -> (any DeviceProfile)? {
        profiles.first { $0.matches(info) }
    }
}
