import Foundation

/// The priority-ordered set of metadata sources. The lookup service consults
/// them in order and stops at the first source that returns candidates.
public struct MetadataRegistry: Sendable {
    public let sources: [any MetadataSourceProviding]

    public init(sources: [any MetadataSourceProviding]) {
        self.sources = sources
    }

    public func source(named name: String) -> (any MetadataSourceProviding)? {
        sources.first { $0.name == name }
    }
}
