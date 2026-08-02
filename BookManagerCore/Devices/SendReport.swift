import Foundation

public enum SendStatus: Sendable, Equatable {
    case sent(format: String)
    case converted(from: String, to: String)
    case noCompatibleFormat
    case failed(String)
}

public struct SendItem: Sendable, Identifiable {
    public let id: UUID
    public let title: String
    public let status: SendStatus

    public init(id: UUID = UUID(), title: String, status: SendStatus) {
        self.id = id
        self.title = title
        self.status = status
    }
}

public struct SendReport: Sendable {
    public let items: [SendItem]

    public init(items: [SendItem]) { self.items = items }

    public var sent: [SendItem] {
        items.filter { if case .sent = $0.status { return true }; return false }
    }
    public var noCompatible: [SendItem] {
        items.filter { if case .noCompatibleFormat = $0.status { return true }; return false }
    }
    public var failed: [SendItem] {
        items.filter { if case .failed = $0.status { return true }; return false }
    }
    public var summary: String {
        "\(sent.count) sent, \(noCompatible.count) no compatible format, \(failed.count) failed"
    }
}
