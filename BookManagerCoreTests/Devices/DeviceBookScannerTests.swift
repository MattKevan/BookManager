import Foundation
import Testing
@testable import BookManagerCore

@Suite
struct DeviceBookScannerTests {
    /// `Bundle.module` is SPM-only; Xcode test bundles resolve their resources
    /// through the bundle that contains a type from the test target, and
    /// XcodeGen copies resources flat (no subdirectory is preserved).
    private final class FixtureMarker {}

    private func mobiFixtureURL() throws -> URL {
        let bundle = Bundle(for: FixtureMarker.self)
        return try #require(bundle.url(forResource: "fixture", withExtension: "mobi"))
    }

    @Test
    func scansMobiWithMetadata() async throws {
        let transport = MockTransport()
        let mobiURL = try mobiFixtureURL()
        await transport.add(fileNamed: "Fixture.mobi", data: try Data(contentsOf: mobiURL))

        let records = try await DeviceBookScanner(transport: transport)
            .scan(in: DeviceFolder(path: "Documents"))

        #expect(records.count == 1)
        let record = try #require(records.first)
        #expect(!record.title.isEmpty)
        #expect(record.format == "MOBI")
        #expect(!record.isDRM)
    }

    @Test
    func marksDrmMobiWithLockFlag() async throws {
        let transport = MockTransport()
        // Patch the fixture's record-0 encryption_type byte, mirroring
        // MobiReaderTests.encryptedMobiThrowsDrmError: the "MOBI" magic sits
        // at record0 + 16; encryption_type is four bytes before it. The first
        // "MOBI" occurrence (PDB creator field, byte 64) is skipped by
        // searching only past the header.
        let data = try Data(contentsOf: mobiFixtureURL())
        guard let magic = data.range(of: Data("MOBI".utf8), in: 80..<data.count) else {
            Issue.record("fixture has no record-0 MOBI magic")
            return
        }
        var patched = data
        patched[magic.lowerBound - 4] = 1 // MOBI_ENCRYPTION_V1
        await transport.add(fileNamed: "Locked.azw3", data: patched)

        let records = try await DeviceBookScanner(transport: transport)
            .scan(in: DeviceFolder(path: "Documents"))

        let locked = try #require(records.first { $0.name() == "Locked.azw3" })
        #expect(locked.isDRM)
    }

    @Test
    func scansEpubWithExtractedMetadata() async throws {
        let transport = MockTransport()
        let epubURL = try Fixtures.makeEPUB(named: "scanned.epub")
        defer { try? FileManager.default.removeItem(at: epubURL) }
        await transport.add(fileNamed: "scanned.epub", data: try Data(contentsOf: epubURL))

        let records = try await DeviceBookScanner(transport: transport)
            .scan(in: DeviceFolder(path: "Documents"))

        let record = try #require(records.first)
        #expect(record.format == "EPUB")
        #expect(!record.title.isEmpty)
        #expect(!record.authors.isEmpty)
    }

    @Test
    func listsKfxByFilenameOnlyAndSkipsNonBooks() async throws {
        let transport = MockTransport()
        await transport.add(fileNamed: "Novel.kfx", data: Data("x".utf8))
        await transport.add(fileNamed: "notes.txt", data: Data("y".utf8))
        await transport.add(fileNamed: ".DS_Store", data: Data("z".utf8))
        await transport.add(fileNamed: "archive.zip", data: Data("w".utf8))

        let records = try await DeviceBookScanner(transport: transport)
            .scan(in: DeviceFolder(path: "Documents"))

        #expect(records.map(\.format).sorted() == ["KFX", "TXT"])
    }
}

// Helper so the test reads cleanly; DeviceBookRecord exposes `file`.
private extension DeviceBookRecord {
    func name() -> String { file.name }
}
