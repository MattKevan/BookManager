import Foundation

public actor LibraryRepository: LibraryRepositoryImporting {
    public nonisolated let manifest: LibraryManifest
    public nonisolated let root: URL

    private let layout: LibraryLayout
    private let changeStore: ChangeStore
    private let catalog: LocalCatalog
    private let folder: BookFolder
    private let deviceID: UUID

    private init(
        manifest: LibraryManifest,
        layout: LibraryLayout,
        catalog: LocalCatalog,
        deviceID: UUID
    ) {
        self.manifest = manifest
        root = layout.root
        self.layout = layout
        changeStore = ChangeStore(layout: layout)
        folder = BookFolder(layout: layout)
        self.catalog = catalog
        self.deviceID = deviceID
    }

    public static func create(
        at root: URL,
        indexesDirectory: URL,
        deviceID: UUID
    ) async throws -> LibraryRepository {
        let layout = LibraryLayout(root: root)
        // Refuse to create over an existing library: writing a fresh manifest
        // would change its identity and fork the library. Settings > Create
        // New / Cmd+Shift+N over an existing folder surfaces this as an error
        // instead of silently damaging it.
        guard !FileManager.default.fileExists(atPath: layout.manifestURL.path) else {
            throw LibraryRepositoryError.libraryAlreadyExists
        }
        let manifest = LibraryManifest(id: UUID())
        try layout.create(manifest: manifest)
        return try LibraryRepository(
            manifest: manifest,
            layout: layout,
            catalog: LocalCatalog(
                databaseURL: indexesDirectory.appending(path: "\(manifest.id.uuidString).sqlite")
            ),
            deviceID: deviceID
        )
    }

    public static func open(
        at root: URL,
        indexesDirectory: URL,
        deviceID: UUID
    ) async throws -> LibraryRepository {
        let layout = LibraryLayout(root: root)
        let manifest = try layout.readManifest()
        guard manifest.formatVersion == 1 else {
            throw LibraryRepositoryError.unsupportedFormat(manifest.formatVersion)
        }
        let repository = try LibraryRepository(
            manifest: manifest,
            layout: layout,
            catalog: LocalCatalog(
                databaseURL: indexesDirectory.appending(path: "\(manifest.id.uuidString).sqlite")
            ),
            deviceID: deviceID
        )
        try await repository.rebuildCatalog()
        return repository
    }

    // MARK: - Staging

    public func stageFile(from sourceURL: URL) async throws -> BookFolder.StagedFile {
        try await folder.stage(from: sourceURL)
    }

    // MARK: - Creating books

    @discardableResult
    public func createBook(
        metadata: NewBookMetadata,
        staged: [BookFolder.StagedFile],
        cover: Data?
    ) async throws -> IndexedBook {
        let bookID = UUID()
        let document = try AutomergeBookDocument.new(bookID: bookID, deviceID: deviceID)

        var written: [URL] = []
        do {
            written = try await writeChanges(
                metadata: metadata, document: document, bookID: bookID, staged: staged, cover: cover
            )
            let resolved = try document.resolvedBook()
            let materialized = try await folder.materialize(
                bookID: bookID,
                resolved: resolved,
                staged: staged,
                cover: cover
            )
            let indexed = try makeIndexedBook(document, relativePath: materialized.path)
            try await catalog.upsert(indexed)
            return indexed
        } catch {
            // A failed create must not leave half of the book's change files
            // durable: the catalog has no row for them, so the next rebuild
            // would resurrect a book the caller was told failed to create.
            for url in written {
                try? FileManager.default.removeItem(at: url)
            }
            throw error
        }
    }

    /// Slice 1 compatibility: create a book with title and authors only.
    @discardableResult
    public func createBook(
        title: String,
        authors: [String],
        at date: Date = .now
    ) async throws -> IndexedBook {
        try await createBook(
            metadata: NewBookMetadata(title: title, authors: authors),
            staged: [],
            cover: nil
        )
    }

    // MARK: - Editing

    public func updateBook(id: UUID, edit: BookEdit) async throws -> IndexedBook {
        guard let indexed = try await catalog.book(id: id) else {
            throw LibraryRepositoryError.bookNotFound(id)
        }
        let document = try AutomergeBookDocument(snapshot: indexed.snapshot, deviceID: deviceID)
        // Seed the edit's clocks from the document's latest clock: a fresh
        // (0, 0) clock would emit equal clocks for two same-millisecond edits,
        // making the LWW tie-break arbitrary.
        var clock = try document.latestClock() ?? HybridLogicalClock(nodeID: deviceID)
        let changes = try document.apply(edit, clock: clock, date: .now)
        var written: [URL] = []
        do {
            for change in changes {
                let result = try await changeStore.writeBookChange(
                    change, bookID: id, deviceID: deviceID, clock: clock.tick()
                )
                if result.created { written.append(result.url) }
            }

            let resolved = try document.resolvedBook()
            let newPath = CanonicalPathBuilder.relativeDirectory(
                bookID: id, title: resolved.title, authors: resolved.authors
            )
            if newPath != indexed.relativePath {
                try await folder.rename(
                    bookID: id,
                    from: indexed.relativePath,
                    to: newPath,
                    oldFormats: indexed.formats.map {
                        BookFormatValue(kind: $0.kind, filename: $0.filename, contentHash: $0.contentHash, size: $0.size)
                    },
                    newFormats: resolved.formats
                )
            }
            // metadata.opf is a derived sidecar of the resolved metadata: keep it in
            // sync on every successful edit, not only when the canonical path moves.
            // Create the folder when it is absent (synced book not yet materialized)
            // instead of failing the whole edit over a sidecar write.
            let directory = await folder.bookDirectoryURL(relativePath: newPath)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try OpfGenerator.opfData(bookID: id, resolved: resolved)
                .write(to: directory.appending(path: "metadata.opf"), options: .atomic)
            let updated = try makeIndexedBook(document, relativePath: newPath)
            try await catalog.upsert(updated)
            return updated
        } catch {
            // The changes were persisted but a later step failed (rename, sidecar
            // write, catalog upsert): roll the just-written change files back so the
            // catalog snapshot never goes stale relative to the authoritative store
            // (a stale snapshot makes the NEXT edit apply on an outdated base and
            // silently revert this one).
            for url in written {
                try? FileManager.default.removeItem(at: url)
            }
            throw error
        }
    }

    /// Writes a cover for a book: a `setCover` Automerge change, a materialized
    /// `cover.jpg` in the book folder (atomic write), and a catalog upsert.
    /// Used by metadata enrichment's cover downloads. Mirrors `createBook`'s
    /// cover handling and `updateBook`'s change/materialize/upsert shape.
    public func updateCover(coverData: Data, for bookID: UUID) async throws -> IndexedBook {
        guard let indexed = try await catalog.book(id: bookID) else {
            throw LibraryRepositoryError.bookNotFound(bookID)
        }
        let document = try AutomergeBookDocument(snapshot: indexed.snapshot, deviceID: deviceID)
        var clock = try document.latestClock() ?? HybridLogicalClock(nodeID: deviceID)
        let change = try document.setCover(
            CoverValue(filename: "cover.jpg", contentHash: BookFolder.contentHash(coverData)),
            clock: clock.tick()
        )
        var written: URL?
        do {
            let result = try await changeStore.writeBookChange(
                change, bookID: bookID, deviceID: deviceID, clock: clock
            )
            if result.created { written = result.url }

            let directory = await folder.bookDirectoryURL(relativePath: indexed.relativePath)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try coverData.write(to: directory.appending(path: "cover.jpg"), options: .atomic)
            let updated = try makeIndexedBook(document, relativePath: indexed.relativePath)
            try await catalog.upsert(updated)
            return updated
        } catch {
            if let written {
                try? FileManager.default.removeItem(at: written)
            }
            throw error
        }
    }

    // MARK: - Delete and restore

    public func deleteBook(id: UUID) async throws {
        guard let indexed = try await catalog.book(id: id) else {
            throw LibraryRepositoryError.bookNotFound(id)
        }
        let document = try AutomergeBookDocument(snapshot: indexed.snapshot, deviceID: deviceID)
        var clock = try document.latestClock() ?? HybridLogicalClock(nodeID: deviceID)
        let change = try document.setDeleted(true, clock: clock.tick())
        var written: URL?
        do {
            let result = try await changeStore.writeBookChange(
                change, bookID: id, deviceID: deviceID, clock: clock
            )
            if result.created { written = result.url }
            try await folder.trash(bookID: id, relativePath: indexed.relativePath)
            let deleted = try makeIndexedBook(document, relativePath: indexed.relativePath)
            try await catalog.upsert(deleted)
        } catch {
            if let written {
                try? FileManager.default.removeItem(at: written)
            }
            throw error
        }
    }

    public func restoreBook(id: UUID) async throws -> IndexedBook {
        guard let indexed = try await catalog.book(id: id) else {
            throw LibraryRepositoryError.bookNotFound(id)
        }
        let document = try AutomergeBookDocument(snapshot: indexed.snapshot, deviceID: deviceID)
        var clock = try document.latestClock() ?? HybridLogicalClock(nodeID: deviceID)
        let change = try document.setDeleted(false, clock: clock.tick())
        var written: URL?
        do {
            let result = try await changeStore.writeBookChange(
                change, bookID: id, deviceID: deviceID, clock: clock
            )
            if result.created { written = result.url }
            let resolved = try document.resolvedBook()
            let path = CanonicalPathBuilder.relativeDirectory(
                bookID: id, title: resolved.title, authors: resolved.authors
            )
            _ = try await folder.restore(bookID: id, relativePath: path)
            let restored = try makeIndexedBook(document, relativePath: path)
            try await catalog.upsert(restored)
            return restored
        } catch {
            if let written {
                try? FileManager.default.removeItem(at: written)
            }
            throw error
        }
    }

    // MARK: - Queries

    public func books() async throws -> [IndexedBook] {
        try await catalog.allBooks()
    }

    public func search(_ query: String) async throws -> [IndexedBook] {
        try await catalog.search(query)
    }

    public func deletedBooks() async throws -> [IndexedBook] {
        try await catalog.deletedBooks()
    }

    public func book(id: UUID) async throws -> IndexedBook? {
        try await catalog.book(id: id)
    }

    public func books(facetType: FacetType, value: String) async throws -> [IndexedBook] {
        try await catalog.books(facetType: facetType, value: value)
    }

    public func facetCounts(_ type: FacetType) async throws -> [(value: String, count: Int)] {
        try await catalog.facetCounts(type)
    }

    public func bookIDs(byFormatHash contentHash: String) async throws -> [UUID] {
        try await catalog.bookIDs(byFormatHash: contentHash)
    }

    public func allBooksForDuplicateCheck() async throws -> [IndexedBook] {
        try await catalog.allBooks()
    }

    // MARK: - Files

    public func formatFileURL(id: UUID) async throws -> URL? {
        guard let book = try await catalog.book(id: id),
              let format = book.formats.first else {
            return nil
        }
        let url = await folder.formatFileURL(relativePath: book.relativePath, filename: format.filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func bookFolderURL(id: UUID) async throws -> URL? {
        guard let book = try await catalog.book(id: id) else { return nil }
        let url = await folder.bookDirectoryURL(relativePath: book.relativePath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func missingFormatFiles() async throws -> [(book: IndexedBook, filename: String)] {
        var missing: [(book: IndexedBook, filename: String)] = []
        for book in try await catalog.allBooks() {
            for format in book.formats {
                let url = await folder.formatFileURL(relativePath: book.relativePath, filename: format.filename)
                if !FileManager.default.fileExists(atPath: url.path) {
                    missing.append((book, format.filename))
                }
            }
        }
        return missing
    }

    // MARK: - Rebuild

    /// Outcome of a catalog rebuild: what was built, which books were skipped
    /// (valid changes whose dependencies have not synced), and which corrupt
    /// change files were moved to quarantine. Surfaces in diagnostics.
    public struct RebuildReport: Sendable, Equatable {
        public var booksBuilt: Int = 0
        public var booksSkipped: [UUID] = []
        public var quarantined: [URL] = []

        public init() {}
    }

    /// Rebuilds the disposable catalog from the change store. Reports
    /// `progress` (0...1, monotonic) between books and checks `cancelled`
    /// before each book, throwing `LibraryRepositoryError.rebuildCancelled`
    /// when a rebuild is cancelled. The defaulted closures keep existing
    /// callers (`open()`, `rebuildIndex`) compiling unchanged.
    ///
    /// Mirrors `SyncEngine.ingest`'s tolerance: digest-corrupt change files
    /// are quarantined (the store names every file
    /// `<clock>-<SHA256(content)>.amchange`, so a mismatch means the file
    /// never came from the change store), and valid changes whose
    /// dependencies have not synced skip their book instead of failing the
    /// whole rebuild — a single damaged book must not brick `open()` for the
    /// entire library.
    public func rebuildCatalog(
        progress: @Sendable (Double) -> Void = { _ in },
        cancelled: @Sendable () -> Bool = { false }
    ) async throws -> RebuildReport {
        try await catalog.clear()
        let bookIDs = try await changeStore.bookIDs()
        let total = max(bookIDs.count, 1)
        var report = RebuildReport()
        var built: [IndexedBook] = []
        for (index, bookID) in bookIDs.enumerated() {
            if cancelled() {
                throw LibraryRepositoryError.rebuildCancelled
            }
            let files = try await changeStore.bookChangeFiles(bookID: bookID)
            var pending: [Data] = []
            for url in files {
                if ChangeStore.hasCorruptDigest(url) {
                    report.quarantined.append(try await changeStore.quarantine(url))
                } else if let data = try? Data(contentsOf: url) {
                    pending.append(data)
                }
            }
            let document = try AutomergeBookDocument.empty(deviceID: deviceID)
            var remaining = pending
            var madeProgress = true

            while !remaining.isEmpty && madeProgress {
                madeProgress = false
                var next: [Data] = []
                for change in remaining {
                    do {
                        try document.apply(change)
                        madeProgress = true
                    } catch {
                        next.append(change)
                    }
                }
                remaining = next
            }

            // Valid changes waiting on a not-yet-synced dependency stay in the
            // store and apply on a later rebuild/ingest. Skip the book (the
            // catalog is disposable; the change store is authoritative) instead
            // of throwing for the whole library.
            guard remaining.isEmpty else {
                report.booksSkipped.append(bookID)
                progress(Double(index + 1) / Double(total))
                continue
            }
            do {
                let resolved = try document.resolvedBook()
                let path = CanonicalPathBuilder.relativeDirectory(
                    bookID: bookID, title: resolved.title, authors: resolved.authors
                )
                built.append(try makeIndexedBook(document, relativePath: path))
                report.booksBuilt += 1
            } catch {
                // Not buildable (e.g. creation change unreadable) — skip like a
                // stuck book; the change store keeps everything for a later retry.
                report.booksSkipped.append(bookID)
            }
            progress(Double(index + 1) / Double(total))
        }
        if !built.isEmpty {
            try await catalog.upsertBatch(built)
        }
        progress(1)
        return report
    }

    // MARK: - Sync integration

    /// Builds the sync engine for this repository's layout and catalog.
    public func syncEngine(state: SyncState) -> SyncEngine {
        SyncEngine(layout: layout, catalog: catalog, state: state, deviceID: deviceID)
    }

    /// Builds the folder reconciler for this repository's layout and catalog.
    public func reconciler() -> FolderReconciler {
        FolderReconciler(layout: layout, catalog: catalog, deviceID: deviceID)
    }

    /// Upserts the catalog entry for an offline-applied edit (no filesystem
    /// writes — the canonical folder is reconciled by the sync monitor in 4b).
    /// The catalog's cached snapshot must reflect the applied state (a stale
    /// snapshot would make the next edit apply on an outdated base), so the
    /// document is rebuilt from the base snapshot plus the staged changes.
    @discardableResult
    public func upsertResolved(
        _ resolved: ResolvedBook,
        bookID: UUID,
        baseSnapshot: Data,
        changes: [Data]
    ) async throws -> IndexedBook {
        let document = try AutomergeBookDocument(snapshot: baseSnapshot, deviceID: deviceID)
        for change in changes {
            try document.apply(change)
        }
        let path = CanonicalPathBuilder.relativeDirectory(
            bookID: bookID, title: resolved.title, authors: resolved.authors
        )
        let indexed = try IndexedBookFactory.make(
            resolved: resolved,
            bookID: bookID,
            path: path,
            snapshot: document.snapshot()
        )
        try await catalog.upsert(indexed)
        return indexed
    }

    private func makeIndexedBook(
        _ document: AutomergeBookDocument,
        relativePath: String
    ) throws -> IndexedBook {
        let resolved = try document.resolvedBook()
        return try IndexedBookFactory.make(
            resolved: resolved,
            bookID: resolved.id,
            path: relativePath,
            snapshot: document.snapshot()
        )
    }
}

public enum LibraryRepositoryError: Error, Equatable {
    case unsupportedFormat(Int)
    case bookNotFound(UUID)
    case rebuildCancelled
    /// The target folder already contains a library manifest; creating over it
    /// would clobber the existing library's identity.
    case libraryAlreadyExists
}

// MARK: - Private helpers

/// Kept out of the actor body (type-body limit): the change-write path used
/// by `createBook`. Members of a `private` extension in the same file reach
/// the actor's private stored properties (`changeStore`, `deviceID`).
private extension LibraryRepository {
    func writeChanges(
        metadata: NewBookMetadata,
        document: AutomergeBookDocument,
        bookID: UUID,
        staged: [BookFolder.StagedFile],
        cover: Data?
    ) async throws -> [URL] {
        var written: [URL] = []
        // Returns the result instead of capturing `written` so the nested
        // function stays nonisolated-safe under strict concurrency.
        func write(_ change: Data, clock: HybridLogicalClock) async throws -> ChangeStore.WriteResult {
            try await changeStore.writeBookChange(
                change, bookID: bookID, deviceID: deviceID, clock: clock
            )
        }
        func record(_ result: ChangeStore.WriteResult) {
            if result.created { written.append(result.url) }
        }
        var current = HybridLogicalClock(nodeID: deviceID)

        record(try await write(document.setTitle(metadata.title, clock: current.tick()), clock: current))
        if !metadata.authors.isEmpty {
            record(try await write(document.setAuthors(metadata.authors, clock: current.tick()), clock: current))
        }
        if let series = metadata.series, !series.isEmpty {
            record(try await write(document.setSeries(series, clock: current.tick()), clock: current))
        }
        if let seriesIndex = metadata.seriesIndex {
            record(try await write(document.setSeriesIndex(seriesIndex, clock: current.tick()), clock: current))
        }
        if !metadata.tags.isEmpty {
            record(try await write(document.setTags(metadata.tags, clock: current.tick()), clock: current))
        }
        if let rating = metadata.rating {
            record(try await write(document.setRating(rating, clock: current.tick()), clock: current))
        }
        if let publisher = metadata.publisher, !publisher.isEmpty {
            record(try await write(document.setPublisher(publisher, clock: current.tick()), clock: current))
        }
        if let publicationDate = metadata.publicationDate {
            record(try await write(document.setPublicationDate(publicationDate, clock: current.tick()), clock: current))
        }
        if let addedDate = metadata.addedDate {
            record(try await write(document.setAddedDate(addedDate, clock: current.tick()), clock: current))
        } else {
            record(try await write(document.setAddedDate(.now, clock: current.tick()), clock: current))
        }
        if !metadata.languages.isEmpty {
            record(try await write(document.setLanguages(metadata.languages, clock: current.tick()), clock: current))
        }
        if !metadata.identifiers.isEmpty {
            record(try await write(document.setIdentifiers(metadata.identifiers, clock: current.tick()), clock: current))
        }
        if let comments = metadata.comments, !comments.isEmpty {
            record(try await write(document.setComments(comments, clock: current.tick()), clock: current))
        }
        if let rawMetadata = metadata.rawMetadata, !rawMetadata.isEmpty {
            record(try await write(document.setRawMetadata(rawMetadata, clock: current.tick()), clock: current))
        }
        for file in staged {
            let filename = CanonicalPathBuilder.formatFileName(
                title: metadata.title, authors: metadata.authors, kind: file.kind
            )
            let format = BookFormatValue(
                kind: file.kind, filename: filename,
                contentHash: file.contentHash, size: file.size
            )
            record(try await write(document.setFormat(format, clock: current.tick()), clock: current))
        }
        if let cover {
            let hash = BookFolder.contentHash(cover)
            record(try await write(
                document.setCover(CoverValue(filename: "cover.jpg", contentHash: hash), clock: current.tick()),
                clock: current
            ))
        }
        return written
    }
}
