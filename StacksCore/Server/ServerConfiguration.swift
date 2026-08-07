import Foundation

/// Configuration for the shared library server (embedded in the macOS app and
/// the headless CLI).
public struct ServerConfiguration: Sendable {
    public var port: Int
    public var libraryPath: String
    /// Where the server keeps its disposable catalog indexes. Must be owned by
    /// the server — never shared with the app's indexes directory (two SQLite
    /// writers on one file is not allowed).
    public var indexesDirectory: URL
    /// Optional basic-auth gate. When either is nil, the server is anonymous
    /// on the LAN (the share toggle is the only gate — see auth decision).
    public var username: String?
    public var password: String?
    public var advertiseBonjour: Bool
    /// The Bonjour display name (defaults to the library folder name).
    public var displayName: String?

    public init(
        port: Int,
        libraryPath: String,
        indexesDirectory: URL,
        username: String? = nil,
        password: String? = nil,
        advertiseBonjour: Bool = true,
        displayName: String? = nil
    ) {
        self.port = port
        self.libraryPath = libraryPath
        self.indexesDirectory = indexesDirectory
        self.username = username
        self.password = password
        self.advertiseBonjour = advertiseBonjour
        self.displayName = displayName
    }
}
