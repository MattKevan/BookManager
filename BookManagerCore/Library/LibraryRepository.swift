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

        try await writeChanges(metadata: metadata, document: document, bookID: bookID, staged: staged, cover: cover)

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

    private func writeChanges(
        metadata: NewBookMetadata,
        document: AutomergeBookDocument,
        bookID: UUID,
        staged: [BookFolder.StagedFile],
        cover: Data?
    ) async throws {
        func write(_ change: Data, clock: HybridLogicalClock) async throws {
            _ = try await changeStore.writeBookChange(
                change, bookID: bookID, deviceID: deviceID, clock: clock
            )
        }
        var current = HybridLogicalClock(nodeID: deviceID)

        try await write(document.setTitle(metadata.title, clock: current.tick()), clock: current)
        if !metadata.authors.isEmpty {
            try await write(document.setAuthors(metadata.authors, clock: current.tick()), clock: current)
        }
        if let series = metadata.series, !series.isEmpty {
            try await write(document.setSeries(series, clock: current.tick()), clock: current)
        }
        if let seriesIndex = metadata.seriesIndex {
            try await write(document.setSeriesIndex(seriesIndex, clock: current.tick()), clock: current)
        }
        if !metadata.tags.isEmpty {
            try await write(document.setTags(metadata.tags, clock: current.tick()), clock: current)
        }
        if let rating = metadata.rating {
            try await write(document.setRating(rating, clock: current.tick()), clock: current)
        }
        if let publisher = metadata.publisher, !publisher.isEmpty {
            try await write(document.setPublisher(publisher, clock: current.tick()), clock: current)
        }
        if let publicationDate = metadata.publicationDate {
            try await write(document.setPublicationDate(publicationDate, clock: current.tick()), clock: current)
        }
        try await write(document.setAddedDate(.now, clock: current.tick()), clock: current)
        if !metadata.languages.isEmpty {
            try await write(document.setLanguages(metadata.languages, clock: current.tick()), clock: current)
        }
        if !metadata.identifiers.isEmpty {
            try await write(document.setIdentifiers(metadata.identifiers, clock: current.tick()), clock: current)
        }
        if let comments = metadata.comments, !comments.isEmpty {
            try await write(document.setComments(comments, clock: current.tick()), clock: current)
        }
        for file in staged {
            let filename = CanonicalPathBuilder.formatFileName(
                title: metadata.title, authors: metadata.authors, kind: file.kind
            )
            let format = BookFormatValue(
                kind: file.kind, filename: filename,
                contentHash: file.contentHash, size: file.size
            )
            try await write(document.setFormat(format, clock: current.tick()), clock: current)
        }
        if let cover {
            let hash = BookFolder.contentHash(cover)
            try await write(
                document.setCover(CoverValue(filename: "cover.jpg", contentHash: hash), clock: current.tick()),
                clock: current
            )
        }
    }

    // MARK: - Editing

    public func updateBook(id: UUID, edit: BookEdit) async throws -> IndexedBook {
        guard let indexed = try await catalog.book(id: id) else {
            throw LibraryRepositoryError.bookNotFound(id)
        }
        let document = try AutomergeBookDocument(snapshot: indexed.snapshot, deviceID: deviceID)
        let changes = try document.apply(edit, clock: HybridLogicalClock(nodeID: deviceID), date: .now)
        for change in changes {
            _ = try await changeStore.writeBookChange(
                change, bookID: id, deviceID: deviceID, clock: HybridLogicalClock(nodeID: deviceID)
            )
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
            let directory = await folder.bookDirectoryURL(relativePath: newPath)
            try OpfGenerator.opfData(bookID: id, resolved: resolved)
                .write(to: directory.appending(path: "metadata.opf"), options: .atomic)
        }
        let updated = try makeIndexedBook(document, relativePath: newPath)
        try await catalog.upsert(updated)
        return updated
    }

    // MARK: - Delete and restore

    public func deleteBook(id: UUID) async throws {
        guard let indexed = try await catalog.book(id: id) else {
            throw LibraryRepositoryError.bookNotFound(id)
        }
        let document = try AutomergeBookDocument(snapshot: indexed.snapshot, deviceID: deviceID)
        var clock = HybridLogicalClock(nodeID: deviceID)
        let change = try document.setDeleted(true, clock: clock.tick())
        _ = try await changeStore.writeBookChange(
            change, bookID: id, deviceID: deviceID, clock: HybridLogicalClock(nodeID: deviceID)
        )
        try await folder.trash(bookID: id, relativePath: indexed.relativePath)
        let deleted = try makeIndexedBook(document, relativePath: indexed.relativePath)
        try await catalog.upsert(deleted)
    }

    public func restoreBook(id: UUID) async throws -> IndexedBook {
        guard let indexed = try await catalog.book(id: id) else {
            throw LibraryRepositoryError.bookNotFound(id)
        }
        let document = try AutomergeBookDocument(snapshot: indexed.snapshot, deviceID: deviceID)
        var clock = HybridLogicalClock(nodeID: deviceID)
        let change = try document.setDeleted(false, clock: clock.tick())
        _ = try await changeStore.writeBookChange(
            change, bookID: id, deviceID: deviceID, clock: HybridLogicalClock(nodeID: deviceID)
        )
        let resolved = try document.resolvedBook()
        let path = CanonicalPathBuilder.relativeDirectory(
            bookID: id, title: resolved.title, authors: resolved.authors
        )
        _ = try await folder.restore(bookID: id, relativePath: path)
        let restored = try makeIndexedBook(document, relativePath: path)
        try await catalog.upsert(restored)
        return restored
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

    public func rebuildCatalog() async throws {
        try await catalog.clear()
        for bookID in try await changeStore.bookIDs() {
            let pending = try await changeStore.bookChanges(bookID: bookID)
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

            guard remaining.isEmpty else {
                throw LibraryRepositoryError.missingDependencies(bookID)
            }
            let resolved = try document.resolvedBook()
            let path = CanonicalPathBuilder.relativeDirectory(
                bookID: bookID, title: resolved.title, authors: resolved.authors
            )
            try await catalog.upsert(makeIndexedBook(document, relativePath: path))
        }
    }

    private func makeIndexedBook(
        _ document: AutomergeBookDocument,
        relativePath: String
    ) throws -> IndexedBook {
        let book = try document.resolvedBook()
        let normalizeEmpty: (String?) -> String? = { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        let normalizeZero: (Double?) -> Double? = { value in
            guard let value, value != 0 else { return nil }
            return value
        }
        let normalizeRating: (Int?) -> Int? = { value in
            guard let value, value != 0 else { return nil }
            return value
        }
        // `.clear` edits write the epoch-0 sentinel; map it back to nil so the
        // UI shows "no date" instead of 1970-01-01 (plan's clear-sentinel contract).
        let epochZero = Date(timeIntervalSince1970: 0)
        let normalizeDate: (Date?) -> Date? = { value in
            guard let value, value != epochZero else { return nil }
            return value
        }
        return IndexedBook(
            id: book.id,
            title: book.title,
            authors: book.authors,
            series: normalizeEmpty(book.series),
            seriesIndex: normalizeZero(book.seriesIndex),
            tags: book.tags,
            rating: normalizeRating(book.rating),
            publisher: normalizeEmpty(book.publisher),
            publicationMilliseconds: normalizeDate(book.publicationDate).map { Int64($0.timeIntervalSince1970 * 1_000) },
            addedMilliseconds: normalizeDate(book.addedDate).map { Int64($0.timeIntervalSince1970 * 1_000) },
            languages: book.languages,
            identifiers: book.identifiers,
            comments: normalizeEmpty(book.comments),
            formats: book.formats.map {
                BookFormatRecord(
                    kind: $0.kind, filename: $0.filename,
                    contentHash: $0.contentHash, size: $0.size
                )
            },
            coverHash: book.cover?.contentHash,
            relativePath: relativePath,
            modifiedMilliseconds: book.modifiedClock.physicalMilliseconds,
            isDeleted: book.isDeleted,
            snapshot: document.snapshot()
        )
    }
}

public enum LibraryRepositoryError: Error, Equatable {
    case unsupportedFormat(Int)
    case missingDependencies(UUID)
    case bookNotFound(UUID)
}
