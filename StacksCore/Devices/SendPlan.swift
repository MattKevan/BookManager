import Foundation

public enum SendOutcome: Sendable, Equatable {
    case copy(format: String)
    case convert(from: String, to: String)
    case noCompatibleFormat
}

public struct SendPlan: Sendable {
    private let profile: any DeviceProfile
    private let converter: any FormatConverter

    public init(profile: any DeviceProfile, converter: any FormatConverter) {
        self.profile = profile
        self.converter = converter
    }

    public func outcome(for formats: [BookFormatRecord]) -> SendOutcome {
        let present = formats.map { $0.kind.lowercased() }
        for target in profile.supportedFormats {
            if present.contains(target.lowercased()) { return .copy(format: target) }
        }
        for source in present {
            for target in profile.supportedFormats where target != source {
                if converter.canConvert(from: source, to: target) {
                    return .convert(from: source, to: target)
                }
            }
        }
        return .noCompatibleFormat
    }
}
