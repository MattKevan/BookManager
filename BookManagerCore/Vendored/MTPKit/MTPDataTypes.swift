import Foundation

/// Parsed MTP ObjectInfo dataset (the reply to GetObjectInfo). We keep the fields we
/// need for a file browser and skip thumbnail/image metadata.
public struct MTPObjectInfo: Sendable, Equatable {
    public var storageID: UInt32
    public var format: UInt16
    public var compressedSize: UInt32
    public var parentObject: UInt32
    public var filename: String
    public var dateModified: Date?

    public var isDirectory: Bool { format == MTPObjectFormat.association }

    /// Parse from a Data container body.
    public init(parsing data: Data) throws {
        var r = ByteReader(data)
        storageID = try r.u32()
        format = try r.u16()
        try r.skip(2)                 // ProtectionStatus
        compressedSize = try r.u32()
        try r.skip(2)                 // ThumbFormat
        try r.skip(4)                 // ThumbCompressedSize
        try r.skip(4)                 // ThumbPixWidth
        try r.skip(4)                 // ThumbPixHeight
        try r.skip(4)                 // ImagePixWidth
        try r.skip(4)                 // ImagePixHeight
        try r.skip(4)                 // ImageBitDepth
        parentObject = try r.u32()
        try r.skip(2)                 // AssociationType
        try r.skip(4)                 // AssociationDesc
        try r.skip(4)                 // SequenceNumber
        filename = try r.mtpString()
        _ = try r.mtpString()         // DateCreated
        let modified = try r.mtpString()
        dateModified = MTPDate.parse(modified)
    }

    /// Build a SendObjectInfo dataset for creating a new file or folder.
    public static func encode(
        storageID: UInt32,
        parentObject: UInt32,
        format: UInt16,
        sizeBytes: UInt32,
        filename: String
    ) -> Data {
        var w = ByteWriter()
        w.u32(storageID)
        w.u16(format)
        w.u16(0)                      // ProtectionStatus
        w.u32(sizeBytes)              // ObjectCompressedSize
        w.u16(0)                      // ThumbFormat
        w.u32(0)                      // ThumbCompressedSize
        w.u32(0); w.u32(0)            // ThumbPix W/H
        w.u32(0); w.u32(0)            // ImagePix W/H
        w.u32(0)                      // ImageBitDepth
        w.u32(parentObject)
        w.u16(format == MTPObjectFormat.association ? 1 : 0) // AssociationType (1 = GenericFolder)
        w.u32(0)                      // AssociationDesc
        w.u32(0)                      // SequenceNumber
        w.mtpString(filename)
        w.mtpString("")               // DateCreated
        w.mtpString("")               // DateModified
        w.mtpString("")               // Keywords
        return w.data
    }
}

/// Parsed MTP StorageInfo dataset (the reply to GetStorageInfo).
public struct MTPStorageInfo: Sendable, Equatable {
    public var storageType: UInt16
    public var filesystemType: UInt16
    public var accessCapability: UInt16
    public var maxCapacity: UInt64
    public var freeSpace: UInt64
    public var storageDescription: String
    public var volumeIdentifier: String

    public init(parsing data: Data) throws {
        var r = ByteReader(data)
        storageType = try r.u16()
        filesystemType = try r.u16()
        accessCapability = try r.u16()
        maxCapacity = try r.u64()
        freeSpace = try r.u64()
        try r.skip(4)                 // FreeSpaceInObjects
        storageDescription = try r.mtpString()
        volumeIdentifier = try r.mtpString()
    }
}

/// PTP/MTP date strings look like "20240115T103000" (optionally ".0" and/or "Z").
enum MTPDate {
    static func parse(_ string: String) -> Date? {
        guard !string.isEmpty else { return nil }
        let trimmed = string
            .replacingOccurrences(of: "Z", with: "")
            .components(separatedBy: ".").first ?? string
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        return formatter.date(from: trimmed)
    }
}
