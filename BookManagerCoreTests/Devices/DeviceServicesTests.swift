import Foundation
import Testing
@testable import BookManagerCore

@Suite
struct DeviceServicesTests {
    private let profile = KindlePaperwhite12Profile()

    private func makeFile(_ name: String, bytes: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: name)
        try bytes.write(to: url)
        return url
    }

    private struct ConvertingConverter: FormatConverter {
        func canConvert(from sourceFormat: String, to targetFormat: String) -> Bool {
            sourceFormat == "mobi" && targetFormat == "epub"
        }
        func convert(_ source: URL, from sourceFormat: String, to targetFormat: String) async throws -> URL {
            let out = FileManager.default.temporaryDirectory
                .appending(path: "\(UUID().uuidString).\(targetFormat)")
            try Data("converted".utf8).write(to: out)
            return out
        }
    }

    // MARK: - Send

    @Test
    func sendsSupportedFormatToDocuments() async throws {
        let transport = MockTransport()
        let service = DeviceSendService(transport: transport)
        let epub = try makeFile("book.epub", bytes: Data("epub".utf8))
        defer { try? FileManager.default.removeItem(at: epub) }

        let items = await service.send(
            [SendRequest(title: "Book Title", sourceURL: epub, format: "epub")],
            profile: profile, converter: IdentityConverter()
        )

        #expect(items.count == 1)
        #expect(items[0].status == .sent(format: "epub"))
        let uploaded = await transport.uploadedFiles()
        #expect(uploaded.keys.contains { $0 == "Documents/Book Title.epub" })
        #expect(uploaded["Documents/Book Title.epub"] == Data("epub".utf8))
    }

    @Test
    func reportsNoCompatibleFormatForDjvu() async throws {
        let transport = MockTransport()
        let service = DeviceSendService(transport: transport)
        let djvu = try makeFile("book.djvu", bytes: Data("djvu".utf8))
        defer { try? FileManager.default.removeItem(at: djvu) }

        let items = await service.send(
            [SendRequest(title: "Old Scan", sourceURL: djvu, format: "djvu")],
            profile: profile, converter: IdentityConverter()
        )

        #expect(items[0].status == .noCompatibleFormat)
        #expect(await transport.uploadedFiles().isEmpty)
    }

    @Test
    func convertsViaConverterWhenFormatUnsupported() async throws {
        let transport = MockTransport()
        let service = DeviceSendService(transport: transport)
        let mobi = try makeFile("book.mobi", bytes: Data("mobi".utf8))
        defer { try? FileManager.default.removeItem(at: mobi) }

        let items = await service.send(
            [SendRequest(title: "Converted Book", sourceURL: mobi, format: "mobi")],
            profile: profile, converter: ConvertingConverter()
        )

        #expect(items[0].status == .converted(from: "mobi", to: "epub"))
        let uploaded = await transport.uploadedFiles()
        #expect(uploaded.keys.contains { $0 == "Documents/Converted Book.epub" })
    }

    @Test
    func reportsUploadFailuresPerItem() async throws {
        let transport = MockTransport()
        await transport.uploadError(DeviceTransportError.fileNotFound("x"))
        let service = DeviceSendService(transport: transport)
        let epub = try makeFile("book.epub", bytes: Data("epub".utf8))
        defer { try? FileManager.default.removeItem(at: epub) }

        let items = await service.send(
            [SendRequest(title: "Fails", sourceURL: epub, format: "epub")],
            profile: profile, converter: IdentityConverter()
        )

        guard case .failed = items[0].status else {
            Issue.record("expected failure, got \(items[0].status)")
            return
        }
        #expect(SendReport(items: items).summary.contains("1 failed"))
    }

    // MARK: - Import

    @Test
    func downloadsSelectedFilesToDirectory() async throws {
        let transport = MockTransport()
        await transport.add(fileNamed: "A.azw3", data: Data("aaa".utf8))
        await transport.add(fileNamed: "B.epub", data: Data("bbb".utf8))

        let service = DeviceImportService(transport: transport)
        let files = try await transport.listFiles(in: DeviceFolder(path: "Documents"))
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let urls = try await service.download(files, to: dir)

        #expect(urls.count == 2)
        #expect(try Data(contentsOf: dir.appending(path: "A.azw3")) == Data("aaa".utf8))
        #expect(try Data(contentsOf: dir.appending(path: "B.epub")) == Data("bbb".utf8))
    }
}
