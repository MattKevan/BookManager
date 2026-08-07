import Foundation

#if !canImport(Network)
// macOS-only content lives above; this file only exists on Linux.

/// Advertises a library over mDNS/DNS-SD on Linux via `avahi-publish-service`
/// (the standard Avahi CLI, `avahi-utils` package). Publishes the same
/// `_stacks._tcp` service with the same TXT records as the macOS
/// Network.framework advertiser, so clients (including the macOS app's
/// Shared sidebar, which browses `_stacks._tcp`) discover Linux servers
/// exactly like Mac ones.
///
/// Requires `avahi-daemon` running and `avahi-utils` installed. When either
/// is missing, `start()` degrades silently — the server still works, clients
/// just reach it by host:port.
final class AvahiAdvertiser: LibraryAdvertiser {
    private let displayName: String
    private let libraryID: UUID
    private let port: Int
    private var process: Process?

    init(displayName: String, libraryID: UUID, port: Int) {
        self.displayName = displayName
        self.libraryID = libraryID
        self.port = port
    }

    func start() {
        guard process == nil else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/avahi-publish-service")
        process.arguments = [
            "-s", displayName,
            "_stacks._tcp",
            String(port),
            "api=/api",
            "id=\(libraryID.uuidString)",
            "v=1",
            "path=/opds",
            "name=\(displayName)",
        ]
        // avahi-publish-service blocks until terminated; the server owns the
        // process for the service's lifetime.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            self.process = process
        } catch {
            // avahi-utils missing or avahi-daemon not running: advertiseBonjour
            // silently degrades to host:port access.
            self.process = nil
        }
    }

    func stop() {
        process?.terminate()
        process = nil
    }
}
#endif
