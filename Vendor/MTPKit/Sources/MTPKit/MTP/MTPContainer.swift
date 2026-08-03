import Foundation

/// The 12-byte header that prefixes every MTP USB container.
public struct MTPContainerHeader: Equatable, Sendable {
    public static let size = 12

    public var length: UInt32        // total container length, including this header
    public var type: UInt16          // MTPContainerType
    public var code: UInt16          // operation / response / event code
    public var transactionID: UInt32

    public init(length: UInt32, type: UInt16, code: UInt16, transactionID: UInt32) {
        self.length = length
        self.type = type
        self.code = code
        self.transactionID = transactionID
    }
}

/// Encoding/decoding of MTP USB containers (header + parameter/payload body).
public enum MTPContainer {

    /// Parse the 12-byte header from the front of `data`.
    public static func decodeHeader(_ data: Data) throws -> MTPContainerHeader {
        guard data.count >= MTPContainerHeader.size else { throw MTPError.truncated }
        var r = ByteReader(data)
        let length = try r.u32()
        let type = try r.u16()
        let code = try r.u16()
        let tx = try r.u32()
        return MTPContainerHeader(length: length, type: type, code: code, transactionID: tx)
    }

    /// Build a Command container (type 1): header + up to 5 UInt32 parameters.
    public static func encodeCommand(operation: MTPOperation, transactionID: UInt32, parameters: [UInt32] = []) -> Data {
        precondition(parameters.count <= 5, "MTP commands carry at most 5 parameters")
        var w = ByteWriter()
        let length = UInt32(MTPContainerHeader.size + parameters.count * 4)
        w.u32(length)
        w.u16(MTPContainerType.command.rawValue)
        w.u16(operation.rawValue)
        w.u32(transactionID)
        for p in parameters { w.u32(p) }
        return w.data
    }

    /// Build a Data container (type 2): header + raw dataset payload.
    public static func encodeData(operation: MTPOperation, transactionID: UInt32, payload: Data) -> Data {
        var w = ByteWriter()
        let length = UInt32(MTPContainerHeader.size + payload.count)
        w.u32(length)
        w.u16(MTPContainerType.data.rawValue)
        w.u16(operation.rawValue)
        w.u32(transactionID)
        w.append(payload)
        return w.data
    }

    /// Return just the body (everything after the 12-byte header) of a container.
    public static func body(of data: Data) throws -> Data {
        guard data.count >= MTPContainerHeader.size else { throw MTPError.truncated }
        return data.subdata(in: MTPContainerHeader.size..<data.count)
    }

    /// Parse the response parameters (up to 5 UInt32) from a Response container body.
    public static func responseParameters(from data: Data) throws -> [UInt32] {
        let payload = try body(of: data)
        var r = ByteReader(payload)
        var params = [UInt32]()
        while r.remaining >= 4 { params.append(try r.u32()) }
        return params
    }
}
