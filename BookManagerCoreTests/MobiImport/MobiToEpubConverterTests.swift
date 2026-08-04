import Foundation
import Testing
import ZIPFoundation
@testable import BookManagerCore

@Suite
struct MobiToEpubConverterTests {
    private func content(
        title: String = "Test Book",
        authors: [String] = ["Alice", "Bob"],
        subjects: [String] = [],
        cover: Data? = nil,
        chapters: [MobiChapter] = [
            MobiChapter(id: "chap1", title: "One", html: "<h1>One</h1><p>First chapter.</p>"),
            MobiChapter(id: "chap2", title: "Two", html: "<h2>Two</h2><p>Second chapter.</p>"),
        ]
    ) -> MobiContent {
        MobiContent(title: title, authors: authors, subjects: subjects, cover: cover, chapters: chapters)
    }

    private func archive(from data: Data) throws -> Archive {
        try Archive(data: data, accessMode: .read)
    }

    private func entryData(_ archive: Archive, _ path: String) -> Data? {
        guard let entry = archive[path] else { return nil }
        var data = Data()
        _ = try? archive.extract(entry) { chunk in data.append(chunk) }
        return data
    }

    @Test
    func producesValidEpubWithExpectedStructure() throws {
        let data = try MobiToEpubConverter.convert(content(cover: Data([0xFF, 0xD8, 0xFF, 0xE0])))
        let archive = try archive(from: data)

        let mimetype = entryData(archive, "mimetype").flatMap { String(data: $0, encoding: .utf8) }
        #expect(mimetype == "application/epub+zip")

        let container = entryData(archive, "META-INF/container.xml").flatMap { String(data: $0, encoding: .utf8) }
        #expect(container?.contains("content.opf") == true)

        let opf = entryData(archive, "content.opf").flatMap { String(data: $0, encoding: .utf8) } ?? ""
        // The OPF must be XML-well-formed (epubcheck/strict parsers reject an
        // unbound `opf:` prefix) — parse it and assert no error.
        #expect(throws: Never.self) { try XMLDocument(xmlString: opf) }
        #expect(opf.contains("Test Book"))
        #expect(opf.contains("Alice"))
        #expect(opf.contains("Bob"))
        // Spine order: chap1 before chap2.
        let first = opf.range(of: "idref=\"chap1\"")?.lowerBound
        let second = opf.range(of: "idref=\"chap2\"")?.lowerBound
        #expect(first != nil && second != nil && first! < second!)
        // Manifest includes chapters, cover, and ncx.
        #expect(opf.contains("chap1.xhtml"))
        #expect(opf.contains("chap2.xhtml"))
        #expect(opf.contains("cover.jpg"))
        #expect(opf.contains("toc.ncx"))

        // Chapter files exist and contain the expected text.
        let chapter1 = entryData(archive, "chap1.xhtml").flatMap { String(data: $0, encoding: .utf8) } ?? ""
        #expect(chapter1.contains("First chapter."))
        let chapter2 = entryData(archive, "chap2.xhtml").flatMap { String(data: $0, encoding: .utf8) } ?? ""
        #expect(chapter2.contains("Second chapter."))

        // Cover entry present; NCX has nav points.
        #expect(entryData(archive, "cover.jpg") != nil)
        let ncx = entryData(archive, "toc.ncx").flatMap { String(data: $0, encoding: .utf8) } ?? ""
        #expect(ncx.contains("navPoint"))
    }

    @Test
    func subjectsBecomeDcSubjectElements() throws {
        let data = try MobiToEpubConverter.convert(content(subjects: ["Sci-Fi", "Dystopian"]))
        let archive = try archive(from: data)
        let opf = entryData(archive, "content.opf").flatMap { String(data: $0, encoding: .utf8) } ?? ""
        #expect(opf.contains("<dc:subject>Sci-Fi</dc:subject>"))
        #expect(opf.contains("<dc:subject>Dystopian</dc:subject>"))
    }

    @Test
    func outputIsDeterministic() throws {
        let content = content()
        let first = try MobiToEpubConverter.convert(content)
        let second = try MobiToEpubConverter.convert(content)
        #expect(first == second)
    }

    @Test
    func minimalContentProducesOpenableEpub() throws {
        let data = try MobiToEpubConverter.convert(
            MobiContent(
                title: "",
                authors: [],
                cover: nil,
                chapters: [MobiChapter(id: "chap1", title: nil, html: "")]
            )
        )
        let archive = try archive(from: data)
        #expect(entryData(archive, "mimetype") != nil)
        #expect(entryData(archive, "chap1.xhtml") != nil)
    }

    @Test
    func normalizedContentStripsWrapper() {
        let wrapped = """
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>T</title></head><body><h1>One</h1><p>Body text.</p></body></html>
        """
        let normalized = MobiToEpubConverter.normalizedContent(wrapped)
        #expect(normalized.contains("<h1>One</h1>"))
        #expect(normalized.contains("Body text."))
        #expect(!normalized.contains("<?xml"))
        #expect(!normalized.contains("<html"))
        #expect(!normalized.contains("<head>"))
        #expect(!normalized.contains("</html>"))

        // Already-clean content is returned trimmed and otherwise untouched.
        let clean = "<p>Hello</p>"
        #expect(MobiToEpubConverter.normalizedContent(clean) == clean)
    }
}
