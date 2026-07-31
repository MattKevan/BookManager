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
        var schema = BookDocumentSchema(schemaVersion: 2, bookID: bookID)
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

    public func setSeries(_ value: String, clock: HybridLogicalClock) throws -> Data {
        var schema = try decode()
        schema.series[deviceID.uuidString] = VersionedValue(value: value, clock: clock)
        return try commit(schema, message: "set-series", timestamp: clock.date)
    }

    public func setSeriesIndex(_ value: Double, clock: HybridLogicalClock) throws -> Data {
        var schema = try decode()
        schema.seriesIndexes[deviceID.uuidString] = VersionedValue(value: value, clock: clock)
        return try commit(schema, message: "set-series-index", timestamp: clock.date)
    }

    public func setTags(_ tags: [String], clock: HybridLogicalClock) throws -> Data {
        var schema = try decode()
        var resolved = resolvedTagNames(schema.tags)
        for tag in tags where !resolved.contains(tag) {
            schema.tags[tag, default: [:]][deviceID.uuidString] = VersionedValue(value: true, clock: clock)
        }
        for tag in resolved where !tags.contains(tag) {
            schema.tags[tag, default: [:]][deviceID.uuidString] = VersionedValue(value: false, clock: clock)
        }
        return try commit(schema, message: "set-tags", timestamp: clock.date)
    }

    public func setRating(_ value: Int, clock: HybridLogicalClock) throws -> Data {
        var schema = try decode()
        schema.ratings[deviceID.uuidString] = VersionedValue(value: value, clock: clock)
        return try commit(schema, message: "set-rating", timestamp: clock.date)
    }

    public func setPublisher(_ value: String, clock: HybridLogicalClock) throws -> Data {
        var schema = try decode()
        schema.publishers[deviceID.uuidString] = VersionedValue(value: value, clock: clock)
        return try commit(schema, message: "set-publisher", timestamp: clock.date)
    }

    public func setPublicationDate(_ value: Date, clock: HybridLogicalClock) throws -> Data {
        var schema = try decode()
        schema.publicationDates[deviceID.uuidString] = VersionedValue(value: value, clock: clock)
        return try commit(schema, message: "set-publication-date", timestamp: clock.date)
    }

    public func setAddedDate(_ value: Date, clock: HybridLogicalClock) throws -> Data {
        var schema = try decode()
        schema.addedDates[deviceID.uuidString] = VersionedValue(value: value, clock: clock)
        return try commit(schema, message: "set-added-date", timestamp: clock.date)
    }

    public func setLanguages(_ value: [String], clock: HybridLogicalClock) throws -> Data {
        var schema = try decode()
        schema.languages[deviceID.uuidString] = VersionedValue(value: value, clock: clock)
        return try commit(schema, message: "set-languages", timestamp: clock.date)
    }

    public func setIdentifiers(_ value: [String: String], clock: HybridLogicalClock) throws -> Data {
        var schema = try decode()
        let existing = resolvedIdentifiers(schema.identifiers)
        for type in existing.keys where value[type] == nil {
            schema.identifiers.removeValue(forKey: type)
        }
        for (type, identifier) in value {
            schema.identifiers[type, default: [:]][deviceID.uuidString] = VersionedValue(value: identifier, clock: clock)
        }
        return try commit(schema, message: "set-identifiers", timestamp: clock.date)
    }

    public func setComments(_ value: String, clock: HybridLogicalClock) throws -> Data {
        var schema = try decode()
        schema.comments[deviceID.uuidString] = VersionedValue(value: value, clock: clock)
        return try commit(schema, message: "set-comments", timestamp: clock.date)
    }

    public func setFormat(_ value: BookFormatValue, clock: HybridLogicalClock) throws -> Data {
        var schema = try decode()
        schema.formats[value.kind, default: [:]][deviceID.uuidString] = VersionedValue(value: value, clock: clock)
        return try commit(schema, message: "set-format-\(value.kind)", timestamp: clock.date)
    }

    public func removeFormat(kind: String, clock: HybridLogicalClock) throws -> Data {
        var schema = try decode()
        schema.formats.removeValue(forKey: kind)
        return try commit(schema, message: "remove-format-\(kind)", timestamp: clock.date)
    }

    public func setCover(_ value: CoverValue?, clock: HybridLogicalClock) throws -> Data {
        var schema = try decode()
        if let value {
            schema.covers[deviceID.uuidString] = VersionedValue(value: value, clock: clock)
        } else {
            schema.covers.removeValue(forKey: deviceID.uuidString)
        }
        return try commit(schema, message: "set-cover", timestamp: clock.date)
    }

    public func setDeleted(_ deleted: Bool, clock: HybridLogicalClock) throws -> Data {
        var schema = try decode()
        schema.deletions[deviceID.uuidString] = VersionedValue(value: deleted, clock: clock)
        return try commit(schema, message: deleted ? "delete-book" : "restore-book", timestamp: clock.date)
    }

    public func apply(_ edits: BookEdit, clock: HybridLogicalClock, date: Date) throws -> [Data] {
        var changes: [Data] = []
        var current = clock
        if let title = edits.title {
            changes.append(try setTitle(title, clock: current.tick(at: date)))
        }
        if let authors = edits.authors {
            changes.append(try setAuthors(authors, clock: current.tick(at: date)))
        }
        switch edits.series {
        case .keep: break
        case .set(let value): changes.append(try setSeries(value, clock: current.tick(at: date)))
        case .clear: changes.append(try setSeries("", clock: current.tick(at: date)))
        }
        switch edits.seriesIndex {
        case .keep: break
        case .set(let value): changes.append(try setSeriesIndex(value, clock: current.tick(at: date)))
        case .clear: changes.append(try setSeriesIndex(0, clock: current.tick(at: date)))
        }
        if let tags = edits.tags {
            changes.append(try setTags(tags, clock: current.tick(at: date)))
        }
        switch edits.rating {
        case .keep: break
        case .set(let value): changes.append(try setRating(value, clock: current.tick(at: date)))
        case .clear: changes.append(try setRating(0, clock: current.tick(at: date)))
        }
        switch edits.publisher {
        case .keep: break
        case .set(let value): changes.append(try setPublisher(value, clock: current.tick(at: date)))
        case .clear: changes.append(try setPublisher("", clock: current.tick(at: date)))
        }
        switch edits.publicationDate {
        case .keep: break
        case .set(let value): changes.append(try setPublicationDate(value, clock: current.tick(at: date)))
        case .clear: changes.append(try setPublicationDate(Date(timeIntervalSince1970: 0), clock: current.tick(at: date)))
        }
        if let languages = edits.languages {
            changes.append(try setLanguages(languages, clock: current.tick(at: date)))
        }
        if let identifiers = edits.identifiers {
            changes.append(try setIdentifiers(identifiers, clock: current.tick(at: date)))
        }
        switch edits.comments {
        case .keep: break
        case .set(let value): changes.append(try setComments(value, clock: current.tick(at: date)))
        case .clear: changes.append(try setComments("", clock: current.tick(at: date)))
        }
        return changes
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
        let series = newest(schema.series)?.value
        let seriesIndex = newest(schema.seriesIndexes)?.value
        let tags = resolvedTagNames(schema.tags)
        let rating = newest(schema.ratings)?.value
        let publisher = newest(schema.publishers)?.value
        let publicationDate = newest(schema.publicationDates)?.value
        let addedDate = newest(schema.addedDates)?.value
        let languages = newest(schema.languages)?.value ?? []
        let identifiers = resolvedIdentifiers(schema.identifiers)
        let comments = newest(schema.comments)?.value
        let formats = resolvedFormats(schema.formats)
        let cover = newest(schema.covers)?.value
        let deletion = newest(schema.deletions)
        let clocks = [
            newest(schema.titles)?.clock,
            newest(schema.authors)?.clock,
            newest(schema.series)?.clock,
            newest(schema.seriesIndexes)?.clock,
            newest(schema.ratings)?.clock,
            newest(schema.publishers)?.clock,
            newest(schema.publicationDates)?.clock,
            newest(schema.addedDates)?.clock,
            newest(schema.languages)?.clock,
            newest(schema.comments)?.clock,
            newest(schema.covers)?.clock,
            deletion?.clock
        ].compactMap { $0 }
        // Tags and identifiers participate in the modified clock through their own newest entries.
        let tagClocks = schema.tags.values.flatMap { $0.values }.map(\.clock)
        let identifierClocks = schema.identifiers.values.flatMap { $0.values }.map(\.clock)
        let formatClocks = schema.formats.values.flatMap { $0.values }.map(\.clock)

        guard let modifiedClock = (clocks + tagClocks + identifierClocks + formatClocks).max() else {
            throw BookDocumentError.missingClock
        }

        return ResolvedBook(
            id: id,
            title: title,
            authors: authors,
            series: series,
            seriesIndex: seriesIndex,
            tags: tags,
            rating: rating,
            publisher: publisher,
            publicationDate: publicationDate,
            addedDate: addedDate,
            languages: languages,
            identifiers: identifiers,
            comments: comments,
            formats: formats,
            cover: cover,
            isDeleted: deletion?.value ?? false,
            modifiedClock: modifiedClock
        )
    }

    private func resolvedTagNames(_ tags: [String: [String: VersionedValue<Bool>]]) -> [String] {
        tags.compactMap { tag, devices in
            guard let newest = devices.values.max(by: { $0.clock < $1.clock }) else { return nil }
            return newest.value ? tag : nil
        }.sorted()
    }

    private func resolvedIdentifiers(_ identifiers: [String: [String: VersionedValue<String>]]) -> [String: String] {
        identifiers.compactMapValues { devices in
            devices.values.max(by: { $0.clock < $1.clock })?.value
        }
    }

    private func resolvedFormats(_ formats: [String: [String: VersionedValue<BookFormatValue>]]) -> [BookFormatValue] {
        formats.compactMapValues { devices in
            devices.values.max(by: { $0.clock < $1.clock })?.value
        }.values.sorted { $0.kind < $1.kind }
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
