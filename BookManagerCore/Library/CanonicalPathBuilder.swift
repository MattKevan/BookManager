import Foundation

public enum CanonicalPathBuilder {
    public static func relativeDirectory(
        bookID: UUID,
        title: String,
        authors: [String]
    ) -> String {
        let author = sanitized(authors.first ?? "Unknown")
        let safeTitle = sanitized(title.isEmpty ? "Unknown" : title)
        let shortID = String(bookID.uuidString.prefix(8)).lowercased()
        return "\(author)/\(safeTitle) (\(shortID))"
    }

    private static func sanitized(_ value: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let scalars = value.unicodeScalars.map { forbidden.contains($0) ? "_" : Character($0) }
        let result = String(scalars)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return String((result.isEmpty ? "Unknown" : result).prefix(120))
    }
}
