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

    /// MOBI-family extensions converted to EPUB before the standard pipeline.
    private static let mobiExtensions: Set<String> = ["mobi", "azw", "azw3"]

    public init(layout: LibraryLayout) {
        folder = BookFolder(layout: layout)
    }

    public func importFiles(
        _ sourceURLs: [URL],
        into repository: LibraryRepositoryImporting
    ) async throws -> ImportReport {
        var items: [ImportItem] = []
        for source in sourceURLs {
            // MOBI/AZW/AZW3 sources convert to a temp EPUB first, then flow
            // through the standard EPUB path against the temp file. The report
            // item keeps the ORIGINAL source URL so the UI shows the MOBI file.
            let prepared = Self.prepare(source)
            defer {
                if let temporaryDirectory = prepared.temporaryDirectory {
                    try? FileManager.default.removeItem(at: temporaryDirectory)
                }
            }
            guard let kind = prepared.kind else {
                items.append(ImportItem(
                    sourceURL: source,
                    kind: .epub,
                    status: .failed(prepared.failureMessage ?? "Unsupported file type")
                ))
                continue
            }
            do {
                var metadata = try MetadataExtractor.extract(from: prepared.url, kind: kind)
                if metadata.title.isEmpty, let fallback = prepared.fallbackTitle {
                    metadata.title = fallback
                }
                // MOBI covers come from the reader (the converted EPUB's OPF
                // does not declare a cover in its metadata/guide); non-MOBI
                // sources keep the extractor path.
                let cover: Data?
                if let mobiCover = prepared.cover {
                    cover = mobiCover
                } else {
                    cover = try MetadataExtractor.extractCover(from: prepared.url, kind: kind)
                }
                let staged = try await folder.stage(from: prepared.url)
                // materialize() consumes the staged copy on success; every other
                // exit (duplicate, throw) must remove it so the synced
                // .bookmanager/staging area never leaks files or empty per-import
                // directories.
                defer {
                    try? FileManager.default.removeItem(at: staged.url)
                    try? FileManager.default.removeItem(at: staged.url.deletingLastPathComponent())
                }

                let exactMatches = try await repository.bookIDs(byFormatHash: staged.contentHash)
                if let first = exactMatches.first {
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
                    status: .failed(Self.message(for: error))
                ))
            }
        }
        return ImportReport(items: items)
    }

    // MARK: - MOBI conversion

    private struct PreparedSource {
        /// The file the standard pipeline imports (the converted temp EPUB for
        /// MOBI sources, the original URL otherwise).
        let url: URL
        /// The import format; nil means the source can't be imported.
        let kind: FormatKind?
        /// A title to use when the extracted metadata title is empty (the
        /// original file's stem for MOBI sources).
        let fallbackTitle: String?
        /// The cover extracted by the MOBI reader (used directly, since the
        /// converted EPUB's OPF does not declare a cover).
        let cover: Data?
        /// A conversion failure message (DRM, unreadable) — the file is
        /// reported as failed with this message.
        let failureMessage: String?
        /// The temp directory holding the converted EPUB; removed after import.
        let temporaryDirectory: URL?
    }

    /// Resolves a source URL to the file the standard pipeline will import:
    /// MOBI-family files are converted to a temp EPUB. Non-MOBI files pass
    /// through unchanged.
    private static func prepare(_ source: URL) -> PreparedSource {
        guard mobiExtensions.contains(source.pathExtension.lowercased()) else {
            return PreparedSource(
                url: source,
                kind: MetadataExtractor.kind(for: source),
                fallbackTitle: nil,
                cover: nil,
                failureMessage: nil,
                temporaryDirectory: nil
            )
        }
        do {
            let content = try MobiReader(url: source).extract()
            let epubData = try MobiToEpubConverter.convert(content)
            let directory = FileManager.default.temporaryDirectory
                .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let baseName = source.deletingPathExtension().lastPathComponent
            let epubURL = directory.appending(path: "\(baseName).epub")
            try epubData.write(to: epubURL, options: .atomic)
            return PreparedSource(
                url: epubURL,
                kind: .epub,
                fallbackTitle: content.title.isEmpty ? baseName : nil,
                cover: content.cover,
                failureMessage: nil,
                temporaryDirectory: directory
            )
        } catch {
            return PreparedSource(
                url: source,
                kind: nil,
                fallbackTitle: nil,
                cover: nil,
                failureMessage: Self.message(for: error),
                temporaryDirectory: nil
            )
        }
    }

    /// A clear per-item failure message: DRM-protected MOBI files get an
    /// explicit reason instead of the generic error description.
    private static func message(for error: Error) -> String {
        if case MobiReaderError.drmProtected = error {
            return "DRM-protected book"
        }
        return error.localizedDescription
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
