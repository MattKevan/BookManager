import CryptoKit
import Foundation

public struct IngestReport: Sendable, Equatable {
    public var appliedChangeCount: Int = 0
    public var quarantined: [URL] = []
    public var booksApplied: Int = 0

    public init() {}
}

/// Ingests unseen change files from the library into the local catalog,
/// drains the durable outbox, and quarantines corrupt changes. Ingest is
/// fingerprint-diffed and idempotent; the change store stays authoritative.
public actor SyncEngine {
    private let layout: LibraryLayout
    private let catalog: LocalCatalog
    private let state: SyncState
    private let deviceID: UUID

    public init(
        layout: LibraryLayout,
        catalog: LocalCatalog,
        state: SyncState,
        deviceID: UUID
    ) {
        self.layout = layout
        self.catalog = catalog
        self.state = state
        self.deviceID = deviceID
    }

    /// Applies every change file this Mac has not applied yet, per book, with
    /// the dependency-ordered retry loop (same algorithm as
    /// `LibraryRepository.rebuildCatalog`). Changes that cannot decode are
    /// quarantined (moved out of the change store); valid changes whose
    /// dependencies have not synced yet are left in place and retried on a
    /// later ingest.
    public func ingest() async throws -> IngestReport {
        var report = IngestReport()
        let store = ChangeStore(layout: layout)
        let applied = try state.appliedFingerprints()
        var newlyApplied = Set<String>()
        let bookIDs = try await store.bookIDs()
        var built: [IndexedBook] = []

        for bookID in bookIDs {
            let files = try await store.bookChangeFiles(bookID: bookID)
            // Seed the document from the catalog's stored snapshot so changes
            // applied by earlier ingests stay part of it. When the catalog has
            // no snapshot (cleared/never upserted), fall back to a full rebuild
            // from every change file — the fingerprint filter alone would drop
            // earlier contributions.
            let snapshotData = try? await catalog.snapshot(bookID: bookID)
            let seededDocument = snapshotData.flatMap { try? AutomergeBookDocument(snapshot: $0, deviceID: deviceID) }
            let document = try seededDocument ?? AutomergeBookDocument.empty(deviceID: deviceID)
            // With a seeded document, skip already-applied changes; without one,
            // every change file must be (re)applied.
            let filterApplied = seededDocument != nil
            var pending = files.filter { url in
                guard filterApplied, let data = try? Data(contentsOf: url) else { return true }
                let fingerprint = Self.fingerprint(data)
                return !applied.contains(fingerprint) && !newlyApplied.contains(fingerprint)
            }
            if pending.isEmpty { continue }

            var appliedAny = false
            var madeProgress = true
            while !pending.isEmpty && madeProgress {
                madeProgress = false
                var next: [URL] = []
                for url in pending {
                    do {
                        let data = try Data(contentsOf: url)
                        try document.apply(data)
                        newlyApplied.insert(Self.fingerprint(data))
                        madeProgress = true
                        appliedAny = true
                    } catch {
                        next.append(url)
                    }
                }
                pending = next
            }

            // Only files whose name digest does not match their content are
            // corrupt (the change store names every file
            // `<clock>-<SHA256(content)>.amchange`). Quarantine those. A valid
            // change waiting on a not-yet-synced dependency stays in the store
            // and applies on a later ingest — quarantining it would lose the edit.
            for url in pending where ChangeStore.hasCorruptDigest(url) {
                report.quarantined.append(try await store.quarantine(url))
            }

            // Upsert the merged state only when something applied; a book with
            // only stuck-authentic changes keeps its previous catalog entry.
            guard appliedAny else { continue }
            let resolved = try document.resolvedBook()
            let path = CanonicalPathBuilder.relativeDirectory(
                bookID: bookID, title: resolved.title, authors: resolved.authors
            )
            built.append(try IndexedBookFactory.make(
                resolved: resolved,
                bookID: bookID,
                path: path,
                snapshot: document.snapshot()
            ))
            report.booksApplied += 1
        }

        if !built.isEmpty {
            try await catalog.upsertBatch(built)
        }

        report.appliedChangeCount = newlyApplied.count
        try state.recordApplied(newlyApplied)
        return report
    }

    /// Moves every outbox change file into the library change store. The
    /// outbox mirrors the library's relative layout
    /// (`<bookID>/<deviceID>/<clock>-<digest>.amchange`), so draining is a
    /// relative-path move — no clock parsing or renaming.
    public func drainOutbox() async throws -> Int {
        var moved = 0
        // The outbox mirrors the library change store's layout
        // (`<bookID>/<deviceID>/<clock>-<digest>.amchange` under the outbox
        // root), so draining is a relative-path move. Paths are symlink-resolved
        // (the enumerator returns `/private/var/…` where the root URL is
        // `/var/…`) and the shape is validated component-wise.
        let base = state.outbox.outboxRoot.resolvingSymlinksInPath().pathComponents
        for url in try state.outbox.pendingFiles() {
            let parts = url.resolvingSymlinksInPath().pathComponents
            guard parts.count == base.count + 3 else { continue }
            let relative = parts[base.count...].joined(separator: "/")
            let destination = layout.bookChangesRoot.appending(path: relative)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: destination.path) {
                // A destination with this exact clock+digest name must hold this
                // content. A partial file can land here when a cross-volume
                // moveItem (copy-then-delete) crashed between the copy and the
                // delete — treating it as "already drained" and dropping the
                // outbox copy would let ingest quarantine the partial and lose
                // the edit forever. Keep the outbox copy; the next pass retries
                // after ingest quarantines the partial.
                guard Self.contentsMatch(url, destination) else { continue }
                try state.outbox.remove(url)
            } else {
                // Copy to a temp sibling and rename so the digest-named path only
                // ever holds complete content: on a different volume, moveItem is
                // copy-then-delete and a crash can leave a partial file AT the
                // digest-named path, which the exists-branch above can then not
                // distinguish from a real drain.
                let temp = destination
                    .deletingLastPathComponent()
                    .appending(path: ".tmp-\(destination.lastPathComponent)")
                try? FileManager.default.removeItem(at: temp)
                try FileManager.default.copyItem(at: url, to: temp)
                try FileManager.default.moveItem(at: temp, to: destination)
                try state.outbox.remove(url)
            }
            moved += 1
        }
        return moved
    }

    /// True when two files hold identical bytes.
    private static func contentsMatch(_ a: URL, _ b: URL) -> Bool {
        guard let dataA = try? Data(contentsOf: a),
              let dataB = try? Data(contentsOf: b) else {
            return false
        }
        return dataA == dataB
    }

    /// Clears the applied-fingerprint record and re-ingests everything (the
    /// correctness backstop for missed events and drifted state).
    public func fullRescan() async throws {
        try state.reset()
        _ = try await ingest()
    }

    // MARK: - Helpers

    private static func fingerprint(_ change: Data) -> String {
        String(sha256Hex(change).prefix(32))
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
