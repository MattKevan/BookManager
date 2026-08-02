import Foundation

public struct ReconciliationReport: Sendable, Equatable {
    public var renamed: [UUID] = []
    public var adopted: [UUID] = []
    public var conflictCopies: [URL] = []
    public var restoredFromTrash: [UUID] = []
    public var missingFolders: [UUID] = []
    public var errors: [String] = []

    public init() {}
}

/// Re-points on-disk book folders to the canonical paths derived from the
/// merged CRDT metadata, forks conflicts (never overwrites), and performs
/// basic trash/restore reconciliation. Runs after every ingest; all moves are
/// journaled via `BookFolder`.
///
/// Discovery: a book's folder is located by (1) its catalog path when it
/// differs from canonical, (2) the 8-char book-id prefix embedded in every
/// canonical folder name, and (3) content-hash matching for folders whose id
/// marker was lost (manual moves). Missing folders are recorded, never
/// fabricated.
public actor FolderReconciler {
    private let layout: LibraryLayout
    private let catalog: LocalCatalog
    private let folder: BookFolder
    private let deviceID: UUID

    public init(layout: LibraryLayout, catalog: LocalCatalog, deviceID: UUID) {
        self.layout = layout
        self.catalog = catalog
        folder = BookFolder(layout: layout)
        self.deviceID = deviceID
    }

    public func reconcile() async throws -> ReconciliationReport {
        var report = ReconciliationReport()
        // ONE root scan per pass: the folder index (all candidates in
        // enumeration order + a short-id prefix map) replaces the per-book
        // O(dirs) scans — O(N × dirs) → O(N + dirs).
        let index = await buildFolderIndex()
        let books = try await catalog.allBooks()
        for book in books {
            await reconcilePath(book, into: &report, index: index)
            await reconcileTrash(book, into: &report)
        }
        let deleted = try await catalog.deletedBooks()
        for book in deleted {
            await reconcileTrash(book, into: &report)
        }
        return report
    }

    // MARK: - Path reconciliation

    private func reconcilePath(_ book: IndexedBook, into report: inout ReconciliationReport, index: FolderIndex) async {
        // A book with no materialized folder (empty relativePath) must never
        // resolve to the library root — with empty formats `folderMatches` is
        // vacuously true and the root would be renamed or forked as if it were
        // the book folder (10k benchmark found a root-rename attempt). Surfaced
        // in errors; left inert. Production always materializes folders, so
        // this guard only sees malformed rows.
        let actualResolved = await folder.bookDirectoryURL(relativePath: book.relativePath)
            .resolvingSymlinksInPath().standardizedFileURL
        let rootResolved = layout.root.resolvingSymlinksInPath().standardizedFileURL
        guard !book.relativePath.isEmpty, actualResolved != rootResolved else {
            report.errors.append("book \(book.id): empty relativePath")
            return
        }

        let canonical = CanonicalPathBuilder.relativeDirectory(
            bookID: book.id, title: book.title, authors: book.authors
        )
        let canonicalURL = await folder.bookDirectoryURL(relativePath: canonical)
        let canonicalExists = FileManager.default.fileExists(atPath: canonicalURL.path)
        let canonicalMatches = canonicalExists ? await folderMatches(book, at: canonicalURL) : false

        if canonicalMatches {
            // Already reconciled; the catalog may still point elsewhere.
            if book.relativePath != canonical {
                report.adopted.append(book.id)
                await repoint(book, to: canonical, into: &report)
                // A leftover folder at the stale catalog path is a duplicate —
                // fork it (never delete).
                let stale = await folder.bookDirectoryURL(relativePath: book.relativePath)
                if FileManager.default.fileExists(atPath: stale.path) {
                    await forkFolder(book, at: stale, into: &report)
                }
            }
            return
        }

        guard !(await isTrashed(book.id)) else {
            // reconcileTrash restores it; nothing to re-point yet.
            return
        }

        guard let actualURL = await actualFolderURL(for: book, excluding: canonicalURL, index: index) else {
            report.missingFolders.append(book.id)
            return
        }

        if canonicalExists {
            // The canonical name is taken by different content: preserve it as
            // a conflict copy, then move the real folder into place.
            await forkFolder(book, at: canonicalURL, into: &report)
        }

        if await folderMatches(book, at: actualURL) {
            await renameToCanonical(book, from: actualURL, canonical: canonical, into: &report)
        } else {
            // The found folder doesn't hold the merged content either — fork it
            // too and surface the mismatch (never overwrite).
            await forkFolder(book, at: actualURL, into: &report)
            report.errors.append("content mismatch for \(book.id)")
        }
    }

    /// Locates the folder that actually holds the book's files, never the
    /// canonical folder itself (it is handled separately). The per-pass
    /// `index` makes discovery a lookup, not a per-book root enumeration.
    private func actualFolderURL(for book: IndexedBook, excluding excluded: URL, index: FolderIndex) async -> URL? {
        let canonical = CanonicalPathBuilder.relativeDirectory(
            bookID: book.id, title: book.title, authors: book.authors
        )
        let isExcluded: (URL) -> Bool = { url in
            url.resolvingSymlinksInPath().standardizedFileURL
                == excluded.resolvingSymlinksInPath().standardizedFileURL
        }
        // 1. The catalog path, when it differs from canonical and exists.
        if book.relativePath != canonical {
            let url = await folder.bookDirectoryURL(relativePath: book.relativePath)
            if !isExcluded(url), FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        // 2. Short-ID index lookup (canonical folder names embed the id
        // prefix). Never discover or re-fork our own conflict copies — they
        // embed the same prefix and would be forked again on the next pass if
        // the content-mismatch branch fires (unbounded folder growth).
        let shortID = String(book.id.uuidString.prefix(8)).lowercased()
        for url in index.byPrefix[shortID] ?? [] where !isExcluded(url) {
            if url.lastPathComponent.localizedCaseInsensitiveContains(" (conflict ")
                { continue }
            if url.lastPathComponent.localizedCaseInsensitiveContains(shortID) {
                return url
            }
        }
        // 3. Content-hash scan (a manual move loses the id marker). Books with
        // no formats match vacuously — skip hash discovery for them.
        guard !book.formats.isEmpty else { return nil }
        for url in index.all where !isExcluded(url) {
            if await folderMatches(book, at: url) {
                return url
            }
        }
        return nil
    }

    private func renameToCanonical(
        _ book: IndexedBook,
        from sourceURL: URL,
        canonical: String,
        into report: inout ReconciliationReport
    ) async {
        let sourcePath = relativePath(of: sourceURL)
        do {
            try await folder.rename(
                bookID: book.id,
                from: sourcePath,
                to: canonical,
                oldFormats: book.formats.map(Self.formatValue),
                newFormats: book.formats.map(Self.formatValue)
            )
            await repoint(book, to: canonical, into: &report)
            report.renamed.append(book.id)
        } catch {
            report.errors.append("rename \(book.id): \(error.localizedDescription)")
        }
    }

    private func forkFolder(_ book: IndexedBook, at url: URL, into report: inout ReconciliationReport) async {
        do {
            let forked = try await folder.forkConflict(bookID: book.id, relativePath: relativePath(of: url))
            report.conflictCopies.append(forked)
        } catch {
            report.errors.append("fork \(book.id): \(error.localizedDescription)")
        }
    }

    private func repoint(_ book: IndexedBook, to path: String, into report: inout ReconciliationReport) async {
        do {
            try await catalog.upsert(book.repointing(to: path))
        } catch {
            report.errors.append("upsert \(book.id): \(error.localizedDescription)")
        }
    }

    /// Whether every format file the catalog expects exists at `url` with the
    /// expected content hash.
    private func folderMatches(_ book: IndexedBook, at url: URL) async -> Bool {
        for format in book.formats {
            let fileURL = url.appending(path: format.filename)
            guard let data = try? Data(contentsOf: fileURL) else { return false }
            if BookFolder.contentHash(data) != format.contentHash { return false }
        }
        return true
    }

    // MARK: - Trash reconciliation

    private func reconcileTrash(_ book: IndexedBook, into report: inout ReconciliationReport) async {
        let trashURL = await folder.trashDirectoryURL(bookID: book.id)
        let inTrash = FileManager.default.fileExists(atPath: trashURL.path)
        if book.isDeleted {
            if !inTrash {
                let source = await folder.bookDirectoryURL(relativePath: book.relativePath)
                if FileManager.default.fileExists(atPath: source.path) {
                    do {
                        try await folder.trash(bookID: book.id, relativePath: book.relativePath)
                    } catch {
                        report.errors.append("trash \(book.id): \(error.localizedDescription)")
                    }
                }
            }
        } else if inTrash {
            do {
                _ = try await folder.restore(bookID: book.id, relativePath: book.relativePath)
                report.restoredFromTrash.append(book.id)
            } catch {
                report.errors.append("restore \(book.id): \(error.localizedDescription)")
            }
        }
    }

    private func isTrashed(_ bookID: UUID) async -> Bool {
        let trashURL = await folder.trashDirectoryURL(bookID: bookID)
        return FileManager.default.fileExists(atPath: trashURL.path)
    }

    // MARK: - Discovery helpers

    private func relativePath(of url: URL) -> String {
        // The enumerator yields /private/… paths while layout.root may be
        // /var/… (symlink); resolve both sides before comparing.
        let rootPath = layout.root.resolvingSymlinksInPath().path
        let path = url.resolvingSymlinksInPath().path
        let prefix = rootPath + "/"
        return path.hasPrefix(prefix)
            ? String(path.dropFirst(prefix.count))
            : url.lastPathComponent
    }

    /// One root scan per reconcile pass: every book-folder candidate in
    /// enumeration order, plus a map from each lowercased 8-char hex window of
    /// a folder name to the folders containing it. Per-book discovery is a
    /// lookup, not a per-book enumeration.
    private struct FolderIndex {
        let all: [URL]
        let byPrefix: [String: [URL]]
    }

    /// Enumerates the library root ONCE (`.skipsHiddenFiles` keeps the
    /// `.bookmanager` control tree out), collecting every directory plus the
    /// short-id prefixes its name embeds.
    private func buildFolderIndex() async -> FolderIndex {
        let manager = FileManager.default
        var all: [URL] = []
        var byPrefix: [String: [URL]] = [:]
        let enumerator = manager.enumerator(
            at: layout.root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        while let url = enumerator?.nextObject() as? URL {
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                continue
            }
            all.append(url)
            for prefix in Self.hexPrefixes(in: url.lastPathComponent) {
                byPrefix[prefix, default: []].append(url)
            }
        }
        return FolderIndex(all: all, byPrefix: byPrefix)
    }

    /// Every lowercased 8-char window of every maximal hex-character run in a
    /// folder name — exactly the substrings an 8-char book-id prefix can match
    /// via `localizedCaseInsensitiveContains` (see `actualFolderURL`).
    private static func hexPrefixes(in name: String) -> Set<String> {
        var runs: [String] = []
        var current = ""
        for scalar in name.lowercased().unicodeScalars {
            if scalar.properties.isHexDigit {
                current.unicodeScalars.append(scalar)
            } else {
                if current.count >= 8 { runs.append(current) }
                current = ""
            }
        }
        if current.count >= 8 { runs.append(current) }
        var prefixes: Set<String> = []
        for run in runs {
            let chars = Array(run)
            for start in 0...(chars.count - 8) {
                prefixes.insert(String(chars[start..<(start + 8)]))
            }
        }
        return prefixes
    }

    private static func formatValue(_ format: BookFormatRecord) -> BookFormatValue {
        BookFormatValue(
            kind: format.kind, filename: format.filename,
            contentHash: format.contentHash, size: format.size
        )
    }
}
