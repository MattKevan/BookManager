import Foundation

/// The owning server of one library. `Journal` is authoritative (append-only
/// operation log + periodic snapshot); `LocalCatalog` is a disposable index
/// rebuilt from it; `BookFolder` owns the derived book folders. All
/// mutations append a command and then apply it — apply is deterministic and
/// replayable, so a crash between append and apply heals on the next rebuild.
public actor LibraryRepository: LibraryRepositoryImporting {
    public nonisolated let manifest: LibraryManifest
    public nonisolated let root: URL

    private let layout: LibraryLayout
    private let journal: Journal
    private let catalog: LocalCatalog
    private let folder: BookFolder

    /// Highest journal seq covered by the on-disk snapshot; a snapshot is
    /// written when the journal advances this by `snapshotEveryCommands`.
    private var lastSnapshotSeq: Int64 = 0
    private static let snapshotEveryCommands: Int64 = 1000

    private init(
        manifest: LibraryManifest,
        layout: LibraryLayout,
        catalog: LocalCatalog
    ) {
        self.manifest = manifest
        root = layout.root
        self.layout = layout
        journal = Journal(layout: layout)
        folder = BookFolder(layout: layout)
        self.catalog = catalog
    }

    public static func create(
        at root: URL,
        indexesDirectory: URL,
        deviceID: UUID
    ) async throws -> LibraryRepository {
        let layout = LibraryLayout(root: root)
        // Refuse to create over an existing library: writing a fresh manifest
        // would change its identity and fork the library.
        guard !FileManager.default.fileExists(atPath: layout.manifestURL.path) else {
            throw LibraryRepositoryError.libraryAlreadyExists
        }
        let manifest = LibraryManifest(id: UUID())
        try layout.create(manifest: manifest)
        let repository = try LibraryRepository(
            manifest: manifest,
            layout: layout,
            catalog: LocalCatalog(
                databaseURL: indexesDirectory.appending(path: "\(manifest.id.uuidString).sqlite")
            )
        )
        try await repository.journal.open()
        return repository
    }

    public static func open(
        at root: URL,
        indexesDirectory: URL,
        deviceID: UUID
    ) async throws -> LibraryRepository {
        let layout = LibraryLayout(root: root)
        let manifest = try layout.readManifest()
        guard manifest.formatVersion == 2 else {
            throw LibraryRepositoryError.unsupportedFormat(manifest.formatVersion)
        }
        let repository = try LibraryRepository(
            manifest: manifest,
            layout: layout,
            catalog: LocalCatalog(
                databaseURL: indexesDirectory.appending(path: "\(manifest.id.uuidString).sqlite")
            ),
        )
        try await repository.journal.open()
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
        let commandID = UUID()
        // Move the incoming staged files under the command's staging
        // directory so the journal record is self-contained (the rebuild
        // path can re-materialize from it).
        let stagedDir = layout.stagingRoot.appending(path: commandID.uuidString, directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: stagedDir, withIntermediateDirectories: true)
            var formats: [JournalCommand.StagedFormat] = []
            for (index, file) in staged.enumerated() {
                let stagedName = "\(index)-\(file.url.lastPathComponent)"
                try FileManager.default.moveItem(
                    at: file.url, to: stagedDir.appending(path: stagedName)
                )
                formats.append(JournalCommand.StagedFormat(
                    kind: file.kind,
                    filename: CanonicalPathBuilder.formatFileName(
                        title: metadata.title, authors: metadata.authors, kind: file.kind
                    ),
                    contentHash: file.contentHash,
                    size: file.size,
                    stagedName: stagedName
                ))
            }
            var stagedCover: JournalCommand.StagedCover?
            if let cover {
                let stagedName = "cover"
                try cover.write(to: stagedDir.appending(path: stagedName))
                stagedCover = JournalCommand.StagedCover(
                    filename: "cover.jpg", contentHash: BookFolder.contentHash(cover), stagedName: stagedName
                )
            }
            let payload = JournalCommand.AddBook(
                bookID: bookID,
                title: metadata.title,
                authors: metadata.authors,
                series: metadata.series,
                seriesIndex: metadata.seriesIndex,
                tags: metadata.tags,
                rating: metadata.rating,
                publisher: metadata.publisher,
                publicationDate: metadata.publicationDate,
                addedDate: metadata.addedDate ?? .now,
                languages: metadata.languages,
                identifiers: metadata.identifiers,
                comments: metadata.comments,
                formats: formats,
                cover: stagedCover
            )
            guard try await journal.append(op: .addBook(payload), id: commandID) != nil else {
                throw LibraryRepositoryError.duplicateCommand
            }
            let indexed = try await applyAddBook(payload, commandID: commandID, materializeFolders: true)
            try? FileManager.default.removeItem(at: stagedDir)
            try await maybeSnapshot()
            return indexed
        } catch {
            try? FileManager.default.removeItem(at: stagedDir)
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
        var metadata = NewBookMetadata(title: title, authors: authors)
        metadata.addedDate = date
        return try await createBook(metadata: metadata, staged: [], cover: nil)
    }

    // MARK: - Editing

    public func updateBook(id: UUID, edit: BookEdit) async throws -> IndexedBook {
        guard try await catalog.book(id: id) != nil else {
            throw LibraryRepositoryError.bookNotFound(id)
        }
        guard try await journal.append(op: .updateBook(.init(bookID: id, edit: edit))) != nil else {
            throw LibraryRepositoryError.duplicateCommand
        }
        let updated = try await applyUpdateBook(id: id, edit: edit, materializeFolders: true)
        try await maybeSnapshot()
        return updated
    }

    /// Writes a cover for a book: a `setCover` journal command, a materialized
    /// `cover.jpg` in the book folder (atomic write), and a catalog upsert.
    public func updateCover(coverData: Data, for bookID: UUID) async throws -> IndexedBook {
        guard try await catalog.book(id: bookID) != nil else {
            throw LibraryRepositoryError.bookNotFound(bookID)
        }
        let commandID = UUID()
        let stagedDir = layout.stagingRoot.appending(path: commandID.uuidString, directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: stagedDir, withIntermediateDirectories: true)
            let stagedName = "cover"
            try coverData.write(to: stagedDir.appending(path: stagedName))
            let cover = JournalCommand.StagedCover(
                filename: "cover.jpg", contentHash: BookFolder.contentHash(coverData), stagedName: stagedName
            )
            guard try await journal.append(op: .setCover(.init(bookID: bookID, cover: cover)), id: commandID) != nil else {
                throw LibraryRepositoryError.duplicateCommand
            }
            let updated = try await applySetCover(bookID: bookID, cover: cover, commandID: commandID, materializeFolders: true)
            try? FileManager.default.removeItem(at: stagedDir)
            try await maybeSnapshot()
            return updated
        } catch {
            try? FileManager.default.removeItem(at: stagedDir)
            throw error
        }
    }

    // MARK: - Delete and restore

    public func deleteBook(id: UUID) async throws {
        guard try await catalog.book(id: id) != nil else {
            throw LibraryRepositoryError.bookNotFound(id)
        }
        guard try await journal.append(op: .deleteBook(.init(bookID: id))) != nil else {
            throw LibraryRepositoryError.duplicateCommand
        }
        try await applyDeleteBook(id: id, materializeFolders: true)
        try await maybeSnapshot()
    }

    public func restoreBook(id: UUID) async throws -> IndexedBook {
        guard try await catalog.book(id: id) != nil else {
            throw LibraryRepositoryError.bookNotFound(id)
        }
        guard try await journal.append(op: .restoreBook(.init(bookID: id))) != nil else {
            throw LibraryRepositoryError.duplicateCommand
        }
        let restored = try await applyRestoreBook(id: id, materializeFolders: true)
        try await maybeSnapshot()
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

    /// The journal's current sequence number (diagnostics surface).
    public func journalSeq() async -> Int64 {
        await journal.currentSeq
    }

    // MARK: - Network surface (Plan 2)

    /// Appends a client command (server-assigned seq; dedupes by the client's
    /// id) and applies it with folder materialization — the sync protocol's
    /// push path. `addBook`/`setCover` payloads must have their staged files
    /// pre-placed at `staging/<commandID>/` via `stageUploadedFile`.
    public func ingest(_ command: JournalCommand) async throws {
        guard try await journal.append(op: command.op, id: command.id) != nil else {
            return  // duplicate id — already applied
        }
        let stagedDir = layout.stagingRoot
            .appending(path: command.id.uuidString, directoryHint: .isDirectory)
        do {
            try await apply(command, materializeFolders: true)
            try? FileManager.default.removeItem(at: stagedDir)
            try await maybeSnapshot()
        } catch {
            try? FileManager.default.removeItem(at: stagedDir)
            throw error
        }
    }

    /// Journal records after a cursor, in order — the sync protocol's pull
    /// surface. The client stores the last `seq` it saw and re-pulls
    /// incrementally.
    public func journalRecords(after seq: Int64) async throws -> [JournalCommand] {
        try await journal.records(after: seq)
    }

    /// Writes an uploaded file into the command's staging directory — network
    /// uploads land here before the command that references them is ingested.
    public func stageUploadedFile(_ data: Data, commandID: UUID, stagedName: String) throws {
        let directory = layout.stagingRoot
            .appending(path: commandID.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appending(path: stagedName))
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

    /// Outcome of a catalog rebuild: how many books are in the catalog and
    /// how many journal commands could not be applied (skipped — the journal
    /// stays authoritative and a later rebuild retries them).
    public struct RebuildReport: Sendable, Equatable {
        public var booksBuilt: Int = 0
        public var commandsSkipped: Int = 0

        public init() {}
    }

    /// Rebuilds the disposable catalog from the journal: snapshot seed, then
    /// replay every command after the snapshot point in seq order, applied as
    /// PURE state transformations (no folder side effects), committed in ONE
    /// catalog transaction. Reports `progress` (0...1, monotonic) and checks
    /// `cancelled` between commands.
    public func rebuildCatalog(
        progress: @Sendable (Double) -> Void = { _ in },
        cancelled: @Sendable () -> Bool = { false }
    ) async throws -> RebuildReport {
        var report = RebuildReport()
        var state: [UUID: IndexedBook] = [:]
        let snapshot = try await journal.readSnapshot()
        if let snapshot {
            for book in snapshot.books {
                state[book.bookID] = try IndexedBookFactory.make(
                    resolved: resolved(from: book),
                    bookID: book.bookID,
                    path: book.relativePath,
                    modifiedMilliseconds: 0
                )
            }
            report.booksBuilt = state.count
        }
        let records = try await journal.records(after: snapshot?.lastSeq ?? 0)
        let total = max(records.count, 1)
        for (index, command) in records.enumerated() {
            if cancelled() {
                throw LibraryRepositoryError.rebuildCancelled
            }
            do {
                try applyToState(command, state: &state)
                report.booksBuilt = state.count
            } catch {
                report.commandsSkipped += 1
            }
            progress(Double(index + 1) / Double(total))
        }
        try await catalog.clear()
        if !state.isEmpty {
            try await catalog.upsertBatch(Array(state.values))
        }
        progress(1)
        return report
    }

    /// Applies one command as a pure state transformation (rebuild path).
    /// Deterministic given `state`; the folder side effects belong to the
    /// live apply path only.
    private func applyToState(
        _ command: JournalCommand,
        state: inout [UUID: IndexedBook]
    ) throws {
        switch command.op {
        case .addBook(let payload):
            let path = CanonicalPathBuilder.relativeDirectory(
                bookID: payload.bookID, title: payload.title, authors: payload.authors
            )
            state[payload.bookID] = try IndexedBookFactory.make(
                resolved: resolved(from: payload),
                bookID: payload.bookID,
                path: path,
                modifiedMilliseconds: tsMilliseconds(payload.addedDate ?? .now)
            )
        case .updateBook(let payload):
            guard let current = state[payload.bookID] else {
                throw LibraryRepositoryError.bookNotFound(payload.bookID)
            }
            let resolved = resolved(byApplying: payload.edit, to: current)
            let path = CanonicalPathBuilder.relativeDirectory(
                bookID: payload.bookID, title: resolved.title, authors: resolved.authors
            )
            state[payload.bookID] = try IndexedBookFactory.make(
                resolved: resolved,
                bookID: payload.bookID,
                path: path,
                modifiedMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000)
            )
        case .setCover(let payload):
            guard let current = state[payload.bookID] else {
                throw LibraryRepositoryError.bookNotFound(payload.bookID)
            }
            state[payload.bookID] = replacingCover(current, coverHash: payload.cover?.contentHash)
        case .deleteBook(let payload):
            guard let current = state[payload.bookID] else {
                throw LibraryRepositoryError.bookNotFound(payload.bookID)
            }
            state[payload.bookID] = withDeleted(current, isDeleted: true)
        case .restoreBook(let payload):
            guard let current = state[payload.bookID] else {
                throw LibraryRepositoryError.bookNotFound(payload.bookID)
            }
            let resolved = resolved(from: current, isDeleted: false)
            let path = CanonicalPathBuilder.relativeDirectory(
                bookID: payload.bookID, title: resolved.title, authors: resolved.authors
            )
            state[payload.bookID] = try IndexedBookFactory.make(
                resolved: resolved,
                bookID: payload.bookID,
                path: path,
                modifiedMilliseconds: current.modifiedMilliseconds
            )
        }
    }

    // MARK: - Journal apply

    /// Applies one journal command to the catalog (+ derived folders on the
    /// live path). All applies are deterministic given the catalog's current
    /// state. `materializeFolders: false` (the rebuild path) touches the
    /// catalog only: folders are derived artifacts already materialized by
    /// the live applies, and replaying folder moves would collide with them.
    private func apply(_ command: JournalCommand, materializeFolders: Bool = true) async throws {
        switch command.op {
        case .addBook(let payload):
            _ = try await applyAddBook(payload, commandID: command.id, materializeFolders: materializeFolders)
        case .updateBook(let payload):
            _ = try await applyUpdateBook(
                id: payload.bookID, edit: payload.edit, materializeFolders: materializeFolders
            )
        case .setCover(let payload):
            _ = try await applySetCover(
                bookID: payload.bookID, cover: payload.cover, commandID: command.id,
                materializeFolders: materializeFolders
            )
        case .deleteBook(let payload):
            try await applyDeleteBook(id: payload.bookID, materializeFolders: materializeFolders)
        case .restoreBook(let payload):
            _ = try await applyRestoreBook(id: payload.bookID, materializeFolders: materializeFolders)
        }
    }

    private func applyAddBook(
        _ payload: JournalCommand.AddBook,
        commandID: UUID,
        materializeFolders: Bool
    ) async throws -> IndexedBook {
        let stagedDir = layout.stagingRoot.appending(path: commandID.uuidString, directoryHint: .isDirectory)
        // Only files that actually exist are materialized (a crash between
        // append and apply leaves missing staged files); the catalog row is
        // built from the command payload either way.
        var stagedFiles: [BookFolder.StagedFile] = []
        for format in payload.formats {
            let url = stagedDir.appending(path: format.stagedName)
            if FileManager.default.fileExists(atPath: url.path) {
                stagedFiles.append(BookFolder.StagedFile(
                    kind: format.kind, contentHash: format.contentHash, size: format.size, url: url
                ))
            }
        }
        var coverData: Data?
        if let cover = payload.cover {
            let url = stagedDir.appending(path: cover.stagedName)
            if FileManager.default.fileExists(atPath: url.path) {
                coverData = try? Data(contentsOf: url)
            }
        }
        let resolved = resolved(from: payload)
        let path = CanonicalPathBuilder.relativeDirectory(
            bookID: payload.bookID, title: payload.title, authors: payload.authors
        )
        if materializeFolders {
            _ = try await folder.materialize(
                bookID: payload.bookID,
                resolved: resolved,
                staged: stagedFiles,
                cover: coverData
            )
        }
        let indexed = try IndexedBookFactory.make(
            resolved: resolved,
            bookID: payload.bookID,
            path: path,
            modifiedMilliseconds: tsMilliseconds(payload.addedDate ?? .now)
        )
        try await catalog.upsert(indexed)
        return indexed
    }

    private func applyUpdateBook(
        id: UUID,
        edit: BookEdit,
        materializeFolders: Bool
    ) async throws -> IndexedBook {
        guard let current = try await catalog.book(id: id) else {
            throw LibraryRepositoryError.bookNotFound(id)
        }
        let resolved = resolved(byApplying: edit, to: current)
        let newPath = CanonicalPathBuilder.relativeDirectory(
            bookID: id, title: resolved.title, authors: resolved.authors
        )
        if materializeFolders {
            if newPath != current.relativePath {
                try await folder.rename(
                    bookID: id,
                    from: current.relativePath,
                    to: newPath,
                    oldFormats: current.formats.map {
                        BookFormatValue(kind: $0.kind, filename: $0.filename, contentHash: $0.contentHash, size: $0.size)
                    },
                    newFormats: resolved.formats
                )
            }
            // metadata.opf is a derived sidecar: keep it in sync on every edit,
            // creating the folder when it is absent (synced book not materialized).
            let directory = await folder.bookDirectoryURL(relativePath: newPath)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try OpfGenerator.opfData(bookID: id, resolved: resolved)
                .write(to: directory.appending(path: "metadata.opf"), options: .atomic)
        }
        let updated = try IndexedBookFactory.make(
            resolved: resolved,
            bookID: id,
            path: newPath,
            modifiedMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000)
        )
        try await catalog.upsert(updated)
        return updated
    }

    private func applySetCover(
        bookID: UUID,
        cover: JournalCommand.StagedCover?,
        commandID: UUID,
        materializeFolders: Bool
    ) async throws -> IndexedBook {
        guard let current = try await catalog.book(id: bookID) else {
            throw LibraryRepositoryError.bookNotFound(bookID)
        }
        if materializeFolders {
            let directory = await folder.bookDirectoryURL(relativePath: current.relativePath)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let coverURL = directory.appending(path: "cover.jpg")
            if let cover {
                let staged = layout.stagingRoot
                    .appending(path: commandID.uuidString)
                    .appending(path: cover.stagedName)
                if FileManager.default.fileExists(atPath: staged.path),
                   let data = try? Data(contentsOf: staged) {
                    try data.write(to: coverURL, options: .atomic)
                }
            } else {
                try? FileManager.default.removeItem(at: coverURL)
            }
        }
        let updated = replacingCover(current, coverHash: cover?.contentHash)
        try await catalog.upsert(updated)
        return updated
    }

    private func applyDeleteBook(id: UUID, materializeFolders: Bool) async throws {
        guard let current = try await catalog.book(id: id) else {
            throw LibraryRepositoryError.bookNotFound(id)
        }
        if materializeFolders {
            try await folder.trash(bookID: id, relativePath: current.relativePath)
        }
        let deleted = withDeleted(current, isDeleted: true)
        try await catalog.upsert(deleted)
    }

    private func applyRestoreBook(id: UUID, materializeFolders: Bool) async throws -> IndexedBook {
        guard let current = try await catalog.book(id: id) else {
            throw LibraryRepositoryError.bookNotFound(id)
        }
        let resolved = resolved(from: current, isDeleted: false)
        let path = CanonicalPathBuilder.relativeDirectory(
            bookID: id, title: resolved.title, authors: resolved.authors
        )
        if materializeFolders {
            _ = try await folder.restore(bookID: id, relativePath: path)
        }
        let restored = try IndexedBookFactory.make(
            resolved: resolved,
            bookID: id,
            path: path,
            modifiedMilliseconds: current.modifiedMilliseconds
        )
        try await catalog.upsert(restored)
        return restored
    }

    // MARK: - Snapshots

    private func maybeSnapshot() async throws {
        let current = await journal.currentSeq
        guard current - lastSnapshotSeq >= Self.snapshotEveryCommands else { return }
        try await writeSnapshot()
        lastSnapshotSeq = current
    }

    private func writeSnapshot() async throws {
        let books = (try await catalog.allBooks()) + (try await catalog.deletedBooks())
        let snapshot = JournalSnapshot(
            lastSeq: await journal.currentSeq,
            books: books.map { JournalSnapshot.Book(book: $0) }
        )
        try await journal.writeSnapshot(snapshot)
    }

    // MARK: - Mapping helpers

    /// Applies an edit's fields over the current catalog row — the same
    /// semantics as the old Automerge apply: nil/`.keep` untouched, `.set`
    /// assigns, `.clear` empties.
    private func resolved(byApplying edit: BookEdit, to book: IndexedBook) -> ResolvedBook {
        ResolvedBook(
            id: book.id,
            title: edit.title ?? book.title,
            authors: edit.authors ?? book.authors,
            series: edit.series.apply(to: book.series),
            seriesIndex: edit.seriesIndex.apply(to: book.seriesIndex),
            tags: edit.tags ?? book.tags,
            rating: edit.rating.apply(to: book.rating),
            publisher: edit.publisher.apply(to: book.publisher),
            publicationDate: edit.publicationDate.apply(to: book.publicationDate),
            addedDate: book.addedDate,
            languages: edit.languages ?? book.languages,
            identifiers: edit.identifiers ?? book.identifiers,
            comments: edit.comments.apply(to: book.comments),
            formats: book.formats.map {
                BookFormatValue(kind: $0.kind, filename: $0.filename, contentHash: $0.contentHash, size: $0.size)
            },
            cover: book.coverHash.map { CoverValue(filename: "cover.jpg", contentHash: $0) },
            rawMetadata: book.rawMetadata,
            isDeleted: book.isDeleted
        )
    }

    private func resolved(from book: IndexedBook) -> ResolvedBook {
        resolved(from: book, isDeleted: book.isDeleted)
    }

    private func resolved(from book: IndexedBook, isDeleted: Bool) -> ResolvedBook {
        ResolvedBook(
            id: book.id,
            title: book.title,
            authors: book.authors,
            series: book.series,
            seriesIndex: book.seriesIndex,
            tags: book.tags,
            rating: book.rating,
            publisher: book.publisher,
            publicationDate: book.publicationDate,
            addedDate: book.addedDate,
            languages: book.languages,
            identifiers: book.identifiers,
            comments: book.comments,
            formats: book.formats.map {
                BookFormatValue(kind: $0.kind, filename: $0.filename, contentHash: $0.contentHash, size: $0.size)
            },
            cover: book.coverHash.map { CoverValue(filename: "cover.jpg", contentHash: $0) },
            rawMetadata: book.rawMetadata,
            isDeleted: isDeleted
        )
    }

    private func resolved(from payload: JournalCommand.AddBook) -> ResolvedBook {
        ResolvedBook(
            id: payload.bookID,
            title: payload.title,
            authors: payload.authors,
            series: payload.series,
            seriesIndex: payload.seriesIndex,
            tags: payload.tags,
            rating: payload.rating,
            publisher: payload.publisher,
            publicationDate: payload.publicationDate,
            addedDate: payload.addedDate,
            languages: payload.languages,
            identifiers: payload.identifiers,
            comments: payload.comments,
            formats: payload.formats.map {
                BookFormatValue(kind: $0.kind, filename: $0.filename, contentHash: $0.contentHash, size: $0.size)
            },
            cover: payload.cover.map { CoverValue(filename: $0.filename, contentHash: $0.contentHash) },
            rawMetadata: nil,
            isDeleted: false
        )
    }

    private func resolved(from snapshotBook: JournalSnapshot.Book) -> ResolvedBook {
        ResolvedBook(
            id: snapshotBook.bookID,
            title: snapshotBook.title,
            authors: snapshotBook.authors,
            series: snapshotBook.series,
            seriesIndex: snapshotBook.seriesIndex,
            tags: snapshotBook.tags,
            rating: snapshotBook.rating,
            publisher: snapshotBook.publisher,
            publicationDate: snapshotBook.publicationDate,
            addedDate: snapshotBook.addedDate,
            languages: snapshotBook.languages,
            identifiers: snapshotBook.identifiers,
            comments: snapshotBook.comments,
            formats: snapshotBook.formats.map {
                BookFormatValue(kind: $0.kind, filename: $0.filename, contentHash: $0.contentHash, size: $0.size)
            },
            cover: snapshotBook.cover.map { CoverValue(filename: $0.filename, contentHash: $0.contentHash) },
            rawMetadata: nil,
            isDeleted: snapshotBook.isDeleted
        )
    }

    private func replacingCover(_ book: IndexedBook, coverHash: String?) -> IndexedBook {
        IndexedBook(
            id: book.id, title: book.title, authors: book.authors,
            series: book.series, seriesIndex: book.seriesIndex, tags: book.tags,
            rating: book.rating, publisher: book.publisher,
            publicationMilliseconds: book.publicationMilliseconds,
            addedMilliseconds: book.addedMilliseconds,
            languages: book.languages, identifiers: book.identifiers, comments: book.comments,
            rawMetadata: book.rawMetadata, formats: book.formats,
            coverHash: coverHash, relativePath: book.relativePath,
            modifiedMilliseconds: book.modifiedMilliseconds, isDeleted: book.isDeleted
        )
    }

    private func withDeleted(_ book: IndexedBook, isDeleted: Bool) -> IndexedBook {
        IndexedBook(
            id: book.id, title: book.title, authors: book.authors,
            series: book.series, seriesIndex: book.seriesIndex, tags: book.tags,
            rating: book.rating, publisher: book.publisher,
            publicationMilliseconds: book.publicationMilliseconds,
            addedMilliseconds: book.addedMilliseconds,
            languages: book.languages, identifiers: book.identifiers, comments: book.comments,
            rawMetadata: book.rawMetadata, formats: book.formats,
            coverHash: book.coverHash, relativePath: book.relativePath,
            modifiedMilliseconds: book.modifiedMilliseconds, isDeleted: isDeleted
        )
    }

    private func tsMilliseconds(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1_000)
    }
}

extension FieldEdit {
    /// Applies the keep/set/clear instruction over a current value.
    func apply(to current: T?) -> T? {
        switch self {
        case .keep: return current
        case .set(let value): return value
        case .clear: return nil
        }
    }
}

public enum LibraryRepositoryError: Error, Equatable {
    case unsupportedFormat(Int)
    case bookNotFound(UUID)
    case rebuildCancelled
    /// The journal rejected a command id that was already applied.
    case duplicateCommand
    /// The target folder already contains a library manifest; creating over it
    /// would clobber the existing library's identity.
    case libraryAlreadyExists
}
