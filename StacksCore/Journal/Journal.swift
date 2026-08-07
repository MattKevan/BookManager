import Foundation

/// The append-only operation journal for one library. The journal is
/// authoritative: `snapshot.json` + the journal tail reconstruct the full
/// state, and `LocalCatalog` is only a disposable index over it.
///
/// Crash-safety: appends go to the current segment file via a FileHandle; a
/// torn tail line (crash mid-append) is dropped on read. Snapshots are
/// written atomically (temp + rename). Command ids dedupe replays.
public actor Journal {
    private let layout: LibraryLayout
    private var segment: (url: URL, handle: FileHandle)?
    private var linesInSegment = 0
    private var appliedIDs: Set<UUID> = []
    private var lastSeq: Int64 = 0

    private static let linesPerSegment = 1000

    /// Compact, deterministic codecs — the journal is line-per-record, so the
    /// record JSON must not contain newlines (`JSONEncoder.bookManager` is
    /// pretty-printed and would shred the line format).
    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public init(layout: LibraryLayout) {
        self.layout = layout
    }

    /// Opens the journal: loads the last segment (dropping a torn tail line),
    /// rebuilds the recent-id set, and computes `lastSeq`. Idempotent.
    public func open() throws {
        try FileManager.default.createDirectory(at: layout.journalRoot, withIntermediateDirectories: true)
        let segments = try segmentURLs()
        guard let tail = segments.last else { return }
        let records = try Self.readRecords(from: tail)
        lastSeq = records.last?.seq ?? 0
        for record in records.suffix(1024) {
            appliedIDs.insert(record.id)
        }
        linesInSegment = records.count
        segment = (tail, try FileHandle(forWritingTo: tail))
        try segment?.handle.seekToEnd()
    }

    /// Appends one command, assigning the next `seq`. Returns nil when `id`
    /// was already applied (idempotent replay).
    @discardableResult
    public func append(op: JournalCommand.Op, id: UUID = UUID()) throws -> JournalCommand? {
        guard !appliedIDs.contains(id) else { return nil }
        lastSeq += 1
        let command = JournalCommand(id: id, seq: lastSeq, ts: .now, op: op)
        if segment == nil || linesInSegment >= Self.linesPerSegment {
            try rollSegment()
        }
        let line = try Self.encoder.encode(command) + Data("\n".utf8)
        try segment!.handle.write(contentsOf: line)
        appliedIDs.insert(id)
        linesInSegment += 1
        return command
    }

    /// Every record with `seq > after`, in order — the sync cursor surface.
    public func records(after seq: Int64) throws -> [JournalCommand] {
        var records: [JournalCommand] = []
        for segment in try segmentURLs() {
            records.append(contentsOf: try Self.readRecords(from: segment))
        }
        return records.filter { $0.seq > seq }
    }

    /// The ids applied so far — the server-side dedupe set for replays.
    public var appliedCommandIDs: Set<UUID> { appliedIDs }
    /// The highest assigned sequence number.
    public var currentSeq: Int64 { lastSeq }

    // MARK: - Snapshot

    public func writeSnapshot(_ snapshot: JournalSnapshot) throws {
        let data = try Self.encoder.encode(snapshot)
        try data.write(to: layout.snapshotURL, options: .atomic)
    }

    public func readSnapshot() throws -> JournalSnapshot? {
        guard FileManager.default.fileExists(atPath: layout.snapshotURL.path) else { return nil }
        guard let data = try? Data(contentsOf: layout.snapshotURL) else { return nil }
        return try? Self.decoder.decode(JournalSnapshot.self, from: data)
    }

    // MARK: - Private

    private func segmentURLs() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: layout.journalRoot.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: layout.journalRoot, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func rollSegment() throws {
        try? segment?.handle.close()
        let name = String(format: "%010d.jsonl", lastSeq)
        let url = layout.journalRoot.appending(path: name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        segment = (url, try FileHandle(forWritingTo: url))
        linesInSegment = 0
    }

    private static func readRecords(from url: URL) throws -> [JournalCommand] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        var records: [JournalCommand] = []
        for line in data.split(separator: 0x0A) {
            // A line that does not decode (torn tail after a crash) is dropped.
            guard let record = try? Self.decoder.decode(
                JournalCommand.self, from: Data(line)
            ) else {
                continue
            }
            records.append(record)
        }
        return records
    }
}
