import Foundation
import Testing
@testable import BookManagerCore

@Suite
struct SyncStateTests {
    private func stateDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test
    func recordsAndReadsAppliedFingerprints() throws {
        let dir = try stateDir()
        let libraryID = UUID()
        let state = try SyncState(root: dir, libraryID: libraryID)
        #expect(try state.appliedFingerprints().isEmpty)
        try state.recordApplied(["abc", "def"])
        #expect(try state.appliedFingerprints() == ["abc", "def"])
        // A reopened state (same library ID) sees the persisted set.
        let reopened = try SyncState(root: dir, libraryID: libraryID)
        #expect(try reopened.appliedFingerprints() == ["abc", "def"])
        // A different library ID has its own empty record.
        let other = try SyncState(root: dir, libraryID: UUID())
        #expect(try other.appliedFingerprints().isEmpty)
    }

    @Test
    func corruptOrMissingStateDegradesToEmpty() throws {
        let dir = try stateDir()
        // No file yet: empty, no throw.
        let state = try SyncState(root: dir, libraryID: UUID())
        #expect(try state.appliedFingerprints().isEmpty)
        // Corrupt JSON: still empty, no throw.
        let url = try state.fileURL
        try Data("not json".utf8).write(to: url)
        #expect(try state.appliedFingerprints().isEmpty)
        // Reset clears.
        try state.recordApplied(["x"])
        try state.reset()
        #expect(try state.appliedFingerprints().isEmpty)
    }

    @Test
    func outboxIsPerLibrary() throws {
        // The outbox root must be scoped to the library ID: draining library
        // B's outbox must never see library A's pending changes.
        let dir = try stateDir()
        let first = try SyncState(root: dir, libraryID: UUID())
        let second = try SyncState(root: dir, libraryID: UUID())
        var clock = HybridLogicalClock(nodeID: UUID())
        _ = try first.outbox.stage(
            change: Data("a".utf8), bookID: UUID(), deviceID: UUID(), clock: clock.tick()
        )
        #expect(try second.outbox.pendingCount() == 0)
        #expect(try first.outbox.pendingCount() == 1)
    }
}
