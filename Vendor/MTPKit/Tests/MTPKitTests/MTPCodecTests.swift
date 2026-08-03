import Testing
import Foundation
@testable import MTPKit

@Suite struct MTPCodecTests {

    @Test func commandContainerRoundTrips() throws {
        let tx: UInt32 = 0x12345678
        let data = MTPContainer.encodeCommand(
            operation: .getObjectHandles,
            transactionID: tx,
            parameters: [0x10001, mtpAllFormats, mtpRootParentHandle]
        )

        let header = try MTPContainer.decodeHeader(data)
        #expect(header.type == MTPContainerType.command.rawValue)
        #expect(header.code == MTPOperation.getObjectHandles.rawValue)
        #expect(header.transactionID == tx)
        #expect(header.length == UInt32(MTPContainerHeader.size + 3 * 4))

        let params = try MTPContainer.responseParameters(from: data)
        #expect(params == [0x10001, mtpAllFormats, mtpRootParentHandle])
    }

    @Test func headerDecodeRejectsTruncatedData() {
        let tooShort = Data([0x01, 0x02, 0x03])
        #expect(throws: MTPError.truncated) {
            _ = try MTPContainer.decodeHeader(tooShort)
        }
    }

    @Test func objectInfoFolderRoundTrips() throws {
        let payload = MTPObjectInfo.encode(
            storageID: 0x10001,
            parentObject: mtpRootParentHandle,
            format: MTPObjectFormat.association,
            sizeBytes: 0,
            filename: "DCIM"
        )
        let info = try MTPObjectInfo(parsing: payload)
        #expect(info.filename == "DCIM")
        #expect(info.isDirectory)
        #expect(info.storageID == 0x10001)
        #expect(info.parentObject == mtpRootParentHandle)
    }

    @Test func objectInfoFileRoundTrips() throws {
        let payload = MTPObjectInfo.encode(
            storageID: 0x10001,
            parentObject: 42,
            format: 0x3801, // EXIF/JPEG
            sizeBytes: 123_456,
            filename: "IMG_0001.jpg"
        )
        let info = try MTPObjectInfo(parsing: payload)
        #expect(!info.isDirectory)
        #expect(info.compressedSize == 123_456)
        #expect(info.parentObject == 42)
        #expect(info.filename == "IMG_0001.jpg")
    }

    @Test func objectInfoHandlesUnicodeFilenames() throws {
        let name = "相片_2024🎉.png"
        let payload = MTPObjectInfo.encode(
            storageID: 1, parentObject: 1, format: 0x380B, sizeBytes: 10, filename: name
        )
        let info = try MTPObjectInfo(parsing: payload)
        #expect(info.filename == name)
    }

    @Test func storageInfoParses() throws {
        var w = ByteWriter()
        w.u16(0x0003)            // StorageType: FixedRAM
        w.u16(0x0002)            // FilesystemType
        w.u16(0x0003)            // AccessCapability: read-write
        w.u64(128_000_000_000)   // MaxCapacity
        w.u64(52_300_000_000)    // FreeSpace
        w.u32(1_000_000)         // FreeSpaceInObjects
        w.mtpString("Internal shared storage")
        w.mtpString("12345-ABCDE")

        let info = try MTPStorageInfo(parsing: w.data)
        #expect(info.maxCapacity == 128_000_000_000)
        #expect(info.freeSpace == 52_300_000_000)
        #expect(info.storageDescription == "Internal shared storage")
        #expect(info.volumeIdentifier == "12345-ABCDE")
    }

    @Test func emptyMTPStringEncodesAsSingleZeroByte() {
        var w = ByteWriter()
        w.mtpString("")
        #expect(w.bytes == [0])
    }

    @Test func ptpDateParses() {
        let date = MTPDate.parse("20240115T103000")
        #expect(date != nil)
        let none = MTPDate.parse("")
        #expect(none == nil)
    }
}
