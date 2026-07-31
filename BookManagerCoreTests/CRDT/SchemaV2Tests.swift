import Automerge
import Foundation
import Testing
@testable import BookManagerCore

@Suite
struct SchemaV2Tests {
    private let bookID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    private let deviceA = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
    private let deviceB = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!

    private func document(deviceID: UUID? = nil) throws -> AutomergeBookDocument {
        try AutomergeBookDocument.new(bookID: bookID, deviceID: deviceID ?? deviceA)
    }

    @Test
    func oldDocumentsWithoutV2FieldsStillDecode() throws {
        // Encode a genuine v1-shaped document (bookID, titles, authors, deletions only)
        // through the raw Automerge encoder, then resolve it with the v2 adapter.
        let clock = HybridLogicalClock(physicalMilliseconds: 1_000, nodeID: deviceA)
        var v1 = V1Shape(bookID: bookID)
        v1.titles[deviceA.uuidString] = VersionedValue(value: "Range", clock: clock)
        let document = Document()
        document.actor = ActorId(uuid: deviceA)
        try AutomergeEncoder(doc: document).encode(v1)

        let reopened = try AutomergeBookDocument(snapshot: document.save(), deviceID: deviceB)
        let resolved = try reopened.resolvedBook()

        #expect(resolved.title == "Range")
        #expect(resolved.tags.isEmpty)
        #expect(resolved.formats.isEmpty)
        #expect(resolved.cover == nil)
        #expect(resolved.series == nil)
        #expect(resolved.identifiers.isEmpty)
        #expect(resolved.languages.isEmpty)
        #expect(resolved.rating == nil)
        #expect(resolved.comments == nil)
    }

    @Test
    func applyEditProducesChangesAndResolves() throws {
        let source = try document()
        let changes = try source.apply(
            BookEdit(title: "New Title", authors: ["Someone"], tags: ["x"], rating: .set(3)),
            clock: .init(physicalMilliseconds: 1_000, nodeID: deviceA),
            date: Date(timeIntervalSince1970: 1)
        )

        #expect(changes.count == 4)
        let resolved = try source.resolvedBook()
        #expect(resolved.title == "New Title")
        #expect(resolved.authors == ["Someone"])
        #expect(resolved.tags == ["x"])
        #expect(resolved.rating == 3)
    }

    private struct V1Shape: Codable {
        var schemaVersion: Int = 1
        var bookID: UUID?
        var titles: [String: VersionedValue<String>] = [:]
        var authors: [String: VersionedValue<[String]>] = [:]
        var deletions: [String: VersionedValue<Bool>] = [:]
    }

    @Test
    func v2FieldsResolveAcrossReplicas() throws {
        let source = try document()
        let base = try source.setTitle("Range", clock: .init(physicalMilliseconds: 1_000, nodeID: deviceA))
        let replica = try AutomergeBookDocument.empty(deviceID: deviceB)
        try replica.apply(base)

        let series = try replica.setSeries("Studies", clock: .init(physicalMilliseconds: 2_000, nodeID: deviceB))
        let format = BookFormatValue(
            kind: "EPUB",
            filename: "Range - David Epstein.epub",
            contentHash: "abc123",
            size: 42
        )
        let formatChange = try replica.setFormat(format, clock: .init(physicalMilliseconds: 2_100, nodeID: deviceB))
        let cover = CoverValue(filename: "cover.jpg", contentHash: "def456")
        let coverChange = try replica.setCover(cover, clock: .init(physicalMilliseconds: 2_200, nodeID: deviceB))

        try source.apply(series)
        try source.apply(formatChange)
        try source.apply(coverChange)

        #expect(try source.resolvedBook().series == "Studies")
        #expect(try source.resolvedBook().formats == [format])
        #expect(try source.resolvedBook().cover == cover)
        #expect(try source.resolvedBook().isDeleted == false)
    }

