import CryptoKit
import Foundation
import Testing
@testable import BookManagerCore

@Suite
struct CalibreReaderTests {
    private func makeLibrary() throws -> URL {
        try CalibreFixture.makeLibrary(named: "fixture-\(UUID().uuidString)")
    }

    private func book(_ id: Int, from library: URL) throws -> CalibreBookRecord {
        let reader = try CalibreReader.open(libraryURL: library)
        defer { try? reader.close() }
        return try reader.books().first { $0.calibreID == id }!
    }

    @Test
    func opensAndSummarizesFixtureLibrary() throws {
        let library = try makeLibrary()
        let reader = try CalibreReader.open(libraryURL: library)
        defer { try? reader.close() }

        let summary = try reader.summary()

        #expect(summary.userVersion == 26)
        #expect(summary.libraryID == "acceptance-fixture-uuid")
        #expect(summary.bookCount == CalibreFixture.expectedBookCount)
        #expect(summary.formatCount == CalibreFixture.expectedFormatCount)
        #expect(summary.titles.count == CalibreFixture.expectedBookCount)
        #expect(summary.titles.contains("Range: Why Generalists Triumph in a Specialized World"))
    }

    @Test
    func mapsFullMetadataMatrix() throws {
        let library = try makeLibrary()
        let record = try book(1, from: library)

        #expect(record.title == "Range: Why Generalists Triumph in a Specialized World")
        #expect(record.authors == [
            CalibreAuthor(name: "David Epstein", sort: "Epstein, David"),
            CalibreAuthor(name: "Peter Brown", sort: "Brown, Peter"),
        ])
        #expect(record.series == "Studies")
        #expect(record.seriesIndex == 1.5)
        #expect(record.tags == ["Science", "Sport"])
        // Calibre's 2...10 rating scale halved to 1...5.
        #expect(record.rating == 4)
        #expect(record.publisher == "Riverhead")
        // Hand-computed julian conversion: 2019-05-28 00:00 UTC == unix 1559001600.
        #expect(record.publicationDate == Date(timeIntervalSince1970: 1_559_001_600))
        #expect(record.addedDate == Date(timeIntervalSince1970: 1_705_276_800))
        #expect(record.languages == ["eng", "fra"])
        #expect(record.identifiers["isbn"] == "978-0-7352-2129-1")
        #expect(record.identifiers["google"] == "abcd1234")
        #expect(record.identifiers["asin"] == "B07VWM1Z2B")
        #expect(record.comments == "<p>Great book</p>")
        #expect(record.rawMetadata["calibre.custom.genre"] == "science")
        #expect(record.rawMetadata["calibre.custom.shelves"] == #"["read","favorites"]"#)
        #expect(record.opfPath == "metadata.opf")
    }

    @Test
    func preservesUnsupportedValuesInRawPayload() throws {
        let library = try makeLibrary()
        let record = try book(1, from: library)

        #expect(record.rawMetadata["calibre.lccn"] == "2018049465")
        // Annotations and last-read positions are preserved verbatim.
        let annotations = record.rawMetadata["calibre.annotations"] ?? ""
        #expect(annotations.contains("ann-1"))
        #expect(annotations.contains("EPUB"))
        let lastRead = record.rawMetadata["calibre.lastReadPositions"] ?? ""
        #expect(lastRead.contains("kindle"))

        // Schema variant with the pages column: preserved defensively.
        let variant = try CalibreFixture.makeVariantLibrary(
            named: "variant-pages-\(UUID().uuidString)",
            userVersion: 26,
            extraColumns: true
        )
        let variantRecord = try book(1, from: variant)
        #expect(variantRecord.rawMetadata["calibre.pages"] == "320")
        #expect(variantRecord.rawMetadata["calibre.lccn"] == "2018049465")
    }

    @Test
    func resolvesFormatsAndCovers() throws {
        let library = try makeLibrary()

        let range = try book(1, from: library)
        #expect(range.formats.count == 2)
        #expect(range.formats[0].format == "EPUB")
        #expect(range.formats[0].name == "Range - David Epstein")
        #expect(range.formats[0].size == 1_000)
        #expect(FileManager.default.fileExists(atPath: range.formats[0].sourceURL.path))
        #expect(range.formats[1].format == "PDF")
        #expect(FileManager.default.fileExists(atPath: range.formats[1].sourceURL.path))
        if case .file(let url) = range.cover {
            #expect(url.lastPathComponent == "cover.jpg")
            #expect(FileManager.default.fileExists(atPath: url.path))
        } else {
            Issue.record("expected a cover.jpg file cover")
        }

        // A data row whose file is missing: reported, not thrown.
        let ghost = try book(6, from: library)
        #expect(ghost.formats.count == 1)
        #expect(ghost.formats[0].isMissing)

        // No cover when neither BLOB nor cover.jpg exists.
        let noCover = try book(3, from: library)
        #expect(noCover.cover == nil)

        // Schema variant with a cover BLOB column: blob wins.
        let variant = try CalibreFixture.makeVariantLibrary(
            named: "variant-cover-\(UUID().uuidString)",
            userVersion: 26,
            extraColumns: true
        )
        let blobBook = try book(1, from: variant)
        #expect(blobBook.cover == .blob(Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])))
    }

    @Test
    func opfCrossCheckFallsBackWhenDatabaseIncomplete() throws {
        let library = try makeLibrary()
        let record = try book(5, from: library)

        // DB title and authors are empty; the book's metadata.opf fills them.
        #expect(record.title == "Fallback Title")
        #expect(record.authors == [CalibreAuthor(name: "Fallback Author", sort: "Fallback Author")])
        #expect(record.opfPath == "metadata.opf")
    }

    @Test
    func rejectsUnsupportedSchemaVersion() throws {
        let variant = try CalibreFixture.makeVariantLibrary(
            named: "variant-version-\(UUID().uuidString)",
            userVersion: 99,
            extraColumns: false
        )
        #expect(throws: CalibreReaderError.unsupportedSchemaVersion(99)) {
            _ = try CalibreReader.open(libraryURL: variant)
        }
    }

    @Test
    func doesNotModifySourceLibrary() throws {
        let library = try makeLibrary()
        let databaseURL = library.appending(path: "metadata.db")

        let beforeData = try Data(contentsOf: databaseURL)
        let beforeHash = SHA256.hash(data: beforeData).map { String(format: "%02x", $0) }.joined()
        let beforeMtime = try FileManager.default
            .attributesOfItem(atPath: databaseURL.path)[.modificationDate] as? Date

        let reader = try CalibreReader.open(libraryURL: library)
        _ = try reader.books()
        try reader.close()

        let afterData = try Data(contentsOf: databaseURL)
        let afterHash = SHA256.hash(data: afterData).map { String(format: "%02x", $0) }.joined()
        let afterMtime = try FileManager.default
            .attributesOfItem(atPath: databaseURL.path)[.modificationDate] as? Date

        #expect(beforeHash == afterHash)
        #expect(beforeMtime == afterMtime)
    }
}
