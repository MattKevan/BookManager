import CryptoKit
import Foundation
import ZIPFoundation

/// Builds a deterministic EPUB 2 archive from extracted MOBI content.
/// Structure mirrors the app's OPF conventions (see `OpfGenerator`); the
/// archive is built in-memory so the converter is pure (MobiContent → Data).
public enum MobiToEpubConverter {

    /// A fixed modification date for every archive entry so identical input
    /// produces byte-identical output (deterministic builds).
    private static let entryDate = Date(timeIntervalSince1970: 1_700_000_000)

    public static func convert(_ content: MobiContent) throws -> Data {
        let archive = try Archive(data: Data(), accessMode: .create)
        try add(entry: "mimetype", data: Data("application/epub+zip".utf8), archive: archive, compression: .none)
        try add(entry: "META-INF/container.xml", data: containerData, archive: archive)
        try add(entry: "content.opf", data: opfData(content: content), archive: archive)
        try add(entry: "toc.ncx", data: ncxData(content: content), archive: archive)
        if let cover = content.cover {
            try add(entry: "cover.jpg", data: cover, archive: archive)
        }
        for chapter in content.chapters {
            try add(
                entry: "\(chapter.id).xhtml",
                data: chapterData(chapter: chapter),
                archive: archive
            )
        }
        return archive.data ?? Data()
    }

    private static func add(
        entry path: String,
        data: Data,
        archive: Archive,
        compression: CompressionMethod = .deflate
    ) throws {
        try archive.addEntry(
            with: path,
            type: .file,
            uncompressedSize: Int64(data.count),
            modificationDate: entryDate,
            compressionMethod: compression
        ) { position, size in
            let lower = Int(position)
            let upper = min(lower + Int(size), data.count)
            guard lower < upper else { return Data() }
            return Data(data[lower..<upper])
        }
    }

    // MARK: - Documents

    private static var containerData: Data {
        Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
        <rootfiles><rootfile full-path="content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """.utf8)
    }

    private static func opfData(content: MobiContent) -> Data {
        let uid = stableID(content)
        let creators = content.authors
            .map { "<dc:creator opf:role=\"aut\">\(escaped($0))</dc:creator>" }
            .joined()
        let manifestChapters = content.chapters
            .map { chapter in
                "<item id=\"\(chapter.id)\" href=\"\(chapter.id).xhtml\" media-type=\"application/xhtml+xml\"/>"
            }
            .joined(separator: "\n")
        let spineChapters = content.chapters
            .map { "<itemref idref=\"\($0.id)\"/>" }
            .joined()
        let coverItem = content.cover == nil
            ? ""
            : "<item id=\"cover\" href=\"cover.jpg\" media-type=\"image/jpeg\"/>"
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="bookid">
        <metadata>
        <dc:identifier opf:scheme="BOOKMANAGER" id="bookid">\(uid)</dc:identifier>
        <dc:title>\(escaped(content.title))</dc:title>
        \(creators)
        </metadata>
        <manifest>
        <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
        \(coverItem)
        \(manifestChapters)
        </manifest>
        <spine toc="ncx">
        \(spineChapters)
        </spine>
        </package>
        """
        return Data(xml.utf8)
    }

    private static func ncxData(content: MobiContent) -> Data {
        let uid = stableID(content)
        let navPoints = content.chapters.enumerated()
            .map { index, chapter in
                let title = escaped(chapter.title ?? "Chapter \(index + 1)")
                return """
                <navPoint id="np\(index + 1)" playOrder="\(index + 1)"><navLabel><text>\(title)</text></navLabel><content src="\(chapter.id).xhtml"/></navPoint>
                """
            }
            .joined(separator: "\n")
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
        <head><meta name="dtb:uid" content="\(uid)"/></head>
        <docTitle><text>\(escaped(content.title))</text></docTitle>
        <navMap>
        \(navPoints)
        </navMap>
        </ncx>
        """
        return Data(xml.utf8)
    }

    private static func chapterData(chapter: MobiChapter) -> Data {
        let title = escaped(chapter.title ?? "")
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head><title>\(title)</title></head>
        <body>
        \(normalizedContent(chapter.html))
        </body>
        </html>
        """
        return Data(xml.utf8)
    }

    // MARK: - Chapter normalization

    /// Strips a leading XML declaration and an outer `<html>…</html>` /
    /// `<body>…</body>` wrapper so the chapter embeds cleanly in the EPUB's
    /// own minimal XHTML document. Already-clean content is returned trimmed.
    /// Internal so the decomposition is directly unit-tested with synthetic
    /// fragments (the `MobiReader` body-embedded fallback keeps the wrapper).
    static func normalizedContent(_ html: String) -> String {
        var value = html.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("<?xml"), let end = value.range(of: "?>") {
            value = String(value[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        value = stripOuterTag(value, tag: "html")
        value = stripLeadingBlock(value, tag: "head")
        value = stripOuterTag(value, tag: "body")
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes a `<head>…</head>` block wherever it appears (metadata that
    /// would otherwise survive the html/body wrapper strip — the body open
    /// tag is not at the value's start when a head precedes it).
    private static func stripLeadingBlock(_ value: String, tag: String) -> String {
        guard let openRange = value.range(of: "<\(tag)(\\s[^>]*)?>", options: .regularExpression),
              let closeRange = value.range(of: "</\(tag)>", options: [.caseInsensitive]) else {
            return value
        }
        var result = value
        result.removeSubrange(openRange.lowerBound..<closeRange.upperBound)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes a single outer `<tag …>…</tag>` pair when it spans the whole
    /// value; otherwise returns the value unchanged.
    private static func stripOuterTag(_ value: String, tag: String) -> String {
        guard let openRange = value.range(
            of: "<\(tag)(\\s[^>]*)?>",
            options: .regularExpression,
            range: value.startIndex..<value.endIndex
        ), openRange.lowerBound == value.startIndex else {
            return value
        }
        guard let closeRange = value.range(
            of: "</\(tag)>",
            options: [.caseInsensitive, .backwards]
        ), closeRange.upperBound == value.endIndex else {
            return value
        }
        return String(value[openRange.upperBound..<closeRange.lowerBound])
    }

    // MARK: - Helpers

    /// A short deterministic identifier derived from the content, so identical
    /// input yields identical output end to end.
    static func stableID(_ content: MobiContent) -> String {
        let seed = "\(content.title)\u{0}\(content.authors.joined(separator: "\u{1}"))\u{0}\(content.chapters.count)"
        let digest = SHA256.hash(data: Data(seed.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined().prefix(16)
        return "mobi-" + String(hex)
    }

    private static func escaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
