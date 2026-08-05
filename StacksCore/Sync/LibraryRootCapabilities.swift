import Darwin
import Foundation

/// What kind of synchronized filesystem a library root sits on. Cloud-synced
/// folders (iCloud Drive, Dropbox, OneDrive) can hold placeholder files whose
/// content is not local until downloaded; network mounts (SMB/NFS) have
/// unreliable change events. Reads must `ensureDownloaded` first.
public struct LibraryRootCapabilities: Sendable, Equatable {
    public let isNetworkMount: Bool
    public let isUbiquitous: Bool
    public let isICloudDrive: Bool

    public init(isNetworkMount: Bool, isUbiquitous: Bool, isICloudDrive: Bool) {
        self.isNetworkMount = isNetworkMount
        self.isUbiquitous = isUbiquitous
        self.isICloudDrive = isICloudDrive
    }

    public static func probe(_ root: URL) -> LibraryRootCapabilities {
        var isNetwork = false
        var stat = statfs()
        if statfs(root.path, &stat) == 0 {
            isNetwork = (stat.f_flags & UInt32(MNT_LOCAL)) == 0
        }
        let path = root.path
        let iCloud = path.contains("/Mobile Documents/com~apple~CloudDocs")
        let ubiquitous = path.contains("/Mobile Documents/")
            || path.contains("/Library/CloudStorage/")
        return LibraryRootCapabilities(
            isNetworkMount: isNetwork,
            isUbiquitous: ubiquitous,
            isICloudDrive: iCloud
        )
    }

    /// Ensures a file's content is local before reading (placeholders on
    /// iCloud Drive / Dropbox online-only folders). No-op for local files.
    public static func ensureDownloaded(_ url: URL) async {
        let resourceKeys: [URLResourceKey] = [
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
        ]
        guard let values = try? url.resourceValues(forKeys: Set(resourceKeys)),
              values.isUbiquitousItem == true,
              values.ubiquitousItemDownloadingStatus != .current else {
            return
        }
        do {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
        } catch {
            return // A failed download attempt must not crash reads downstream.
        }
        // Wait for the download to land (bounded by the caller's patience).
        while await !Self.isDownloaded(url) {
            try? await Task.sleep(for: .milliseconds(100))
            if Task.isCancelled { return }
        }
    }

    private static func isDownloaded(_ url: URL) async -> Bool {
        let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            .ubiquitousItemDownloadingStatus
        return status == .current
    }
}
