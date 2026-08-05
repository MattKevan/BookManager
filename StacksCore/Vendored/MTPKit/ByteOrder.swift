import Foundation

public enum MTPError: Error, Sendable, Equatable {
    case truncated
    case unexpectedContainerType(UInt16)
    case operationFailed(code: UInt16)
    case stringTooLong
    case noDevice
    case interfaceNotFound
    case usb(String)
    case protocolError(String)
    /// The device's USB state machine is wedged; only a port reset recovers it.
    case deviceStalled
}

/// Little-endian cursor reader for MTP/PTP payloads. MTP is always little-endian.
struct ByteReader {
    private let bytes: [UInt8]
    private(set) var offset: Int

    init(_ data: Data) { self.bytes = [UInt8](data); self.offset = 0 }
    init(_ bytes: [UInt8]) { self.bytes = bytes; self.offset = 0 }

    var remaining: Int { bytes.count - offset }

    mutating func u8() throws -> UInt8 {
        guard remaining >= 1 else { throw MTPError.truncated }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func u16() throws -> UInt16 {
        guard remaining >= 2 else { throw MTPError.truncated }
        defer { offset += 2 }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    mutating func u32() throws -> UInt32 {
        guard remaining >= 4 else { throw MTPError.truncated }
        defer { offset += 4 }
        var v: UInt32 = 0
        for i in 0..<4 { v |= UInt32(bytes[offset + i]) << (8 * i) }
        return v
    }

    mutating func u64() throws -> UInt64 {
        guard remaining >= 8 else { throw MTPError.truncated }
        defer { offset += 8 }
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(bytes[offset + i]) << (8 * i) }
        return v
    }

    /// MTP string: 1 byte = number of UTF-16 code units *including* the trailing null,
    /// then that many UTF-16LE code units. A count of 0 means an empty string.
    mutating func mtpString() throws -> String {
        let count = try u8()
        guard count > 0 else { return "" }
        var units = [UInt16]()
        units.reserveCapacity(Int(count))
        for _ in 0..<count { units.append(try u16()) }
        if units.last == 0 { units.removeLast() } // drop null terminator
        return String(decoding: units, as: UTF16.self)
    }

    mutating func u32Array() throws -> [UInt32] {
        let count = try u32()
        var result = [UInt32]()
        result.reserveCapacity(Int(count))
        for _ in 0..<count { result.append(try u32()) }
        return result
    }

    mutating func u16Array() throws -> [UInt16] {
        let count = try u32()
        var result = [UInt16]()
        result.reserveCapacity(Int(count))
        for _ in 0..<count { result.append(try u16()) }
        return result
    }

    mutating func skip(_ n: Int) throws {
        guard remaining >= n else { throw MTPError.truncated }
        offset += n
    }
}

/// Little-endian writer for MTP/PTP payloads.
struct ByteWriter {
    private(set) var bytes = [UInt8]()

    mutating func u8(_ v: UInt8) { bytes.append(v) }
    mutating func u16(_ v: UInt16) { for i in 0..<2 { bytes.append(UInt8((v >> (8 * i)) & 0xFF)) } }
    mutating func u32(_ v: UInt32) { for i in 0..<4 { bytes.append(UInt8((v >> (8 * i)) & 0xFF)) } }
    mutating func u64(_ v: UInt64) { for i in 0..<8 { bytes.append(UInt8((v >> (8 * i)) & 0xFF)) } }

    mutating func mtpString(_ s: String) {
        if s.isEmpty { u8(0); return }
        let units = Array(s.utf16) + [0] // include null terminator
        u8(UInt8(min(units.count, 255)))
        for unit in units.prefix(255) { u16(unit) }
    }

    mutating func append(_ data: [UInt8]) { bytes.append(contentsOf: data) }
    mutating func append(_ data: Data) { bytes.append(contentsOf: data) }

    var data: Data { Data(bytes) }
}
