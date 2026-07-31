import Automerge
import Foundation

public final class AutomergeBookDocument: @unchecked Sendable {
    private let document: Document
    private let deviceID: UUID

    private init(document: Document, deviceID: UUID) {
        self.document = document
        self.deviceID = deviceID
        self.document.actor = ActorId(uuid: deviceID)
    }

    public static func empty(deviceID: UUID) throws -> AutomergeBookDocument {
        AutomergeBookDocument(document: Document(), deviceID: deviceID)
    }

    public static func new(bookID: UUID, deviceID: UUID) throws -> AutomergeBookDocument {
        let result = AutomergeBookDocument(document: Document(), deviceID: deviceID)
        var schema = BookDocumentSchema(bookID: bookID)
        schema.deletions[deviceID.uuidString] = VersionedValue(
            value: false,
            clock: HybridLogicalClock(nodeID: deviceID)
        )
        try result.encode(schema)
        return result
    }

    public convenience init(snapshot: Data, deviceID: UUID) throws {
        try self.init(document: Document(snapshot), deviceID: deviceID)
    }

    public func setTitle(_ title: String, clock: HybridLogicalClock) throws -> Data {
        var schema = try decode()
        schema.titles[deviceID.uuidString] = VersionedValue(value: title, clock: clock)
        return try commit(schema, message: "set-title", timestamp: clock.date)
    }

    public func setAuthors(_ authors: [String], clock: HybridLogicalClock) throws -> Data {
        var schema = try decode()
        schema.authors[deviceID.uuidString] = VersionedValue(value: authors, clock: clock)
        return try commit(schema, message: "set-authors", timestamp: clock.date)
    }

    public func apply(_ encodedChanges: Data) throws {
        try document.applyEncodedChanges(encoded: encodedChanges)
        _ = document.encodeNewChanges()
    }

    public func snapshot() -> Data {
        document.save()
    }

    public func heads() -> Set<ChangeHash> {
        document.heads()
    }

    public func resolvedBook() throws -> ResolvedBook {
        let schema = try decode()
        guard let id = schema.bookID else {
            throw BookDocumentError.missingBookID
        }

        let title = newest(schema.titles)?.value ?? "Unknown"
        let authors = newest(schema.authors)?.value ?? ["Unknown"]
        let deletion = newest(schema.deletions)
        let clocks = [
            newest(schema.titles)?.clock,
            newest(schema.authors)?.clock,
            deletion?.clock
        ].compactMap { $0 }

        guard let modifiedClock = clocks.max() else {
            throw BookDocumentError.missingClock
        }

        return ResolvedBook(
            id: id,
            title: title,
            authors: authors,
            isDeleted: deletion?.value ?? false,
            modifiedClock: modifiedClock
        )
    }

    private func commit(
        _ schema: BookDocumentSchema,
        message: String,
        timestamp: Date
    ) throws -> Data {
        try encode(schema)
        document.commitWith(message: message, timestamp: timestamp)
        return document.encodeNewChanges()
    }

    private func encode(_ schema: BookDocumentSchema) throws {
        try AutomergeEncoder(doc: document).encode(schema)
    }

    private func decode() throws -> BookDocumentSchema {
        try AutomergeDecoder(doc: document).decode(BookDocumentSchema.self)
    }

    private func newest<Value>(
        _ values: [String: VersionedValue<Value>]
    ) -> VersionedValue<Value>? {
        values.values.max { $0.clock < $1.clock }
    }
}

public enum BookDocumentError: Error, Equatable {
    case missingBookID
    case missingClock
}

private extension HybridLogicalClock {
    var date: Date {
        Date(timeIntervalSince1970: TimeInterval(physicalMilliseconds) / 1_000)
    }
}
