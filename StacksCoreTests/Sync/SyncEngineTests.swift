import Foundation
import GRDB
import Testing
@testable import StacksCore

@Suite
struct SyncEngineTests {
    private struct Harness {
        let layout: LibraryLayout
        let catalog: LocalCatalog
        let state: SyncState
        let deviceID = UUID()
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            layout = LibraryLayout(root: root)
            try layout.create(manifest: LibraryManifest(id: UUID()))
            catalog = try LocalCatalog(
                databaseURL: FileManager.default.temporaryDirectory
                    .appending(path: "\(UUID().uuidString).sqlite")
            )
            state = try SyncState(
                root: FileManager.default.temporaryDirectory
                    .appending(path: "\(UUID().uuidString)", directoryHint: .isDirectory),
                libraryID: UUID()
            )
        }

        func engine() throws -> SyncEngine {
            SyncEngine(layout: layout, catalog: catalog, state: state, deviceID: deviceID)
        }
    }

    @Test
    func ingestsUnseenChangesAndIsIdempotent() async throws {
        let h = try Harness()
        // Simulate a remote device's change store: write a change file directly.
        let remoteDevice = UUID()
        let bookID = UUID()
        let document = try AutomergeBookDocument.new(bookID: bookID, deviceID: remoteDevice)
        var clock = HybridLogicalClock(nodeID: remoteDevice)
        let change = try document.setTitle("Remote Title", clock: clock.tick())
        let store = ChangeStore(layout: h.layout)
        _ = try await store.writeBookChange(change, bookID: bookID, deviceID: remoteDevice, clock: clock)

        let engine = try h.engine()
        let report = try await engine.ingest()
        #expect(report.appliedChangeCount == 1)
        #expect(report.quarantined.isEmpty)
        #expect(try await h.catalog.allBooks().first?.title == "Remote Title")

        // Idempotent: re-ingest applies nothing new.
        let second = try await engine.ingest()
        #expect(second.appliedChangeCount == 0)
        #expect(try await h.catalog.allBooks().count == 1)
    }

    @Test
    func quarantinesCorruptChangesWithoutCrashing() async throws {
        let h = try Harness()
        // A change file with garbage bytes, written directly into the library.
        let corruptDir = h.layout.bookChangesRoot
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: corruptDir, withIntermediateDirectories: true)
        let corrupt = corruptDir.appending(path: "1-0-deadbeef.amchange")
        try Data("not an automerge change".utf8).write(to: corrupt)

        let engine = try h.engine()
        let report = try await engine.ingest()
        #expect(report.quarantined.count == 1)
        // The corrupt file left the change store and landed in quarantine.
        #expect(!FileManager.default.fileExists(atPath: corrupt.path))
        #expect(try await h.catalog.allBooks().isEmpty)
    }

    @Test
    func drainOutboxMovesChangesIntoLibraryAndIngests() async throws {
        let h = try Harness()
        // Stage an offline edit into the outbox (as the session would).
        let deviceID = h.deviceID
        let bookID = UUID()
        let document = try AutomergeBookDocument.new(bookID: bookID, deviceID: deviceID)
        var clock = HybridLogicalClock(nodeID: deviceID)
        let change = try document.setTitle("Offline Title", clock: clock.tick())
        _ = try h.state.outbox.stage(change: change, bookID: bookID, deviceID: deviceID, clock: clock)

        let engine = try h.engine()
        let moved = try await engine.drainOutbox()
        #expect(moved == 1)
        #expect(try h.state.outbox.pendingCount() == 0)
        let report = try await engine.ingest()
        #expect(report.appliedChangeCount == 1)
        #expect(try await h.catalog.allBooks().first?.title == "Offline Title")
    }

    @Test
    func fullRescanReingestsEverything() async throws {
        let h = try Harness()
        let deviceID = UUID()
        let bookID = UUID()
        let document = try AutomergeBookDocument.new(bookID: bookID, deviceID: deviceID)
        var clock = HybridLogicalClock(nodeID: deviceID)
        let change = try document.setTitle("Rescanned", clock: clock.tick())
        _ = try await ChangeStore(layout: h.layout)
            .writeBookChange(change, bookID: bookID, deviceID: deviceID, clock: clock)

        let engine = try h.engine()
        _ = try await engine.ingest()
        try h.state.recordApplied(["forged-fingerprint"]) // simulate drift
        try await engine.fullRescan()
        #expect(try await h.catalog.allBooks().count == 1)
    }

    @Test
    func incrementalIngestAccumulatesAcrossMultipleRuns() async throws {
        // Changes for a book often arrive in separate syncs (cloud delivery).
        // Each ingest must accumulate on the catalog's stored snapshot —
        // rebuilding from only the newly-arrived changes would drop earlier
        // contributions (and a valid change must never be quarantined).
        let h = try Harness()
        let deviceID = UUID()
        let bookID = UUID()
        let document = try AutomergeBookDocument.new(bookID: bookID, deviceID: deviceID)
        var clock = HybridLogicalClock(nodeID: deviceID)
        let titleChange = try document.setTitle("Base", clock: clock.tick())
        let tagsDoc = try AutomergeBookDocument(snapshot: document.snapshot(), deviceID: deviceID)
        let tagsChange = try tagsDoc.setTags(["science"], clock: clock.tick())
        let store = ChangeStore(layout: h.layout)

        // Ingest 1: only the title has arrived.
        _ = try await store.writeBookChange(titleChange, bookID: bookID, deviceID: deviceID, clock: clock)
        let engine = try h.engine()
        let first = try await engine.ingest()
        #expect(first.quarantined.isEmpty)
        #expect(try await h.catalog.allBooks().first?.title == "Base")

        // Ingest 2: the tags change arrives later — the earlier title must
        // survive, and nothing is quarantined.
        _ = try await store.writeBookChange(tagsChange, bookID: bookID, deviceID: deviceID, clock: clock)
        let second = try await engine.ingest()
        #expect(second.quarantined.isEmpty)
        let book = try #require(try await h.catalog.allBooks().first)
        #expect(book.title == "Base")
        #expect(book.tags == ["science"])
    }

    @Test
    func outOfOrderDeliveryConvergesWithoutQuarantine() async throws {
        // Out-of-order cloud delivery: every change is a full-schema re-encode
        // (decode → mutate → commit), so a change delivered ahead of its
        // predecessor embeds the predecessor's state. It must ingest cleanly —
        // never quarantined, never lost — and later delivery of the earlier
        // change must still converge. This locks the 4a final-review ruling's
        // intent (no data loss on reordered delivery) against the actual,
        // self-contained change format.
        let h = try Harness()
        let deviceID = UUID()
        let bookID = UUID()
        let baseDoc = try AutomergeBookDocument.new(bookID: bookID, deviceID: deviceID)
        var clock = HybridLogicalClock(nodeID: deviceID)
        let base = try baseDoc.setTitle("Base", clock: clock.tick())
        let depDoc = try AutomergeBookDocument(snapshot: baseDoc.snapshot(), deviceID: deviceID)
        let dep = try depDoc.setTags(["science"], clock: clock.tick())
        let store = ChangeStore(layout: h.layout)
        // Deliver ONLY the later change first; the base arrives later.
        _ = try await store.writeBookChange(dep, bookID: bookID, deviceID: deviceID, clock: clock)

        let engine = try h.engine()
        let first = try await engine.ingest()
        #expect(first.quarantined.isEmpty)
        let firstBook = try #require(try await h.catalog.allBooks().first)
        #expect(firstBook.title == "Base")
        #expect(firstBook.tags == ["science"])

        // The earlier change arrives later: nothing quarantined, still converged.
        _ = try await store.writeBookChange(base, bookID: bookID, deviceID: deviceID, clock: clock)
        let second = try await engine.ingest()
        #expect(second.quarantined.isEmpty)
        let book = try #require(try await h.catalog.allBooks().first)
        #expect(book.title == "Base")
        #expect(book.tags == ["science"])
    }
}
