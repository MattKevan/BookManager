import Foundation

/// One-time migration: the app's Application Support directory was named
/// "Book Manager"; rename it to "Stacks" so SyncState/outbox state (pending
/// offline edits, applied fingerprints) survives the rename. Runs before any
/// sync root is created.
enum StacksSupportMigrator {
    static func migrateOnce() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let base else { return }
        let legacy = base.appending(path: "Book Manager", directoryHint: .isDirectory)
        let current = base.appending(path: "Stacks", directoryHint: .isDirectory)
        guard fm.fileExists(atPath: legacy.path), !fm.fileExists(atPath: current.path) else { return }
        try? fm.moveItem(at: legacy, to: current)
    }
}