    @Test
    func tagsResolveNewestAddOrRemovePerTag() throws {
        let source = try document()
        let replica = try AutomergeBookDocument.empty(deviceID: deviceB)
        try replica.apply(try source.setTitle("Range", clock: .init(physicalMilliseconds: 1_000, nodeID: deviceA)))

        let addChange = try replica.setTags(["science", "sport"], clock: .init(physicalMilliseconds: 2_000, nodeID: deviceB))
        try source.apply(addChange)
        #expect(try source.resolvedBook().tags == ["science", "sport"])

        let removeChange = try replica.setTags(["science"], clock: .init(physicalMilliseconds: 3_000, nodeID: deviceB))
        try source.apply(removeChange)
        #expect(try source.resolvedBook().tags == ["science"])
    }

    @Test
    func concurrentFormatReplacementKeepsNewestPerKind() throws {
        let source = try document()
        let base = try source.setTitle("Range", clock: .init(physicalMilliseconds: 1_000, nodeID: deviceA))
        let first = try AutomergeBookDocument.empty(deviceID: deviceA)
        let second = try AutomergeBookDocument.empty(deviceID: deviceB)
        try first.apply(base)
        try second.apply(base)

        let older = BookFormatValue(kind: "EPUB", filename: "older.epub", contentHash: "old", size: 1)
        let newer = BookFormatValue(kind: "EPUB", filename: "newer.epub", contentHash: "new", size: 2)
        let olderChange = try first.setFormat(older, clock: .init(physicalMilliseconds: 2_000, nodeID: deviceA))
        let newerChange = try second.setFormat(newer, clock: .init(physicalMilliseconds: 3_000, nodeID: deviceB))

        try first.apply(newerChange)
        try second.apply(olderChange)

        #expect(try first.resolvedBook().formats == [newer])
        #expect(try second.resolvedBook().formats == [newer])
    }

    @Test
    func tombstoneAndRestoreResolveNewest() throws {
        let source = try document()
        let base = try source.setTitle("Range", clock: .init(physicalMilliseconds: 1_000, nodeID: deviceA))

        let delete = try source.setDeleted(true, clock: .init(physicalMilliseconds: 2_000, nodeID: deviceA))
        let replica = try AutomergeBookDocument.empty(deviceID: deviceB)
        try replica.apply(base)
        try replica.apply(delete)
        #expect(try replica.resolvedBook().isDeleted)

        let restore = try replica.setDeleted(false, clock: .init(physicalMilliseconds: 3_000, nodeID: deviceB))
        try source.apply(restore)
        #expect(try !source.resolvedBook().isDeleted)
    }

    @Test
    func identifiersUseIndependentRegistersPerType() throws {
        let source = try document()
        let firstChange = try source.setIdentifiers(
            ["isbn": "1234", "google": "abcd"],
            clock: .init(physicalMilliseconds: 1_000, nodeID: deviceA)
        )
        let change = try source.setIdentifiers(
            ["isbn": "9999"],
            clock: .init(physicalMilliseconds: 2_000, nodeID: deviceA)
        )
        let replica = try AutomergeBookDocument.empty(deviceID: deviceB)
        try replica.apply(firstChange)
        try replica.apply(change)
        #expect(try replica.resolvedBook().identifiers["isbn"] == "9999")
    }

    @Test
    func coverRemovalConvergesAcrossReplicas() throws {
        let source = try document()
        let base = try source.setTitle("Range", clock: .init(physicalMilliseconds: 1_000, nodeID: deviceA))
        let first = try AutomergeBookDocument.empty(deviceID: deviceA)
        let second = try AutomergeBookDocument.empty(deviceID: deviceB)
        try first.apply(base)
        try second.apply(base)

        let coverA = CoverValue(filename: "a.jpg", contentHash: "aa")
        let coverB = CoverValue(filename: "b.jpg", contentHash: "bb")
        let setA = try first.setCover(coverA, clock: .init(physicalMilliseconds: 2_000, nodeID: deviceA))
        let setB = try second.setCover(coverB, clock: .init(physicalMilliseconds: 2_100, nodeID: deviceB))

        try first.apply(setB)
        try second.apply(setA)
        #expect(try first.resolvedBook().cover != nil)
        #expect(try second.resolvedBook().cover != nil)

        let clear = try first.setCover(nil, clock: .init(physicalMilliseconds: 3_000, nodeID: deviceA))
        try second.apply(clear)

        #expect(try first.resolvedBook().cover == nil)
        #expect(try second.resolvedBook().cover == nil)
    }

