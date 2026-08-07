import Foundation

/// Title/author normalization for duplicate detection: lowercase, strip all
/// non-alphanumerics. Shared by the file importer (`ImportService`) and the
/// Calibre import (`CalibreImportService`) — both must build identical keys,
/// and Calibre runs in the headless Linux package where Import/ is excluded.
enum TextNormalization {
    static func normalized(_ value: String) -> String {
        value.lowercased()
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }
}
