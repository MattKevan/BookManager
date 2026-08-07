import Foundation
import Testing
@testable import StacksCore

@Suite
struct JournalTests {
    private func makeLayout() throws -> (URL, LibraryLayout) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let layout = LibraryLayout(root: root)
        try layout.create(manifest: LibraryManifest(id: UUID()))
        return (root, layout)
    }

    @Test
    func appendsAssignSequentialSeqAndReadsBack() async throws {
        let (_, layout) = try makeLayout()
        let journal = Journal(layout: layout)
        try await journal.open()
        let first = try #require(try await journal.append(
            op: .updateBook(.init(bookID: UUID(), edit: .init(title: "A")))
        ))
        let second = try #require(try await journal.append(
            op: .deleteBook(.init(bookID: UUID()))
        ))

        #expect(first.seq == 1)
        #expect(second.seq == 2)
        let records = try await journal.records(after: 0)
        #expect(records.count == 2)
        #expect(records.map(\.seq) == [1, 2])
        #expect(try await journal.records(after: 1).map(\.seq) == [2])
        #expect(await journal.currentSeq == 2)
    }

    @Test
    func idempotencySetRejectsDuplicateIds() async throws {
        let (_, layout) = try makeLayout()
        let journal = Journal(layout: layout)
        try await journal.open()
        let commandID = UUID()
        let first = try #require(try await journal.append(
            op: .deleteBook(.init(bookID: UUID())), id: commandID
        ))
        let duplicate = try await journal.append(
            op: .deleteBook(.init(bookID: UUID())), id: commandID
        )

        #expect(first.seq == 1)
        #expect(duplicate == nil)
        #expect(try await journal.records(after: 0).count == 1)
    }

    @Test
    func tornTailLineIsDroppedOnRead() async throws {
        let (_, layout) = try makeLayout()
        let journal = Journal(layout: layout)
        try await journal.open()
        _ = try await journal.append(op: .deleteBook(.init(bookID: UUID())))

        // Simulate a crash mid-append: garbage half-line at the tail.
        let segment = try #require(try FileManager.default.contentsOfDirectory(
            at: layout.journalRoot, includingPropertiesForKeys: nil
        ).first)
        let handle = try FileHandle(forWritingTo: segment)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"id\":\"truncat".utf8))
        try handle.close()

        let records = try await journal.records(after: 0)
        #expect(records.count == 1)
    }

    @Test
    func reopenRebuildsSeqAndIdempotencyFromTail() async throws {
        let (_, layout) = try makeLayout()
        let first = Journal(layout: layout)
        try await first.open()
        let commandID = UUID()
        _ = try await first.append(op: .deleteBook(.init(bookID: UUID())), id: commandID)
        _ = try await first.append(op: .deleteBook(.init(bookID: UUID())))

        // A fresh Journal over the same layout sees the same seq + id set.
        let reopened = Journal(layout: layout)
        try await reopened.open()
        #expect(await reopened.currentSeq == 2)
        #expect(await reopened.appliedCommandIDs.contains(commandID))
        // The duplicate id is still rejected after reopen.
        #expect(try await reopened.append(op: .deleteBook(.init(bookID: UUID())), id: commandID) == nil)
    }

    @Test
    func snapshotRoundTrips() async throws {
        let (_, layout) = try makeLayout()
        let journal = Journal(layout: layout)
        try await journal.open()
        let book = JournalSnapshot.Book(
            bookID: UUID(), relativePath: "Alice/Range (1a2b3c4d)", title: "Range",
            authors: ["Alice"], series: nil, seriesIndex: nil, tags: [],
            rating: nil, publisher: nil, publicationDate: nil, addedDate: nil,
            languages: [], identifiers: [:], comments: nil,
            formats: [], cover: nil, isDeleted: false
        )
        let snapshot = JournalSnapshot(lastSeq: 7, books: [book])
        try await journal.writeSnapshot(snapshot)

        let loaded = try await journal.readSnapshot()
        #expect(loaded?.lastSeq == 7)
        #expect(loaded?.books.first?.title == "Range")
        #expect(loaded?.books.first?.bookID == book.bookID)
    }
}