    @Test
    func formatRemovalConvergesAcrossReplicas() throws {
        let source = try document()
        let base = try source.setTitle("Range", clock: .init(physicalMilliseconds: 1_000, nodeID: deviceA))
        let first = try AutomergeBookDocument.empty(deviceID: deviceA)
        let second = try AutomergeBookDocument.empty(deviceID: deviceB)
        try first.apply(base)
        try second.apply(base)

        let older = BookFormatValue(kind: "EPUB", filename: "older.epub", contentHash: "old", size: 1)
        let newer = BookFormatValue(kind: "EPUB", filename: "newer.epub", contentHash: "new", size: 2)
        let setA = try first.setFormat(older, clock: .init(physicalMilliseconds: 2_000, nodeID: deviceA))
        let setB = try second.setFormat(newer, clock: .init(physicalMilliseconds: 2_100, nodeID: deviceB))

        try first.apply(setB)
        try second.apply(setA)
        #expect(try first.resolvedBook().formats.count == 1)
        #expect(try second.resolvedBook().formats.count == 1)

        let remove = try first.removeFormat(kind: "EPUB", clock: .init(physicalMilliseconds: 3_000, nodeID: deviceA))
        try second.apply(remove)

        #expect(try first.resolvedBook().formats.isEmpty)
        #expect(try second.resolvedBook().formats.isEmpty)
    }

    @Test
    func identifierRemovalConvergesAcrossReplicas() throws {
        let source = try document()
        let base = try source.setTitle("Range", clock: .init(physicalMilliseconds: 1_000, nodeID: deviceA))
        let first = try AutomergeBookDocument.empty(deviceID: deviceA)
        let second = try AutomergeBookDocument.empty(deviceID: deviceB)
        try first.apply(base)
        try second.apply(base)

        let setA = try first.setIdentifiers(
            ["isbn": "1", "google": "g"],
            clock: .init(physicalMilliseconds: 2_000, nodeID: deviceA)
        )
        let setB = try second.setIdentifiers(
            ["isbn": "2"],
            clock: .init(physicalMilliseconds: 2_100, nodeID: deviceB)
        )

        try first.apply(setB)
        try second.apply(setA)
        // Swift dictionaries encode as Automerge lists, so the concurrent-set
        // winner for a shared type is not guaranteed to be the newest clock
        // value across processes. What is guaranteed — and what this test
        // verifies — is that both replicas converge, and that google (touched
        // only by device A) survives.
        let mergedA = try first.resolvedBook().identifiers
        let mergedB = try second.resolvedBook().identifiers
        #expect(mergedA == mergedB)
        #expect(mergedA["google"] == "g")
        #expect(mergedA["isbn"] != nil)

        // Device A clears only the isbn type; the removal loop deletes the
        // whole isbn key, so the clear converges on both replicas while
        // google survives.
        let clear = try first.setIdentifiers(
            ["google": "g"],
            clock: .init(physicalMilliseconds: 3_000, nodeID: deviceA)
        )
        try second.apply(clear)

        #expect(try first.resolvedBook().identifiers["isbn"] == nil)
        #expect(try second.resolvedBook().identifiers["isbn"] == nil)
        #expect(try first.resolvedBook().identifiers["google"] == "g")
        #expect(try second.resolvedBook().identifiers["google"] == "g")
    }
}
