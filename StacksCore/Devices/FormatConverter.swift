import Foundation

public protocol FormatConverter: Sendable {
    func canConvert(from sourceFormat: String, to targetFormat: String) -> Bool
    func convert(_ source: URL, from sourceFormat: String, to targetFormat: String) async throws -> URL
}

/// v1: no conversions. The full format-conversion feature (EPUB→MOBI/AZW3, …)
/// plugs in behind this protocol without touching device code.
public struct IdentityConverter: FormatConverter {
    public init() {}
    public func canConvert(from sourceFormat: String, to targetFormat: String) -> Bool { false }
    public func convert(_ source: URL, from sourceFormat: String, to targetFormat: String) async throws -> URL {
        throw DeviceSendError.conversionUnsupported(from: sourceFormat, to: targetFormat)
    }
}

public enum DeviceSendError: Error, Equatable {
    case conversionUnsupported(from: String, to: String)
}
