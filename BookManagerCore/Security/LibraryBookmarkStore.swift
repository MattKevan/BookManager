import Foundation

public struct ResolvedLibraryBookmark: Sendable {
    public let url: URL
    public let isStale: Bool
}

public struct LibraryBookmarkStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "librarySecurityBookmarks"
    private let recencyKey = "librarySecurityBookmarkRecency"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func save(_ url: URL, for libraryID: UUID, at date: Date = .now) throws {
        let data = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        var bookmarks = defaults.dictionary(forKey: key) as? [String: Data] ?? [:]
        bookmarks[libraryID.uuidString] = data
        defaults.set(bookmarks, forKey: key)
        var recency = defaults.dictionary(forKey: recencyKey) as? [String: TimeInterval] ?? [:]
        recency[libraryID.uuidString] = date.timeIntervalSinceReferenceDate
        defaults.set(recency, forKey: recencyKey)
    }

    public func resolve(_ libraryID: UUID) throws -> ResolvedLibraryBookmark {
        guard
            let bookmarks = defaults.dictionary(forKey: key) as? [String: Data],
            let data = bookmarks[libraryID.uuidString]
        else {
            throw LibraryBookmarkError.notFound(libraryID)
        }
        var stale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        return ResolvedLibraryBookmark(url: url, isStale: stale)
    }

    /// A bookmarked library and when it was last opened, newest first.
    public struct RecentLibrary: Sendable, Identifiable, Equatable {
        public let id: UUID
        public let lastOpenedAt: Date

        public init(id: UUID, lastOpenedAt: Date) {
            self.id = id
            self.lastOpenedAt = lastOpenedAt
        }
    }

    /// Every bookmarked library id.
    public func libraryIDs() -> [UUID] {
        (defaults.dictionary(forKey: key) as? [String: Data] ?? [:])
            .keys.compactMap(UUID.init(uuidString:))
    }

    /// All bookmarked libraries with recency, ordered newest first.
    public func recentLibraries() -> [RecentLibrary] {
        let recency = defaults.dictionary(forKey: recencyKey) as? [String: TimeInterval] ?? [:]
        return libraryIDs()
            .compactMap { id in
                recency[id.uuidString].map {
                    RecentLibrary(id: id, lastOpenedAt: Date(timeIntervalSinceReferenceDate: $0))
                }
            }
            .sorted { $0.lastOpenedAt > $1.lastOpenedAt }
    }

    /// The id of the most recently opened library, or nil when none.
    public func mostRecentlyOpenedLibraryID() -> UUID? {
        recentLibraries().first?.id
    }
}

public enum LibraryBookmarkError: Error, Equatable {
    case notFound(UUID)
}
