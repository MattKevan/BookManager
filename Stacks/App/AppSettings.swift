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

    // MARK: - Sharing pane

    static let shareLibraryOverNetworkKey = "shareLibraryOverNetwork"
    static let shareLibraryOverNetworkDefault = false
    static let advertiseWithBonjourKey = "advertiseWithBonjour"
    static let advertiseWithBonjourDefault = true
    static let requireSharePasswordKey = "requireSharePassword"
    static let requireSharePasswordDefault = false
    static let shareUsernameKey = "shareUsername"
    static let sharePortKey = "sharePort"
    static let sharePortDefault = 8080

    private var _shareLibraryOverNetwork: Bool
    private var _advertiseWithBonjour: Bool
    private var _requireSharePassword: Bool
    private var _shareUsername: String
    private var _sharePort: Int

    /// Share the open library over the LAN (the Settings → Sharing toggle).
    /// The server lifecycle is owned by `LibrarySession.sharing`; this is the
    /// persisted preference + the pane's source of truth.
    var shareLibraryOverNetwork: Bool {
        get { _shareLibraryOverNetwork }
        set {
            _shareLibraryOverNetwork = newValue
            UserDefaults.standard.set(newValue, forKey: Self.shareLibraryOverNetworkKey)
        }
    }

    /// Advertise the shared library over Bonjour so other Stacks clients can
    /// discover it (the Shared sidebar section browses `_bookmanager._tcp`).
    var advertiseWithBonjour: Bool {
        get { _advertiseWithBonjour }
        set {
            _advertiseWithBonjour = newValue
            UserDefaults.standard.set(newValue, forKey: Self.advertiseWithBonjourKey)
        }
    }

    /// Gate the shared library behind basic auth. The password lives in the
    /// Keychain (`ShareCredentials`); the username is a plain preference.
    var requireSharePassword: Bool {
        get { _requireSharePassword }
        set {
            _requireSharePassword = newValue
            UserDefaults.standard.set(newValue, forKey: Self.requireSharePasswordKey)
        }
    }

    var shareUsername: String {
        get { _shareUsername }
        set {
            _shareUsername = newValue
            UserDefaults.standard.set(newValue, forKey: Self.shareUsernameKey)
        }
    }

    /// The port the shared server binds (8080 default; change it when
    /// another service already holds 8080).
    var sharePort: Int {
        get { _sharePort }
        set {
            _sharePort = newValue
            UserDefaults.standard.set(newValue, forKey: Self.sharePortKey)
        }
    }

    init(defaults: UserDefaults = .standard) {
        _automaticallyFetchMissingMetadata = defaults.object(forKey: Self.automaticallyFetchMissingMetadataKey) as? Bool
            ?? Self.automaticallyFetchMissingMetadataDefault
        _shareLibraryOverNetwork = defaults.object(forKey: Self.shareLibraryOverNetworkKey) as? Bool
            ?? Self.shareLibraryOverNetworkDefault
        _advertiseWithBonjour = defaults.object(forKey: Self.advertiseWithBonjourKey) as? Bool
            ?? Self.advertiseWithBonjourDefault
        _requireSharePassword = defaults.object(forKey: Self.requireSharePasswordKey) as? Bool
            ?? Self.requireSharePasswordDefault
        _shareUsername = defaults.string(forKey: Self.shareUsernameKey) ?? ""
        _sharePort = defaults.object(forKey: Self.sharePortKey) as? Int
            ?? Self.sharePortDefault
    }
}
