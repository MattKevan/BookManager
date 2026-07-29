import Foundation

public struct HybridLogicalClock: Codable, Hashable, Sendable, Comparable {
    public private(set) var physicalMilliseconds: Int64
    public private(set) var logical: UInt32
    public let nodeID: UUID

    public init(physicalMilliseconds: Int64 = 0, logical: UInt32 = 0, nodeID: UUID) {
        self.physicalMilliseconds = physicalMilliseconds
        self.logical = logical
        self.nodeID = nodeID
    }

    @discardableResult
    public mutating func tick(at date: Date = .now) -> Self {
        let now = Self.milliseconds(date)
        if now > physicalMilliseconds {
            physicalMilliseconds = now
            logical = 0
        } else {
            logical &+= 1
        }
        return self
    }

    @discardableResult
    public mutating func observe(_ remote: Self, at date: Date = .now) -> Self {
        let now = Self.milliseconds(date)
        let maximum = max(now, max(physicalMilliseconds, remote.physicalMilliseconds))

        switch (maximum == physicalMilliseconds, maximum == remote.physicalMilliseconds) {
        case (true, true):
            logical = max(logical, remote.logical) &+ 1
        case (true, false):
            logical &+= 1
        case (false, true):
            logical = remote.logical &+ 1
        case (false, false):
            logical = 0
        }

        physicalMilliseconds = maximum
        return self
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.physicalMilliseconds != rhs.physicalMilliseconds {
            return lhs.physicalMilliseconds < rhs.physicalMilliseconds
        }
        if lhs.logical != rhs.logical {
            return lhs.logical < rhs.logical
        }
        return lhs.nodeID.uuidString < rhs.nodeID.uuidString
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded(.down))
    }
}
