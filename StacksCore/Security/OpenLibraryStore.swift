import Foundation

/// Persists the set of libraries currently open in the app: security-scoped
/// bookmarks keyed by library ID, the ordered open list (home first), the home
/// designation, and display names — so launch can reopen exactly what the user
/// had open. Separate from `LibraryBookmarkStore` (which powers the Open
/// Recent menu); the two stores use disjoint UserDefaults keys.
public struct OpenLibraryStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let bookmarksKey = "openLibraryBookmarks"
    private let orderKey = "openLibraryOrder"
    private let homeKey = "openLibraryHome"
    private let namesKey = "openLibraryNames"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Bookmarks

    /// Stores a security-scoped bookmark for `libraryID` plus its display name.
    /// Throws when the bookmark cannot be created (e.g. the URL is not
    /// security-scope-capable).
    public func save(_ url: URL, for libraryID: UUID, name: String) throws {
        let data = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        var bookmarks = defaults.dictionary(forKey: bookmarksKey) as? [String: Data] ?? [:]
        bookmarks[libraryID.uuidString] = data
        defaults.set(bookmarks, forKey: bookmarksKey)
        var names = defaults.dictionary(forKey: namesKey) as? [String: String] ?? [:]
        names[libraryID.uuidString] = name
        defaults.set(names, forKey: namesKey)
    }

    /// Resolves a stored bookmark; throws `LibraryBookmarkError.notFound` when
    /// the library has no bookmark.
    public func resolve(_ libraryID: UUID) throws -> ResolvedLibraryBookmark {
        guard
            let bookmarks = defaults.dictionary(forKey: bookmarksKey) as? [String: Data],
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

    /// Removes the library from the open set entirely: bookmark, display name,
    /// order position, and the home designation (when it was home).
    public func remove(_ libraryID: UUID) {
        var bookmarks = defaults.dictionary(forKey: bookmarksKey) as? [String: Data] ?? [:]
        bookmarks.removeValue(forKey: libraryID.uuidString)
        defaults.set(bookmarks, forKey: bookmarksKey)
        var names = defaults.dictionary(forKey: namesKey) as? [String: String] ?? [:]
        names.removeValue(forKey: libraryID.uuidString)
        defaults.set(names, forKey: namesKey)
        setOrder(order().filter { $0 != libraryID })
        if home() == libraryID { setHome(nil) }
    }

    // MARK: - Order

    /// The persisted open-library order (home first when designated), newest
    /// arrangement wins; entries without a bookmark are dropped.
    public func order() -> [UUID] {
        let stored = (defaults.array(forKey: orderKey) as? [String] ?? [])
            .compactMap(UUID.init(uuidString:))
        let bookmarks = defaults.dictionary(forKey: bookmarksKey) as? [String: Data] ?? [:]
        return stored.filter { bookmarks[$0.uuidString] != nil }
    }

    public func setOrder(_ libraryIDs: [UUID]) {
        defaults.set(libraryIDs.map(\.uuidString), forKey: orderKey)
    }

    // MARK: - Home

    /// The persisted home library id, or nil when none is designated.
    public func home() -> UUID? {
        defaults.string(forKey: homeKey).flatMap(UUID.init(uuidString:))
    }

    public func setHome(_ libraryID: UUID?) {
        if let libraryID {
            defaults.set(libraryID.uuidString, forKey: homeKey)
        } else {
            defaults.removeObject(forKey: homeKey)
        }
    }

    // MARK: - Names

    /// Display names by library id (offline sidebar rows, retry labels).
    public func names() -> [UUID: String] {
        (defaults.dictionary(forKey: namesKey) as? [String: String] ?? [:])
            .reduce(into: [UUID: String]()) { result, entry in
                guard let id = UUID(uuidString: entry.key) else { return }
                result[id] = entry.value
            }
    }
}
