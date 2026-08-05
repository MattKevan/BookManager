import Foundation
import Testing
@testable import StacksCore

@Suite
struct ConvergenceTests {
    private struct Mac {
        let deviceID = UUID()
        let catalog: LocalCatalog
        let state: SyncState
        let layout: LibraryLayout

        init(layout: LibraryLayout) throws {
            catalog = try LocalCatalog(
                databaseURL: FileManager.default.temporaryDirectory
                    .appending(path: "\(UUID().uuidString).sqlite")
            )
            state = try SyncState(
                root: FileManager.default.temporaryDirectory
                    .appending(path: "\(UUID().uuidString)", directoryHint: .isDirectory),
                libraryID: UUID()
            )
            self.layout = layout
        }

        func engine() throws -> SyncEngine {
            SyncEngine(layout: layout, catalog: catalog, state: state, deviceID: deviceID)
        }

        /// The offline-edit path (Task 4 extracts `OfflineBookEdit`): apply the
        /// edit to a snapshot without touching the library, stage the changes
        /// into this Mac's outbox, return the new snapshot.
        func edit(_ edit: BookEdit, bookID: UUID, base: Data) throws -> Data {
            let document = try AutomergeBookDocument(snapshot: base, deviceID: deviceID)
            let changes = try document.apply(
                edit,
                clock: HybridLogicalClock(nodeID: deviceID),
                date: .now
            )
            for change in changes {
                _ = try state.outbox.stage(
                    change: change,
                    bookID: bookID,
                    deviceID: deviceID,
                    clock: HybridLogicalClock(nodeID: deviceID)
                )
            }
            return document.snapshot()
        }
    }

    @Test
    func twoMacsConvergeAfterOfflineEdits() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let layout = LibraryLayout(root: root)
        try layout.create(manifest: LibraryManifest(id: UUID()))
        var macA = try Mac(layout: layout)
        var macB = try Mac(layout: layout)

        // A book exists (created on A, synced to both Macs' catalogs).
        let bookID = UUID()
        let seed = try AutomergeBookDocument.new(bookID: bookID, deviceID: macA.deviceID)
        let seedDoc = try AutomergeBookDocument(snapshot: seed.snapshot(), deviceID: macA.deviceID)
        var clock = HybridLogicalClock(nodeID: macA.deviceID)
        let change = try seedDoc.setTitle("Shared", clock: clock.tick())
        _ = try await ChangeStore(layout: layout)
            .writeBookChange(change, bookID: bookID, deviceID: macA.deviceID, clock: clock)
        _ = try await macA.engine().ingest()
        _ = try await macB.engine().ingest()
        #expect(try await macA.catalog.book(id: bookID)?.title == "Shared")
        #expect(try await macB.catalog.book(id: bookID)?.title == "Shared")

        // Offline edits: A renames, B retitles (same field, concurrent), each
        // staged only in its own outbox.
        let base = try #require(try await macA.catalog.book(id: bookID)).snapshot
        _ = try macA.edit(BookEdit(title: "Title From A"), bookID: bookID, base: base)
        _ = try macB.edit(BookEdit(title: "Title From B"), bookID: bookID, base: base)

        // Reconnect: each Mac drains its outbox and ingests. Convergence
        // requires every Mac to have ingested every change, so A re-ingests
        // once B's change is in the shared store.
        _ = try await macA.engine().drainOutbox()
        _ = try await macA.engine().ingest()
        _ = try await macB.engine().drainOutbox()
        _ = try await macB.engine().ingest()
        _ = try await macA.engine().ingest()

        // Acceptance 9: same-field concurrent edits resolve deterministically —
        // both Macs agree, and it is one of the two authored values.
        let titleA = try #require(try await macA.catalog.book(id: bookID)).title
        let titleB = try #require(try await macB.catalog.book(id: bookID)).title
        #expect(titleA == titleB)
        #expect(["Title From A", "Title From B"].contains(titleA))

        // Acceptance 8: identical canonical paths.
        let pathA = try #require(try await macA.catalog.book(id: bookID)).relativePath
        let pathB = try #require(try await macB.catalog.book(id: bookID)).relativePath
        #expect(pathA == pathB)
    }
}
