import Foundation
import Testing
@testable import StacksCore

@Suite
struct DeviceTransportTests {
    @Test
    func mockConnectReturnsAmazonVendorInfo() async throws {
        let transport = MockTransport()
        let info = try await transport.connect()
        #expect(info.name == "Mock Kindle")
        #expect(info.vendorID == 0x1949)
    }

    @Test
    func mockListsSeededFilesInFolder() async throws {
        let transport = MockTransport()
        await transport.add(fileNamed: "Book.azw3", data: Data("x".utf8))
        await transport.add(fileNamed: "Other.epub", data: Data("y".utf8))

        let files = try await transport.listFiles(in: DeviceFolder(path: "Documents"))

        #expect(files.count == 2)
        #expect(files.contains { $0.name == "Book.azw3" && $0.size == 1 })
        #expect(files.contains { $0.name == "Other.epub" })
    }

    @Test
    func mockDownloadWritesBytesToDestination() async throws {
        let transport = MockTransport()
        let bytes = Data("hello".utf8)
        await transport.add(fileNamed: "Book.epub", data: bytes)

        let dest = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dest) }
        let file = try #require(try await transport.listFiles(in: DeviceFolder(path: "Documents")).first)
        try await transport.download(file, to: dest.appending(path: "Book.epub"))

        let written = try Data(contentsOf: dest.appending(path: "Book.epub"))
        #expect(written == bytes)
    }

    @Test
    func mockUploadStoresBytesUnderFolderName() async throws {
        let transport = MockTransport()
        let source = FileManager.default.temporaryDirectory.appending(path: "up.epub")
        try Data("content".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        try await transport.upload(source, to: DeviceFolder(path: "Documents"), as: "Up.epub")

        let uploaded = await transport.uploadedFiles()
        #expect(uploaded["Documents/Up.epub"] == Data("content".utf8))
    }

    @Test
    func mockEjectSetsFlag() async throws {
        let transport = MockTransport()
        try await transport.eject()
        #expect(await transport.ejected)
    }

    @Test
    func rootFileRoundTripsDownloadAndUploadWithoutEnteringListings() async throws {
        let transport = MockTransport()
        let bytes = Data("cache".utf8)
        await transport.addRootFile(named: "metadata.calibre", data: bytes)

        let dest = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dest) }

        try await transport.download(atPath: "metadata.calibre", to: dest.appending(path: "metadata.calibre"))
        #expect(try Data(contentsOf: dest.appending(path: "metadata.calibre")) == bytes)

        // Root files are device-level: they never appear in Documents listings.
        let files = try await transport.listFiles(in: DeviceFolder(path: "Documents"))
        #expect(files.isEmpty)

        let source = dest.appending(path: "new.calibre")
        try Data("newer".utf8).write(to: source)
        try await transport.upload(atPath: "metadata.calibre", from: source)
        #expect(await transport.rootFileData(named: "metadata.calibre") == Data("newer".utf8))
    }

    @Test
    func rootDownloadMissingFileThrows() async throws {
        let transport = MockTransport()
        let dest = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dest) }
        await #expect(throws: DeviceTransportError.self) {
            try await transport.download(atPath: "metadata.calibre", to: dest.appending(path: "m.calibre"))
        }
    }
}
