import Foundation
import Testing
@testable import BookManagerCore

@Suite
struct OfflineBookEditTests {
    @Test
    func appliesEditToSnapshotWithoutFilesystem() throws {
        let deviceID = UUID()
        let seed = try AutomergeBookDocument.new(bookID: UUID(), deviceID: deviceID)
        let (changes, resolved) = try OfflineBookEdit.apply(
            BookEdit(title: "New Title", tags: ["science"]),
            to: seed.snapshot(),
            deviceID: deviceID
        )
        #expect(!changes.isEmpty)
        #expect(resolved.title == "New Title")
        #expect(resolved.tags == ["science"])
    }

    @Test
    func redundantEditLeavesResolvedStateUnchanged() throws {
        let deviceID = UUID()
        let document = try AutomergeBookDocument.new(bookID: UUID(), deviceID: deviceID)
        var clock = HybridLogicalClock(nodeID: deviceID)
        _ = try document.setTitle("T", clock: clock.tick())
        let snapshot = document.snapshot()

        // apply(_ edit:clock:date:) is non-differential for non-nil fields (the
        // editor filters unchanged fields before calling). The offline-edit
        // invariant is that a redundant change leaves the resolved state
        // unchanged and re-applies without drift.
        let (changes, resolved) = try OfflineBookEdit.apply(
            BookEdit(title: "T"), to: snapshot, deviceID: deviceID
        )
        #expect(resolved.title == "T")
        #expect(changes.count == 1)

        // Re-applying the redundant change to the original snapshot does not
        // change the resolved title.
        let replay = try AutomergeBookDocument(snapshot: snapshot, deviceID: UUID())
        for change in changes {
            try replay.apply(change)
        }
        #expect(try replay.resolvedBook().title == "T")
    }
}
