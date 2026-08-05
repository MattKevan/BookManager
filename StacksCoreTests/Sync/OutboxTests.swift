import Foundation
import Testing
@testable import StacksCore

@Suite
struct OutboxTests {
    private func outbox() throws -> Outbox {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try Outbox(root: dir)
    }

    @Test
    func stagesPendingAndRemoves() throws {
        let box = try outbox()
        var clock = HybridLogicalClock(nodeID: UUID())
        let id = UUID()
        let deviceID = UUID()
        // The same clock + deviceID + bytes are passed to both stages so the
        // dedupe path is genuinely exercised: identical book/device directory,
        // clockPart and digest → identical filename.
        let first = clock.tick()
        let url = try box.stage(change: Data("one".utf8), bookID: id, deviceID: deviceID, clock: first)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try box.pendingCount() == 1)
        // Identical change (same clock, same bytes) dedupes.
        _ = try box.stage(change: Data("one".utf8), bookID: id, deviceID: deviceID, clock: first)
        #expect(try box.pendingCount() == 1)
        try box.remove(url)
        #expect(try box.pendingCount() == 0)
    }

    @Test
    func survivesReopen() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var box = try Outbox(root: dir)
        var clock = HybridLogicalClock(nodeID: UUID())
        _ = try box.stage(change: Data("x".utf8), bookID: UUID(), deviceID: UUID(), clock: clock.tick())
        // Reopen from disk.
        box = try Outbox(root: dir)
        #expect(try box.pendingCount() == 1)
    }
}
