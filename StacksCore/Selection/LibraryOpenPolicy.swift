import Foundation

/// How an open request should be resolved against the libraries already open
/// in this instance. Dedupe guarantees one connection per library.
public enum OpenIntent: Sendable, Equatable {
    case home       // requested to become/remain home
    case peer       // requested as an additional open library
}

public enum OpenResolution: Sendable, Equatable {
    case openNew
    case selectExisting(UUID)     // already open; select it, no second connection
    case makeHomeExisting(UUID)   // already open as a peer; role-swap to home
}

public struct ExistingLibrary: Sendable, Equatable {
    public let id: UUID
    public let isHome: Bool

    public init(id: UUID, isHome: Bool) {
        self.id = id
        self.isHome = isHome
    }
}

public enum LibraryOpenPolicy {
    public static func resolve(
        existing: [ExistingLibrary],
        manifestID: UUID,
        intent: OpenIntent
    ) -> OpenResolution {
        guard let match = existing.first(where: { $0.id == manifestID }) else {
            return .openNew
        }
        switch intent {
        case .home:
            return match.isHome ? .selectExisting(match.id) : .makeHomeExisting(match.id)
        case .peer:
            return .selectExisting(match.id)
        }
    }
}
