import Foundation

/// Applies a metadata edit to a book snapshot without touching the
/// filesystem — the offline-edit path (and the two-Mac test harness). The
/// returned changes stage into the outbox; the resolved book feeds the local
/// catalog upsert so offline edits stay visible.
public enum OfflineBookEdit {
    public static func apply(
        _ edit: BookEdit,
        to snapshot: Data,
        deviceID: UUID
    ) throws -> (changes: [Data], resolved: ResolvedBook) {
        let document = try AutomergeBookDocument(snapshot: snapshot, deviceID: deviceID)
        let changes = try document.apply(edit, clock: HybridLogicalClock(nodeID: deviceID), date: .now)
        return (changes, try document.resolvedBook())
    }
}
