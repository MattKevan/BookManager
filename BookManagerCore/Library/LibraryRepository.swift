import Foundation

public actor LibraryRepository {
    public let manifest: LibraryManifest
    public let root: URL

    private let layout: LibraryLayout
    private let changeStore: ChangeStore
    private let catalog: LocalCatalog
    private let deviceID: UUID
    private var clock: HybridLogicalClock

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
        self.catalog = catalog
        self.deviceID = deviceID
        clock = HybridLogicalClock(nodeID: deviceID)
    }

    public static func create(
        at root: URL,
        indexesDirectory: URL,
        deviceID: UUID
    ) async throws -> LibraryRepository {
        let layout = LibraryLayout(root: root)
        let manifest = LibraryManifest(id: UUID())
        try layout.create(manifest: manifest)
        let repository = try LibraryRepository(
            manifest: manifest,
            layout: layout,
            catalog: LocalCatalog(
                databaseURL: indexesDirectory.appending(path: "\(manifest.id.uuidString).sqlite")
            ),
            deviceID: deviceID
        )
        return repository
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

    @discardableResult
    public func createBook(
        title: String,
        authors: [String],
        at date: Date = .now
    ) async throws -> IndexedBook {
        let bookID = UUID()
        let document = try AutomergeBookDocument.new(bookID: bookID, deviceID: deviceID)

        let titleClock = clock.tick(at: date)
        let titleChange = try document.setTitle(title, clock: titleClock)
        _ = try await changeStore.writeBookChange(
            titleChange,
            bookID: bookID,
            deviceID: deviceID,
            clock: titleClock
        )

        let authorClock = clock.tick(at: date)
        let authorChange = try document.setAuthors(authors, clock: authorClock)
        _ = try await changeStore.writeBookChange(
            authorChange,
            bookID: bookID,
            deviceID: deviceID,
            clock: authorClock
        )

        let indexed = try makeIndexedBook(document)
        try await catalog.upsert(indexed)
        return indexed
    }

    public func books() async throws -> [IndexedBook] {
        try await catalog.allBooks()
    }

    public func search(_ query: String) async throws -> [IndexedBook] {
        try await catalog.search(query)
    }

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
            try await catalog.upsert(makeIndexedBook(document))
        }
    }

    private func makeIndexedBook(_ document: AutomergeBookDocument) throws -> IndexedBook {
        let book = try document.resolvedBook()
        return IndexedBook(
            id: book.id,
            title: book.title,
            authors: book.authors,
            modifiedMilliseconds: book.modifiedClock.physicalMilliseconds,
            isDeleted: book.isDeleted,
            snapshot: document.snapshot()
        )
    }
}

public enum LibraryRepositoryError: Error, Equatable {
    case unsupportedFormat(Int)
    case missingDependencies(UUID)
}
