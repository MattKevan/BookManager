import Foundation
import libmobi

/// One extracted chapter of a MOBI book: the fragment's content markup (the
/// XHTML wrapper libmobi emits around each MOBI file is stripped) and, when a
/// heading or document title is present, a title.
public struct MobiChapter: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String?
    public let html: String

    public init(id: String, title: String?, html: String) {
        self.id = id
        self.title = title
        self.html = html
    }
}

/// The plain content model extracted from a MOBI/AZW/AZW3 file. Metadata is
/// empty when the source carries none (the reader degrades, never crashes).
public struct MobiContent: Sendable, Equatable {
    public let title: String
    public let authors: [String]
    public let cover: Data?
    public let chapters: [MobiChapter]

    public init(title: String, authors: [String], cover: Data?, chapters: [MobiChapter]) {
        self.title = title
        self.authors = authors
        self.cover = cover
        self.chapters = chapters
    }
}

public enum MobiReaderError: Error, Equatable {
    case drmProtected
    case unreadable(String)
}

/// Reads a MOBI/AZW/AZW3 file into a plain content model. DRM is detected
/// first via the record-0 `encryption_type` field (the same check libmobi's
/// `mobi_is_encrypted` performs), before the binding is consulted. The binding
/// object is created and used within `extract()` only (it is not Sendable),
/// so the reader is a lightweight Sendable struct.
public struct MobiReader: Sendable {
    private let url: URL

    public init(url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MobiReaderError.unreadable("file not found: \(url.lastPathComponent)")
        }
        self.url = url
    }

    public func extract() throws -> MobiContent {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw MobiReaderError.unreadable(error.localizedDescription)
        }

        // DRM detection first: encryption_type != 0 means an encrypted book.
        if Self.encryptionType(of: data).map({ $0 != 0 }) == true {
            throw MobiReaderError.drmProtected
        }

        let mobi: Mobi
        do {
            mobi = try Mobi(url: url)
        } catch {
            throw MobiReaderError.unreadable(error.localizedDescription)
        }

        let rawml: String
        do {
            rawml = try mobi.getRawml()
        } catch {
            throw MobiReaderError.unreadable(error.localizedDescription)
        }

        let cover = try? mobi.getCover()

        // Metadata: EXTH records first (the standard location), then the
        // rawml <dc:> block, then empty defaults.
        let exthTitle = ((try? mobi.getTitle()) ?? nil)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let exthAuthor = ((try? mobi.getAuthor()) ?? nil)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let dcTitle = Self.metadataTitle(from: rawml)
        let dcAuthors = Self.metadataCreators(from: rawml)

        let title = (exthTitle?.isEmpty == false ? exthTitle : dcTitle) ?? ""
        let authors: [String] = {
            if let exthAuthor, !exthAuthor.isEmpty {
                return [exthAuthor]
            }
            if !dcAuthors.isEmpty {
                return dcAuthors
            }
            return []
        }()

        return MobiContent(
            title: title,
            authors: authors,
            cover: cover,
            chapters: Self.chapters(from: rawml)
        )
    }

    // MARK: - Chapter decomposition

    /// Splits the rawml into chapters. libmobi's `getRawml` concatenates one
    /// XHTML fragment per MOBI file, each starting with an XML declaration;
    /// split on those boundaries. Older-style documents without fragment
    /// boundaries fall back to `<mbp:pagebreak>` markers. The per-fragment
    /// XHTML wrapper (`<?xml … </html>`) is stripped, leaving the content.
    private static func chapters(from rawml: String) -> [MobiChapter] {
        let fragments: [String]
        if rawml.contains("<?xml") {
            fragments = rawml.components(separatedBy: "<?xml")
                .enumerated()
                .compactMap { index, piece in
                    index == 0 ? nil : "<?xml" + piece
                }
        } else {
            fragments = rawml.components(separatedBy: "<mbp:pagebreak")
        }
        return fragments.enumerated().compactMap { index, fragment in
            let content = strippedContent(fragment)
            guard !content.isEmpty else { return nil }
            let title = chapterTitle(from: content) ?? documentTitle(from: fragment)
            return MobiChapter(id: "chap\(index + 1)", title: title, html: content)
        }
    }

    /// Removes everything up to and including the fragment's XHTML wrapper
    /// (`</html>`), leaving the heading/paragraph content that follows it.
    private static func strippedContent(_ fragment: String) -> String {
        let trimmed = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = trimmed.range(of: "</html>", options: .caseInsensitive) {
            return String(trimmed[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    private static func chapterTitle(from content: String) -> String? {
        for tag in ["h1", "h2", "h3"] {
            if let text = elementText(content, tag: tag) {
                return text
            }
        }
        return nil
    }

    private static func documentTitle(from fragment: String) -> String? {
        elementText(fragment, tag: "title")
    }

    /// The inner text of the first `<tag …>…</tag>` match, tags stripped.
    private static func elementText(_ html: String, tag: String) -> String? {
        let pattern = "<\(tag)[^>]*>(.*?)</\(tag)>"
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ), let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)) else {
            return nil
        }
        guard let range = Range(match.range(at: 1), in: html) else { return nil }
        let stripped = String(html[range])
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? nil : stripped
    }

    // MARK: - Rawml <dc:> metadata

    private static func metadataTitle(from rawml: String) -> String? {
        elementText(rawml, tag: "dc:Title") ?? elementText(rawml, tag: "dc:title")
    }

    private static func metadataCreators(from rawml: String) -> [String] {
        let pattern = "<dc:Creator[^>]*>(.*?)</dc:Creator>"
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return []
        }
        let range = NSRange(rawml.startIndex..., in: rawml)
        let matches = regex.matches(in: rawml, range: range)
        return matches.compactMap { match in
            guard let range = Range(match.range(at: 1), in: rawml) else { return nil }
            let stripped = String(rawml[range])
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return stripped.isEmpty ? nil : stripped
        }
    }

    // MARK: - DRM detection

    /// Reads the record-0 `encryption_type` field (MOBIRecord0Header byte 12),
    /// mirroring libmobi's `mobi_is_encrypted` for the mobipocket subset:
    /// nil when the file isn't a mobipocket (PDB type BOOK / creator MOBI) or
    /// the header can't be read.
    private static func encryptionType(of data: Data) -> UInt16? {
        guard data.count >= 82 else { return nil }
        let type = String(data: data[60..<64], encoding: .ascii) ?? ""
        let creator = String(data: data[64..<68], encoding: .ascii) ?? ""
        guard type == "BOOK", creator == "MOBI" else { return nil }
        guard u16(data, 76) > 0 else { return nil }
        let firstRecordOffset = u32(data, 78)
        let encryptionOffset = firstRecordOffset + 12
        guard data.count >= encryptionOffset + 2 else { return nil }
        return u16(data, encryptionOffset)
    }

    private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
    }

    private static func u32(_ data: Data, _ offset: Int) -> Int {
        Int(data[offset]) << 24 | Int(data[offset + 1]) << 16
            | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
    }
}
