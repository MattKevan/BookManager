import CoreGraphics
import Foundation
import ImageIO
import ZIPFoundation

enum Fixtures {
    /// A minimal EPUB 2.0 archive with one book and a cover PNG.
    static func makeEPUB(named name: String = "book.epub") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: name)
        try? FileManager.default.removeItem(at: url)
        let archive = try Archive(url: url, accessMode: .create)
        try archive.addEntry(
            with: "mimetype", type: .file, uncompressedSize: Int64(20),
            compressionMethod: .none,
            provider: { _, _ in Data("application/epub+zip".utf8) }
        )
        let container = """
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """
        try archive.addEntry(
            with: "META-INF/container.xml", type: .file,
            uncompressedSize: Int64(container.utf8.count),
            provider: { _, _ in Data(container.utf8) }
        )
        let opf = """
        <?xml version="1.0" encoding="utf-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/" version="2.0" unique-identifier="uid">
        <metadata>
          <dc:identifier id="uid" opf:scheme="ISBN">978-0-7352-2129-1</dc:identifier>
          <dc:title>Range: Why Generalists Triumph in a Specialized World</dc:title>
          <dc:creator opf:role="aut">David Epstein</dc:creator>
          <dc:language>eng</dc:language>
          <dc:date>2019-05-28</dc:date>
          <dc:subject>Science</dc:subject>
          <dc:description>Why generalists beat specialists.</dc:description>
          <meta name="calibre:series" content="Studies"/>
          <meta name="calibre:series_index" content="1.5"/>
          <meta name="cover" content="cover-image"/>
        </metadata>
        <manifest>
          <item id="cover-image" href="cover.png" media-type="image/png" properties="cover-image"/>
          <item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>
        </manifest>
        </package>
        """
        try archive.addEntry(
            with: "OEBPS/content.opf", type: .file,
            uncompressedSize: Int64(opf.utf8.count),
            provider: { _, _ in Data(opf.utf8) }
        )
        let coverPNG = Fixtures.png1x1()
        try archive.addEntry(
            with: "OEBPS/cover.png", type: .file,
            uncompressedSize: Int64(coverPNG.count),
            provider: { _, _ in coverPNG }
        )
        try archive.addEntry(
            with: "OEBPS/chapter.xhtml", type: .file,
            uncompressedSize: Int64(Data("<p/>".utf8).count),
            provider: { _, _ in Data("<p/>".utf8) }
        )
        return url
    }

    /// A one-page PDF with no embedded metadata, rendered via a CoreGraphics PDF context.
    static func makePDF(named name: String = "plain.pdf") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: name)
        try? FileManager.default.removeItem(at: url)
        var mediaBox = CGRect(x: 0, y: 0, width: 300, height: 400)
        let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil)!
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(mediaBox)
        context.endPDFPage()
        context.closePDF()
        return url
    }

    static func png1x1() -> Data {
        // 1x1 transparent PNG bytes.
        let base64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
        return Data(base64Encoded: base64)!
    }

    static func jpeg1x1() throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.1, green: 0.4, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        let image = context.makeImage()!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}
