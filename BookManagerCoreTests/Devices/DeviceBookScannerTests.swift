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

    private let documents = DeviceFolder(path: "Documents")

    @Test
    func listReturnsStemTitlesWithoutDownloading() async throws {
        let transport = MockTransport()
        await transport.add(fileNamed: "Fixture.mobi", data: try Data(contentsOf: mobiFixtureURL()))
        await transport.add(fileNamed: "scanned.epub", data: Data("x".utf8))
        await transport.add(fileNamed: ".DS_Store", data: Data("z".utf8))

        let records = try await DeviceBookScanner(transport: transport)
            .list(in: documents)

        #expect(records.map { $0.name() }.sorted() == ["Fixture.mobi", "scanned.epub"])
        #expect(records.allSatisfy { !$0.isEnriched && $0.authors.isEmpty && !$0.isDRM })
        // Filename-stem titles only — no downloads happened.
        #expect(records.allSatisfy { $0.title == URL(fileURLWithPath: $0.name()).deletingPathExtension().lastPathComponent })
        #expect(await transport.downloadedNames.isEmpty)
    }

    @Test
    func listKeepsKfxAndTxtSkipsNonBooks() async throws {
        let transport = MockTransport()
        await transport.add(fileNamed: "Novel.kfx", data: Data("x".utf8))
        await transport.add(fileNamed: "notes.txt", data: Data("y".utf8))
        await transport.add(fileNamed: ".DS_Store", data: Data("z".utf8))
        await transport.add(fileNamed: "archive.zip", data: Data("w".utf8))

        let records = try await DeviceBookScanner(transport: transport)
            .list(in: documents)

        #expect(records.map(\.format).sorted() == ["KFX", "TXT"])
        #expect(await transport.downloadedNames.isEmpty)
    }

    @Test
    func enrichFillsMetadataFromFixture() async throws {
        let transport = MockTransport()
        let mobiURL = try mobiFixtureURL()
        await transport.add(fileNamed: "Fixture.mobi", data: try Data(contentsOf: mobiURL))

        let scanner = DeviceBookScanner(transport: transport)
        let listed = try await scanner.list(in: documents)
        let record = try #require(listed.first)
        #expect(!record.isEnriched)

        let enriched = try await scanner.enrich(record)

        #expect(enriched.isEnriched)
        #expect(!enriched.title.isEmpty)
        #expect(!enriched.isDRM)
        #expect(await transport.downloadedNames == ["Fixture.mobi"])
    }

    @Test
    func enrichMarksDrmBooks() async throws {
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

        let scanner = DeviceBookScanner(transport: transport)
        let listed = try await scanner.list(in: documents)
        let record = try #require(listed.first { $0.name() == "Locked.azw3" })

        let enriched = try await scanner.enrich(record)

        #expect(enriched.isDRM)
        #expect(enriched.isEnriched)
        #expect(enriched.title == "Locked")
    }

    @Test
    func enrichReadsEpubMetadata() async throws {
        let transport = MockTransport()
        let epubURL = try Fixtures.makeEPUB(named: "scanned.epub")
        defer { try? FileManager.default.removeItem(at: epubURL) }
        await transport.add(fileNamed: "scanned.epub", data: try Data(contentsOf: epubURL))

        let scanner = DeviceBookScanner(transport: transport)
        let record = try #require(try await scanner.list(in: documents).first)

        let enriched = try await scanner.enrich(record)

        #expect(enriched.isEnriched)
        #expect(!enriched.title.isEmpty)
        #expect(!enriched.authors.isEmpty)
        #expect(!enriched.isDRM)
    }

    @Test
    func enrichDegradesOnMalformedFile() async throws {
        let transport = MockTransport()
        await transport.add(fileNamed: "garbage.azw3", data: Data("not a real book".utf8))

        let scanner = DeviceBookScanner(transport: transport)
        let record = try #require(try await scanner.list(in: documents).first)

        let enriched = try await scanner.enrich(record)

        #expect(enriched.isEnriched)
        #expect(enriched.title == "garbage")
        #expect(!enriched.isDRM)
    }

    @Test
    func applyCacheFillsMetadataWithoutDownloads() async throws {
        let transport = MockTransport()
        await transport.add(fileNamed: "Alpha - One.mobi", data: Data("x".utf8))
        await transport.add(fileNamed: "Beta.mobi", data: Data("y".utf8))

        let scanner = DeviceBookScanner(transport: transport)
        let listed = try await scanner.list(in: documents)

        let cache = CalibreCache(jsonData: Data("""
        [{"lpath": "documents/Alpha - One.mobi", "size": 1, "title": "Alpha One", "authors": ["A Author"], "pages": -3}]
        """.utf8))
        let records = scanner.apply(cache: cache, to: listed)

        let alpha = try #require(records.first { $0.name() == "Alpha - One.mobi" })
        #expect(alpha.title == "Alpha One")
        #expect(alpha.authors == ["A Author"])
        #expect(alpha.isDRM)
        #expect(alpha.isEnriched)

        // Unmatched record keeps its filename-only state, un-enriched.
        let beta = try #require(records.first { $0.name() == "Beta.mobi" })
        #expect(beta.title == "Beta")
        #expect(!beta.isEnriched)
        #expect(beta.authors.isEmpty)
        #expect(!beta.isDRM)

        // The cache path must never touch the device for file contents.
        #expect(await transport.downloadedNames.isEmpty)
    }
}

// Helper so the test reads cleanly; DeviceBookRecord exposes `file`.
private extension DeviceBookRecord {
    func name() -> String { file.name }
}
