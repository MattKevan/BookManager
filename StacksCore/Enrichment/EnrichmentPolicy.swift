import Foundation

/// Decides which books qualify for automatic metadata enrichment.
public enum EnrichmentPolicy {
    /// A book needs enrichment when it is missing authors or tags. The
    /// `"Unknown"` placeholder (the import fallback when extraction finds no
    /// author — e.g. an EPUB whose OPF lacks `dc:creator`) also counts as
    /// missing so placeholder authors can be replaced with real ones.
    public static func needsEnrichment(_ book: IndexedBook) -> Bool {
        book.authors.isEmpty
            || book.authors.allSatisfy { $0 == "Unknown" }
            || book.tags.isEmpty
    }
}
