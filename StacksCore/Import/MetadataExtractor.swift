import Foundation
import PDFKit
import UniformTypeIdentifiers
import ZIPFoundation

public enum FormatKind: String, Sendable {
    case epub = "EPUB"
    case pdf = "PDF"
    case djvu = "DJVU"
}

public struct ExtractedMetadata: Equatable, Sendable {
    public var title: String
    public var authors: [String]
    public var series: String?
    public var seriesIndex: Double?
    public var tags: [String]
    public var publisher: String?
    public var publicationDate: Date?
    public var languages: [String]
    public var identifiers: [String: String]
    public var comments: String?

    public init(
        title: String,
        authors: [String] = [],
        series: String? = nil,
        seriesIndex: Double? = nil,
        tags: [String] = [],
        publisher: String? = nil,
        publicationDate: Date? = nil,
        languages: [String] = [],
        identifiers: [String: String] = [:],
        comments: String? = nil
    ) {
        self.title = title
        self.authors = authors
        self.series = series
        self.seriesIndex = seriesIndex
        self.tags = tags
        self.publisher = publisher
        self.publicationDate = publicationDate
        self.languages = languages
        self.identifiers = identifiers
        self.comments = comments
    }
}

public enum MetadataExtractor {
    public static func kind(for url: URL) -> FormatKind? {
        switch url.pathExtension.lowercased() {
        case "epub": return .epub
        case "pdf": return .pdf
        case "djvu", "djv": return .djvu
        default: return nil
        }
    }

    public static func extract(from url: URL, kind: FormatKind) throws -> ExtractedMetadata {
        switch kind {
        case .epub:
            return try extractEPUB(from: url)
        case .pdf:
            return extractPDF(from: url)
        case .djvu:
            return extractFromFilename(url)
        }
    }

    public static func extractCover(from url: URL, kind: FormatKind) throws -> Data? {
        switch kind {
        case .epub:
            return try extractEPUBCover(from: url)
        case .pdf:
            return try renderPDFFirstPage(from: url)
        case .djvu:
            return nil
        }
    }

    // MARK: - EPUB

    private static func extractEPUB(from url: URL) throws -> ExtractedMetadata {
        guard let archive = try? Archive(url: url, accessMode: .read, pathEncoding: nil) else {
            throw ImportError.cannotOpenArchive(url)
        }
        guard let opfPath = try opfPath(in: archive) else {
            return extractFromFilename(url)
        }
        guard let opfData = try entryData(in: archive, path: opfPath) else {
            return extractFromFilename(url)
        }
        let parser = OPFParser()
        parser.parse(data: opfData)
        return parser.metadata ?? extractFromFilename(url)
    }

    private static func extractEPUBCover(from url: URL) throws -> Data? {
        guard let archive = try? Archive(url: url, accessMode: .read, pathEncoding: nil) else { return nil }
        guard let opfPath = try opfPath(in: archive),
              let opfData = try entryData(in: archive, path: opfPath) else {
            return nil
        }
        let parser = OPFParser()
        parser.parse(data: opfData)
        guard let coverPath = parser.coverPath else { return nil }
        let directory = (opfPath as NSString).deletingLastPathComponent
        let resolved = directory.isEmpty ? coverPath : "\(directory)/\(coverPath)"
        guard let data = try entryData(in: archive, path: resolved) else { return nil }
        return normalizeToJPEG(data)
    }

    // MARK: - PDF

