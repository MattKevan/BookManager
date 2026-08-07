import Foundation
import Observation
import StacksCore

/// Owns the in-process `LibraryServer` + Bonjour advertising driven by the
/// Settings → Sharing pane. The app is one writer among many: when sharing is
/// on, the app's local edits and the server's journal stay in sync because
/// the app routes its edits through the same repository the server opens —
/// the server is the ordering authority, and the app is a privileged client
/// on the same journal.
@MainActor
@Observable
final class SharingService {
    private(set) var isSharing = false
    private(set) var lastError: String?
    private var server: LibraryServer?

    /// The port the server binds. Fixed at 8080 for v1 (the CLI default);
    /// a picker is a follow-up.
    private let port = 8080

    /// Starts sharing the given (home) library. Idempotent while already
    /// sharing. Serves the repository the app already has open: one journal,
    /// one writer — local edits flow into the served sync stream and client
    /// commands serialize through the same journal.
    func start(library: LibraryConnection, advertiseBonjour: Bool, username: String?, password: String?) async {
        guard !isSharing else { return }
        let server = await LibraryServer(repository: library.coreRepository, configuration: .init(
            port: port,
            libraryPath: library.coreRepository.root.path,
            indexesDirectory: nil,
            username: username,
            password: password,
            advertiseBonjour: advertiseBonjour,
            displayName: library.name
        ))
        do {
            try await server.start()
            self.server = server
            isSharing = true
            lastError = nil
        } catch {
            lastError = "Couldn't start sharing: \(error.localizedDescription)"
        }
    }

    /// Stops sharing; safe to call while not sharing.
    func stop() async {
        await server?.stop()
        server = nil
        isSharing = false
    }

    /// The LAN address clients connect to, e.g. `http://192.168.1.20:8080`.
    var addressString: String {
        guard let name = Host.current().localizedName else { return "http://localhost:\(port)" }
        // localizedName can contain spaces or non-hostname chars; keep the
        // copy button honest by resolving the first IPv4 address instead.
        var hint = "localhost"
        var addr: UnsafeMutablePointer<addrinfo>?
        if getaddrinfo(name, nil, nil, &addr) == 0, let addr {
            var pointer: UnsafeMutablePointer<addrinfo>? = addr
            while let current = pointer {
                if current.pointee.ai_family == AF_INET {
                    var address = current.pointee.ai_addr
                    var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if let address {
                        if getnameinfo(address, socklen_t(current.pointee.ai_addrlen),
                                       &hostBuffer, socklen_t(hostBuffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                            hint = String(cString: hostBuffer)
                            break
                        }
                    }
                }
                pointer = current.pointee.ai_next
            }
            freeaddrinfo(addr)
        }
        return "http://\(hint):\(port)"
    }
}
