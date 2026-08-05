import Foundation

public enum OpfGenerator {
    /// Minimal, portable OPF 2.0 projection of merged metadata. Not a synchronization authority.
    public static func opfData(bookID: UUID, resolved: ResolvedBook) -> Data {
        let shortID = String(bookID.uuidString.prefix(8)).lowercased()
        let seriesMeta: String
        if let series = resolved.series, !series.isEmpty {
            let index = resolved.seriesIndex.map { String($0) } ?? ""
            seriesMeta = """
                <meta name="calibre:series" content="\(escaped(series))"/><meta name="calibre:series_index" content="\(escaped(index))"/>
            """
        } else {
            seriesMeta = ""
        }
        let tags = resolved.tags.map { "<dc:subject>\(escaped($0))</dc:subject>" }.joined()
        let identifiers = resolved.identifiers.map { type, value in
            "<dc:identifier opf:scheme=\"\(escaped(type.uppercased()))\">\(escaped(value))</dc:identifier>"
        }.joined()

        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="bookid">
        <metadata>
        <dc:identifier opf:scheme="BOOKMANAGER" id="bookid">\(shortID)</dc:identifier>
        <dc:title>\(escaped(resolved.title))</dc:title>
        \(resolved.authors.map { "<dc:creator opf:role=\"aut\">\(escaped($0))</dc:creator>" }.joined(separator: "\n"))
        \(tags)
        \(identifiers)
        \(seriesMeta)
        </metadata>
        </package>
        """

        return Data(xml.utf8)
    }

    private static func escaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
