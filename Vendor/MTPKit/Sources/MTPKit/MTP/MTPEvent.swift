import Foundation

/// A parsed MTP asynchronous event received on the interrupt endpoint. The container is
/// the standard 12-byte header (type = event) followed by up to 3 UInt32 parameters.
/// For object events, `parameters[0]` is the affected object handle; for store events it
/// is the StorageID.
public struct MTPEvent: Sendable, Equatable {
    public var code: UInt16
    public var parameters: [UInt32]

    public init(code: UInt16, parameters: [UInt32]) {
        self.code = code
        self.parameters = parameters
    }

    /// Parse from a raw interrupt packet. Returns nil if it isn't a well-formed event.
    public init?(parsing data: Data) {
        guard let header = try? MTPContainer.decodeHeader(data),
              header.type == MTPContainerType.event.rawValue else { return nil }
        self.code = header.code
        var params = [UInt32]()
        var r = ByteReader(data)
        try? r.skip(MTPContainerHeader.size)
        while r.remaining >= 4, let v = try? r.u32() { params.append(v) }
        self.parameters = params
    }

    public var eventCode: MTPEventCode? { MTPEventCode(rawValue: code) }
    public var firstParameter: UInt32? { parameters.first }
}