    private static func extractPDF(from url: URL) -> ExtractedMetadata {
        guard let document = PDFDocument(url: url) else {
            return extractFromFilename(url)
        }
        let attributes = document.documentAttributes ?? [:]
        let title = (attributes[PDFDocumentAttribute.titleAttribute] as? String)
            .flatMap { $0.isEmpty ? nil : $0 } ?? url.deletingPathExtension().lastPathComponent
        let author = (attributes[PDFDocumentAttribute.authorAttribute] as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
        let keywords = (attributes[PDFDocumentAttribute.keywordsAttribute] as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
        let subject = (attributes[PDFDocumentAttribute.subjectAttribute] as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
        return ExtractedMetadata(
            title: title,
            authors: author.map { [$0] } ?? [],
            tags: keywords.map { [$0] } ?? [],
            publicationDate: nil,
            comments: subject
        )
    }

    private static func renderPDFFirstPage(from url: URL) throws -> Data? {
        guard let document = PDFDocument(url: url),
              let page = document.page(at: 0) else {
            return nil
        }
        let bounds = page.bounds(for: .mediaBox)
        let scale = min(1, 600 / max(bounds.width, bounds.height))
        let width = Int(bounds.width * scale)
        let height = Int(bounds.height * scale)
        guard width > 0, height > 0,
              let context = CGContext(
                  data: nil, width: width, height: height,
                  bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        context.restoreGState()
        guard let image = context.makeImage() else { return nil }
        return normalizeToJPEG(CGImageToData(image))
    }

    // MARK: - DJVU and fallback

    private static func extractFromFilename(_ url: URL) -> ExtractedMetadata {
        ExtractedMetadata(title: url.deletingPathExtension().lastPathComponent)
    }

    // MARK: - helpers

    private static func opfPath(in archive: Archive) throws -> String? {
        guard let containerData = try entryData(in: archive, path: "META-INF/container.xml"),
              let containerString = String(data: containerData, encoding: .utf8) else {
            return nil
        }
        guard let range = containerString.range(of: "full-path=\"") else { return nil }
        let remainder = containerString[range.upperBound...]
        guard let end = remainder.firstIndex(of: "\"") else { return nil }
        return String(remainder[..<end])
    }

    private static func entryData(in archive: Archive, path: String) throws -> Data? {
        guard let entry = archive[path] else { return nil }
        // A hostile or mis-encoded archive must not buffer gigabytes: a cover
        // or metadata entry larger than 64 MB is treated as absent (metadata
        // degrades gracefully) instead of being extracted whole.
        guard entry.uncompressedSize <= maxExtractableEntrySize else { return nil }
        var data = Data()
        _ = try archive.extract(entry) { chunk in
            data.append(chunk)
        }
        return data
    }

    /// The largest archive entry `entryData` extracts (covers are typically a
    /// few MB; 64 MB is generous headroom).
    private static let maxExtractableEntrySize: Int64 = 64 << 20

    private static func normalizeToJPEG(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        return CGImageToData(image)
    }

    private static func CGImageToData(_ image: CGImage) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}

public enum ImportError: Error, Equatable {
    case cannotOpenArchive(URL)
}

/// Minimal OPF 2.0 metadata parser built on XMLParser.
private final class OPFParser: NSObject, XMLParserDelegate {
    private enum Element: String {
        case title, creator, language, subject, description, identifier, date, meta
    }

    private var currentElement: String?
    private var textBuffer = ""
    private var inMetadata = false
    private var metadataFound = false
    private var opfScheme: String?

    var metadata: ExtractedMetadata?
    var coverPath: String?
    private var manifestItems: [(id: String, href: String, properties: String)] = []

    func parse(data: Data) {
        let parser = XMLParser(data: data)
        parser.delegate = self
        // OPF metadata lives in the dc: namespace; process namespaces so element
        // names arrive unprefixed ("title", "identifier", …) and match Element.
        parser.shouldProcessNamespaces = true
        parser.parse()
        guard metadataFound else { return }

        let identifiers = resolvedIdentifiers()
        let coverID = resolvedCoverID()
        coverPath = manifestItems.first { $0.id == coverID }?.href

        metadata = ExtractedMetadata(
            title: values[.title]?.first ?? "",
            authors: values[.creator] ?? [],
            series: metas["calibre:series"],
            seriesIndex: metas["calibre:series_index"].flatMap(Double.init),
            tags: values[.subject] ?? [],
            publicationDate: values[.date]?.first.flatMap { Self.parseDate($0) },
            languages: values[.language] ?? [],
            identifiers: identifiers,
            comments: values[.description]?.first
        )
    }

    private var values: [Element: [String]] = [:]
    private var metas: [String: String] = [:]
    private var identifierItems: [(scheme: String?, value: String)] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName
        textBuffer = ""
        if elementName == "metadata" { inMetadata = true }
        if elementName == "meta" {
            if let name = attributeDict["name"], let content = attributeDict["content"] {
                metas[name] = content
            }
        }
        if elementName == "identifier" {
            opfScheme = attributeDict["opf:scheme"] ?? attributeDict["scheme"]
        }
        if elementName == "item" {
            manifestItems.append((
                id: attributeDict["id"] ?? "",
                href: attributeDict["href"] ?? "",
                properties: attributeDict["properties"] ?? ""
            ))
        }
    }

    func parser(
        _ parser: XMLParser,
        foundCharacters string: String
    ) {
        textBuffer += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard inMetadata else { return }
        if elementName == "metadata" {
            inMetadata = false
            metadataFound = true
            return
        }
        let value = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        if let element = Element(rawValue: elementName) {
            if element == .identifier {
                identifierItems.append((scheme: opfScheme, value: value))
            } else {
                values[element, default: []].append(value)
            }
        }
    }

    private func resolvedIdentifiers() -> [String: String] {
        var result: [String: String] = [:]
        for item in identifierItems {
            let scheme = (item.scheme ?? "id").lowercased()
            if result[scheme] == nil {
                result[scheme] = item.value
            }
        }
        return result
    }

    private func resolvedCoverID() -> String {
        if let cover = metas["cover"] { return cover }
        if let item = manifestItems.first(where: { $0.properties.contains("cover-image") }) {
            return item.id
        }
        if let item = manifestItems.first(where: { $0.id.lowercased() == "cover" }) {
            return item.id
        }
        return ""
    }

    private static func parseDate(_ string: String) -> Date? {
        let formatters: [ISO8601DateFormatter] = [.init(), .init()]
        formatters[1].formatOptions = [.withFullDate]
        return formatters.compactMap { $0.date(from: string) }.first
    }
}
