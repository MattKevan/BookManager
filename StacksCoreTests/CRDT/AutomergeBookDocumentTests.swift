import Automerge
import Foundation
import Testing
@testable import StacksCore

@Suite
struct AutomergeBookDocumentTests {
    private let bookID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    private let deviceA = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
    private let deviceB = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!

    @Test
    func creationChangeRoundTripsIntoEmptyReplica() throws {
        let source = try AutomergeBookDocument.new(bookID: bookID, deviceID: deviceA)
        let clock = HybridLogicalClock(physicalMilliseconds: 1_000, nodeID: deviceA)
        let change = try source.setTitle("Range", clock: clock)
        let replica = try AutomergeBookDocument.empty(deviceID: deviceB)

        try replica.apply(change)

        #expect(try replica.resolvedBook().id == bookID)
        #expect(try replica.resolvedBook().title == "Range")
        #expect(replica.heads() == source.heads())
    }

    @Test
    func concurrentDifferentFieldsSurvive() throws {
        let base = try AutomergeBookDocument.new(bookID: bookID, deviceID: deviceA)
        let creation = try base.setTitle("Range", clock: .init(physicalMilliseconds: 1_000, nodeID: deviceA))

        let first = try AutomergeBookDocument.empty(deviceID: deviceA)
        let second = try AutomergeBookDocument.empty(deviceID: deviceB)
        try first.apply(creation)
        try second.apply(creation)

        let titleChange = try first.setTitle(
            "Range: Revised",
            clock: .init(physicalMilliseconds: 2_000, nodeID: deviceA)
        )
        let authorChange = try second.setAuthors(
            ["David Epstein"],
            clock: .init(physicalMilliseconds: 2_100, nodeID: deviceB)
        )

        try first.apply(authorChange)
        try second.apply(titleChange)

        #expect(try first.resolvedBook() == second.resolvedBook())
        #expect(try first.resolvedBook().title == "Range: Revised")
        #expect(try first.resolvedBook().authors == ["David Epstein"])
    }

    @Test
    func newerHLCWinsSameFieldRegardlessOfDeliveryOrder() throws {
        let base = try AutomergeBookDocument.new(bookID: bookID, deviceID: deviceA)
        let creation = try base.setTitle("Original", clock: .init(physicalMilliseconds: 1_000, nodeID: deviceA))
        let first = try AutomergeBookDocument.empty(deviceID: deviceA)
        let second = try AutomergeBookDocument.empty(deviceID: deviceB)
        try first.apply(creation)
        try second.apply(creation)

        let older = try first.setTitle("Older", clock: .init(physicalMilliseconds: 2_000, nodeID: deviceA))
        let newer = try second.setTitle("Newer", clock: .init(physicalMilliseconds: 3_000, nodeID: deviceB))

        try first.apply(newer)
        try second.apply(older)

        #expect(try first.resolvedBook().title == "Newer")
        #expect(try second.resolvedBook().title == "Newer")
    }

    @Test
    func savedSnapshotCanContinueWithNewDeviceActor() throws {
        let source = try AutomergeBookDocument.new(bookID: bookID, deviceID: deviceA)
        _ = try source.setTitle("Range", clock: .init(physicalMilliseconds: 1_000, nodeID: deviceA))

        let reopened = try AutomergeBookDocument(snapshot: source.snapshot(), deviceID: deviceB)
        let change = try reopened.setAuthors(
            ["David Epstein"],
            clock: .init(physicalMilliseconds: 2_000, nodeID: deviceB)
        )

        #expect(!change.isEmpty)
        #expect(try reopened.resolvedBook().authors == ["David Epstein"])
    }
}
