import Foundation

public struct ResolvedLibraryBookmark: Sendable {
    public let url: URL
    public let isStale: Bool
}

public struct LibraryBookmarkStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "librarySecurityBookmarks"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func save(_ url: URL, for libraryID: UUID) throws {
        let data = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        var bookmarks = defaults.dictionary(forKey: key) as? [String: Data] ?? [:]
        bookmarks[libraryID.uuidString] = data
        defaults.set(bookmarks, forKey: key)
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
}

public enum LibraryBookmarkError: Error, Equatable {
    case notFound(UUID)
}
