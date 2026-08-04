import Foundation
import Observation

/// User defaults–backed app preferences, exposed to the Settings pane.
@Observable
final class AppSettings {
    static let automaticallyFetchMissingMetadataKey = "automaticallyFetchMissingMetadata"
    static let automaticallyFetchMissingMetadataDefault = true

    /// The current app-wide value, for code paths without a view (the import
    /// hook in `LibrarySession`).
    static func automaticallyFetchMissingMetadata(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: automaticallyFetchMissingMetadataKey) as? Bool
            ?? automaticallyFetchMissingMetadataDefault
    }

    private var _automaticallyFetchMissingMetadata: Bool

    /// Enrich imported books that are missing authors/tags from the online
    /// sources after an import. On by default; the Settings pane is the
    /// opt-out.
    var automaticallyFetchMissingMetadata: Bool {
        get { _automaticallyFetchMissingMetadata }
        set {
            _automaticallyFetchMissingMetadata = newValue
            UserDefaults.standard.set(newValue, forKey: Self.automaticallyFetchMissingMetadataKey)
        }
    }

    init(defaults: UserDefaults = .standard) {
        _automaticallyFetchMissingMetadata = defaults.object(forKey: Self.automaticallyFetchMissingMetadataKey) as? Bool
            ?? Self.automaticallyFetchMissingMetadataDefault
    }
}
