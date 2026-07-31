import Foundation

public protocol LibraryRepositoryImporting: Sendable {
    func bookIDs(byFormatHash contentHash: String) async throws -> [UUID]
    func allBooksForDuplicateCheck() async throws -> [IndexedBook]
    func createBook(
        metadata: NewBookMetadata,
        staged: [BookFolder.StagedFile],
        cover: Data?
    ) async throws -> IndexedBook
}

public struct ImportItem: Sendable {
    public enum Status: Sendable {
        case imported(UUID)
        case duplicate(matchingBookID: UUID)
        case failed(String)
    }

    public let sourceURL: URL
    public let kind: FormatKind
    public let status: Status
    public let likelyDuplicateOf: UUID?

    public init(sourceURL: URL, kind: FormatKind, status: Status, likelyDuplicateOf: UUID? = nil) {
        self.sourceURL = sourceURL
        self.kind = kind
        self.status = status
        self.likelyDuplicateOf = likelyDuplicateOf
    }
}

public struct ImportReport: Sendable {
    public let items: [ImportItem]

    public init(items: [ImportItem]) {
        self.items = items
    }

    public var imported: [ImportItem] {
        items.filter { if case .imported = $0.status { return true }; return false }
    }

    public var duplicates: [ImportItem] {
        items.filter { if case .duplicate = $0.status { return true }; return false }
    }

    public var failed: [ImportItem] {
        items.filter { if case .failed = $0.status { return true }; return false }
    }

    public var summary: String {
        "\(imported.count) imported, \(duplicates.count) duplicates, \(failed.count) failed"
    }
}

public actor ImportService {
    private let folder: BookFolder

    public init(layout: LibraryLayout) {
        folder = BookFolder(layout: layout)
    }

    public func importFiles(
        _ sourceURLs: [URL],
        into repository: LibraryRepositoryImporting
    ) async throws -> ImportReport {
        var items: [ImportItem] = []
        for source in sourceURLs {
            guard let kind = MetadataExtractor.kind(for: source) else {
                items.append(ImportItem(
                    sourceURL: source,
                    kind: .epub,
                    status: .failed("Unsupported file type")
                ))
                continue
            }
            do {
                let metadata = try MetadataExtractor.extract(from: source, kind: kind)
                let cover = try MetadataExtractor.extractCover(from: source, kind: kind)
                let staged = try await folder.stage(from: source)

                let exactMatches = try await repository.bookIDs(byFormatHash: staged.contentHash)
                if let first = exactMatches.first {
                    // Exact duplicate: never copy silently, and never leave the
                    // staged copy behind — clean it up so staging does not leak.
                    try? FileManager.default.removeItem(at: staged.url)
                    items.append(ImportItem(
                        sourceURL: source, kind: kind,
                        status: .duplicate(matchingBookID: first)
                    ))
                    continue
                }

                var likelyDuplicate: UUID?
                if metadata.title.isEmpty == false {
                    let candidates = try await repository.allBooksForDuplicateCheck()
                    let normalized = Self.normalized(metadata.title)
                    let firstAuthor = metadata.authors.first.map(Self.normalized) ?? ""
                    likelyDuplicate = candidates.first {
                        Self.normalized($0.title) == normalized
                            && ($0.authors.first.map(Self.normalized) ?? "") == firstAuthor
                    }?.id
                }

                let book = try await repository.createBook(
                    metadata: newBookMetadata(from: metadata),
                    staged: [staged],
                    cover: cover
                )
                items.append(ImportItem(
                    sourceURL: source, kind: kind,
                    status: .imported(book.id),
                    likelyDuplicateOf: likelyDuplicate
                ))
            } catch {
                items.append(ImportItem(
                    sourceURL: source, kind: kind,
                    status: .failed(error.localizedDescription)
                ))
            }
        }
        return ImportReport(items: items)
    }

    static func normalized(_ value: String) -> String {
        value.lowercased()
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    /// `ExtractedMetadata` and `NewBookMetadata` are distinct types; the extractor
    /// result carries every field the repository accepts (rating stays unset).
    private func newBookMetadata(from extracted: ExtractedMetadata) -> NewBookMetadata {
        NewBookMetadata(
            title: extracted.title,
            authors: extracted.authors,
            series: extracted.series,
            seriesIndex: extracted.seriesIndex,
            tags: extracted.tags,
            rating: nil,
            publisher: extracted.publisher,
            publicationDate: extracted.publicationDate,
            languages: extracted.languages,
            identifiers: extracted.identifiers,
            comments: extracted.comments
        )
    }
}
