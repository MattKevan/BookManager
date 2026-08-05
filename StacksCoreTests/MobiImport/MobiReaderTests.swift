import Foundation
import Testing
@testable import StacksCore

@Suite
struct MobiReaderTests {
    private final class FixtureMarker {}

    private func fixtureURL() throws -> URL {
        let bundle = Bundle(for: FixtureMarker.self)
        return try #require(bundle.url(forResource: "fixture", withExtension: "mobi"))
    }

    @Test
    func extractsChaptersFromFixture() throws {
        let reader = try MobiReader(url: fixtureURL())
        let content = try reader.extract()

        // The fixture ("sample-ncx.mobi") has three XHTML fragments: two
        // h1-chapters and one h2-subchapter block.
        #expect(content.chapters.count == 3)
        #expect(content.chapters.allSatisfy { !$0.html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        #expect(content.chapters[0].html.contains("Test chapter 1"))
        #expect(content.chapters[1].html.contains("Test chapter 2"))
        // The h1 content is used as the chapter title when present.
        #expect(content.chapters[0].title == "Test chapter 1")
        #expect(content.chapters[2].title == "Test subchapter 2-1")
        // Stable ids.
        #expect(content.chapters.map(\.id) == ["chap1", "chap2", "chap3"])
    }

    @Test
    func minimalMobiWithoutMetadataOrDefaults() throws {
        // The fixture carries no EXTH metadata and no cover: the reader must
        // degrade to defaults without crashing.
        let reader = try MobiReader(url: fixtureURL())
        let content = try reader.extract()
        #expect(content.title == "")
        #expect(content.authors.isEmpty)
        #expect(content.cover == nil)
        #expect(!content.chapters.isEmpty)
    }

    @Test
    func encryptedMobiThrowsDrmError() throws {
        // Patch the fixture's record-0 encryption_type byte (the "MOBI" magic
        // sits at record0 + 16; encryption_type is at record0 + 12, i.e. four
        // bytes before the magic) to simulate a DRM-encrypted book.
        let data = try Data(contentsOf: fixtureURL())
        // The first "MOBI" occurrence is the PDB creator field (byte 64); the
        // record-0 header magic sits at firstRecordOffset + 16, well past the
        // header. Search only past the header.
        guard let magic = data.range(of: Data("MOBI".utf8), in: 80..<data.count) else {
            Issue.record("fixture has no record-0 MOBI magic")
            return
        }
        var patched = data
        patched[magic.lowerBound - 4] = 1 // MOBI_ENCRYPTION_V1
        let encrypted = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).mobi")
        try patched.write(to: encrypted)
        defer { try? FileManager.default.removeItem(at: encrypted) }

        let reader = try MobiReader(url: encrypted)
        #expect(throws: MobiReaderError.drmProtected) {
            _ = try reader.extract()
        }
    }

    @Test
    func unreadableFileThrowsUnreadable() throws {
        let bad = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).mobi")
        try Data("not a mobi file at all".utf8).write(to: bad)
        defer { try? FileManager.default.removeItem(at: bad) }

        let reader = try MobiReader(url: bad)
        do {
            _ = try reader.extract()
            Issue.record("expected an unreadable error")
        } catch let error as MobiReaderError {
            guard case .unreadable = error else {
                Issue.record("expected unreadable, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test
    func missingFileThrowsUnreadableAtInit() {
        let missing = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).mobi")
        #expect(throws: MobiReaderError.unreadable("file not found: \(missing.lastPathComponent)")) {
            _ = try MobiReader(url: missing)
        }
    }

    // MARK: - Synthetic rawml decomposition (review round 1)

    @Test
    func bodyEmbeddedContentYieldsChapter() throws {
        // A typical real-world rawml stores content INSIDE the html wrapper;
        // the </html> strip must not silently empty the chapter (review fix 1).
        let rawml = """
        <?xml version="1.0"?>
        <html><head><title>Chapter One</title></head>
        <body><h1>Chapter One</h1><p>Real-world content inside the body.</p></body></html>
        """
        let chapters = MobiReader.chapters(from: rawml)
        #expect(chapters.count == 1)
        #expect(chapters[0].html.contains("Real-world content inside the body."))
    }

    @Test
    func noSeparatorsYieldsSingleChapter() throws {
        // A document without <?xml boundaries and without pagebreaks is a
        // single chapter carrying the whole content.
        let rawml = "<html><head><title>Only</title></head><body><p>Whole document without separators.</p></body></html>"
        let chapters = MobiReader.chapters(from: rawml)
        #expect(chapters.count == 1)
        #expect(chapters[0].html.contains("Whole document without separators."))
    }

    @Test
    func pagebreakFallbackStillSplits() throws {
        // The no-<?xml fallback splits on <mbp:pagebreak> markers.
        let rawml = "<p>Part one.</p><mbp:pagebreak/><p>Part two.</p><mbp:pagebreak/><p>Part three.</p>"
        let chapters = MobiReader.chapters(from: rawml)
        #expect(chapters.count == 3)
        #expect(chapters[0].html.contains("Part one."))
        #expect(chapters[1].html.contains("Part two."))
        #expect(chapters[2].html.contains("Part three."))
    }
}
