import Foundation
import Testing
@testable import StacksCore

@Suite
struct MetadataExtractorTests {
    @Test
    func kindIsDetectedFromExtension() {
        #expect(MetadataExtractor.kind(for: URL(fileURLWithPath: "/tmp/x.epub")) == .epub)
        #expect(MetadataExtractor.kind(for: URL(fileURLWithPath: "/tmp/x.pdf")) == .pdf)
        #expect(MetadataExtractor.kind(for: URL(fileURLWithPath: "/tmp/x.djvu")) == .djvu)
        #expect(MetadataExtractor.kind(for: URL(fileURLWithPath: "/tmp/x.txt")) == nil)
    }

    @Test
    func epubExtractsMetadataAndCover() throws {
        let url = try Fixtures.makeEPUB()
        let metadata = try MetadataExtractor.extract(from: url, kind: .epub)

        #expect(metadata.title == "Range: Why Generalists Triumph in a Specialized World")
        #expect(metadata.authors == ["David Epstein"])
        #expect(metadata.series == "Studies")
        #expect(metadata.seriesIndex == 1.5)
        #expect(metadata.tags.contains("Science"))
        #expect(metadata.languages == ["eng"])
        #expect(metadata.identifiers["isbn"] == "978-0-7352-2129-1")
        #expect(metadata.comments == "Why generalists beat specialists.")
        #expect(metadata.publicationDate != nil)

        let cover = try MetadataExtractor.extractCover(from: url, kind: .epub)
        #expect(cover != nil)
    }

    @Test
    func pdfFallsBackToFilenameWhenNoMetadata() throws {
        let url = try Fixtures.makePDF()
        let metadata = try MetadataExtractor.extract(from: url, kind: .pdf)

        #expect(metadata.title == "plain")
        #expect(metadata.authors.isEmpty)

        let cover = try MetadataExtractor.extractCover(from: url, kind: .pdf)
        #expect(cover != nil)
    }

    @Test
    func djvuUsesFilenameMetadata() {
        let url = URL(fileURLWithPath: "/tmp/My Book.djvu")
        let metadata = try? MetadataExtractor.extract(from: url, kind: .djvu)
        #expect(metadata?.title == "My Book")
    }
}
