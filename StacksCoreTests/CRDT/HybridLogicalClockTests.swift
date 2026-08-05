import Foundation
import Testing
@testable import StacksCore

@Suite
struct HybridLogicalClockTests {
    private let nodeA = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let nodeB = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    @Test
    func tickAdvancesLogicalCounterWhenWallTimeDoesNotAdvance() {
        var state = HybridLogicalClock(physicalMilliseconds: 1_000, logical: 2, nodeID: nodeA)

        let next = state.tick(at: Date(timeIntervalSince1970: 1))

        #expect(next.physicalMilliseconds == 1_000)
        #expect(next.logical == 3)
        #expect(state == next)
    }

    @Test
    func tickUsesNewWallTimeAndResetsCounter() {
        var state = HybridLogicalClock(physicalMilliseconds: 1_000, logical: 4, nodeID: nodeA)

        let next = state.tick(at: Date(timeIntervalSince1970: 2))

        #expect(next.physicalMilliseconds == 2_000)
        #expect(next.logical == 0)
    }

    @Test
    func observingRemoteClockProducesValueAfterLocalAndRemote() {
        var local = HybridLogicalClock(physicalMilliseconds: 1_000, logical: 3, nodeID: nodeA)
        let remote = HybridLogicalClock(physicalMilliseconds: 2_000, logical: 7, nodeID: nodeB)

        let next = local.observe(remote, at: Date(timeIntervalSince1970: 1.5))

        #expect(next > remote)
        #expect(next.physicalMilliseconds == 2_000)
        #expect(next.logical == 8)
    }

    @Test
    func observingRemoteClockIncrementsLocalLogicalCounterWhenLocalPhysicalTimeWins() {
        var local = HybridLogicalClock(physicalMilliseconds: 2_000, logical: 3, nodeID: nodeA)
        let remote = HybridLogicalClock(physicalMilliseconds: 1_000, logical: 7, nodeID: nodeB)

        let next = local.observe(remote, at: Date(timeIntervalSince1970: 1.5))

        #expect(next.physicalMilliseconds == 2_000)
        #expect(next.logical == 4)
    }

    @Test
    func observingRemoteClockUsesLargestLogicalCounterWhenPhysicalTimesAreEqual() {
        var local = HybridLogicalClock(physicalMilliseconds: 2_000, logical: 3, nodeID: nodeA)
        let remote = HybridLogicalClock(physicalMilliseconds: 2_000, logical: 7, nodeID: nodeB)

        let next = local.observe(remote, at: Date(timeIntervalSince1970: 1.5))

        #expect(next.physicalMilliseconds == 2_000)
        #expect(next.logical == 8)
    }

    @Test
    func observingRemoteClockResetsLogicalCounterWhenWallTimeWins() {
        var local = HybridLogicalClock(physicalMilliseconds: 1_000, logical: 3, nodeID: nodeA)
        let remote = HybridLogicalClock(physicalMilliseconds: 2_000, logical: 7, nodeID: nodeB)

        let next = local.observe(remote, at: Date(timeIntervalSince1970: 3))

        #expect(next.physicalMilliseconds == 3_000)
        #expect(next.logical == 0)
    }

    @Test
    func tickCarriesToPhysicalTimeWhenLogicalCounterOverflows() {
        var state = HybridLogicalClock(physicalMilliseconds: 1_000, logical: .max, nodeID: nodeA)

        let next = state.tick(at: Date(timeIntervalSince1970: 1))

        #expect(next.physicalMilliseconds == 1_001)
        #expect(next.logical == 0)
    }

    @Test
    func observingRemoteClockCarriesWhenLocalPhysicalTimeWinsAndLogicalCounterOverflows() {
        var local = HybridLogicalClock(physicalMilliseconds: 1_000, logical: .max, nodeID: nodeA)
        let remote = HybridLogicalClock(physicalMilliseconds: 999, logical: 0, nodeID: nodeB)

        let next = local.observe(remote, at: Date(timeIntervalSince1970: 0.5))

        #expect(next.physicalMilliseconds == 1_001)
        #expect(next.logical == 0)
    }

    @Test
    func observingRemoteClockCarriesWhenRemotePhysicalTimeWinsAndLogicalCounterOverflows() {
        var local = HybridLogicalClock(physicalMilliseconds: 999, logical: 0, nodeID: nodeA)
        let remote = HybridLogicalClock(physicalMilliseconds: 1_000, logical: .max, nodeID: nodeB)

        let next = local.observe(remote, at: Date(timeIntervalSince1970: 0.5))

        #expect(next.physicalMilliseconds == 1_001)
        #expect(next.logical == 0)
    }

    @Test
    func observingRemoteClockCarriesWhenPhysicalTimesAreEqualAndLogicalCounterOverflows() {
        var local = HybridLogicalClock(physicalMilliseconds: 1_000, logical: 0, nodeID: nodeA)
        let remote = HybridLogicalClock(physicalMilliseconds: 1_000, logical: .max, nodeID: nodeB)

        let next = local.observe(remote, at: Date(timeIntervalSince1970: 0.5))

        #expect(next.physicalMilliseconds == 1_001)
        #expect(next.logical == 0)
    }

    @Test
    func nodeIDBreaksOtherwiseEqualTies() {
        let first = HybridLogicalClock(physicalMilliseconds: 1_000, logical: 0, nodeID: nodeA)
        let second = HybridLogicalClock(physicalMilliseconds: 1_000, logical: 0, nodeID: nodeB)

        #expect(first < second)
    }
}
