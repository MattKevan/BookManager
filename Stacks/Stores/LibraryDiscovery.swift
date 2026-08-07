import CryptoKit
import Foundation
import Network
import Observation

/// One library discovered on the LAN via Bonjour (`_stacks._tcp`), or typed
/// in manually as host:port.
public struct DiscoveredLibrary: Identifiable, Equatable, Sendable {
    /// The library's manifest id (TXT record for Bonjour discovery). Manual
    /// connections use a stable id derived from the host:port so credentials
    /// and the offline queue survive reconnect.
    public let id: UUID
    /// Display name. Manual connections start as the host and adopt the
    /// server's real name once `/api/identity` answers.
    public var name: String
    public let host: String
    public let port: Int

    public var baseURL: URL {
        URL(string: "http://\(host):\(port)")!
    }

    /// A manual host:port entry (no Bonjour TXT): id is the SHA-256 of the
    /// address, stable across sessions.
    public init(manualHost host: String, port: Int) {
        let digest = SHA256.hash(data: Data("stacks://\(host):\(port)".utf8))
        let bytes = Array(digest.prefix(16))
        self.id = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
        self.name = host
        self.host = host
        self.port = port
    }

    /// Bonjour-discovered values (TXT record carries the manifest id + name).
    public init(id: UUID, name: String, host: String, port: Int) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
    }
}

/// Browses for `_stacks._tcp` services on the LAN and resolves them to
/// `DiscoveredLibrary` values. Drives the sidebar's Shared section.
@MainActor
@Observable
public final class LibraryDiscovery {
    public private(set) var libraries: [DiscoveredLibrary] = []
    /// Non-nil while browsing is active (the privacy-prompt gate surfaced
    /// as `.waiting(.dns(kDNSServiceErr_PolicyDenied))` is reported here).
    public private(set) var browseError: String?

    private var browser: NWBrowser?
    private var resolved: [String: DiscoveredLibrary] = [:]

    public init() {}

    public func start() {
        guard browser == nil else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_stacks._tcp", domain: nil), using: parameters)
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .waiting(let error):
                    self?.browseError = error.localizedDescription
                case .failed(let error):
                    self?.browseError = error.localizedDescription
                    self?.browser = nil
                case .ready, .cancelled, .setup:
                    break
                @unknown default:
                    break
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                self?.update(results: results)
            }
        }
        self.browser = browser
        browser.start(queue: .main)
    }

    public func stop() {
        browser?.cancel()
        browser = nil
        libraries = []
        resolved = [:]
        browseError = nil
    }

    private func update(results: Set<NWBrowser.Result>) {
        var next: [String: DiscoveredLibrary] = [:]
        for result in results {
            switch result.endpoint {
            case .service(name: let name, type: _, domain: _, interface: _):
                next[name] = resolved[name]
            case .hostPort, .unix, .url, .opaque:
                break
            @unknown default:
                break
            }
            // Resolve (async) and merge the result.
            resolve(result)
        }
        // Keep stale entries until their re-resolution completes.
        for (name, library) in resolved where next[name] == nil && results.contains(where: {
            if case .service(name: name, type: _, domain: _, interface: _) = $0.endpoint { return true }
            return false
        }) {
            next[name] = library
        }
        libraries = next.values.sorted { $0.name < $1.name }
    }

    private func resolve(_ result: NWBrowser.Result) {
        guard case .service(name: let name, type: _, domain: _, interface: _) = result.endpoint else {
            return
        }
        let connection = NWConnection(to: result.endpoint, using: .tcp)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                // The connection resolved the service to a concrete
                // host:port; the resolved service endpoint carries the TXT
                // record (library id + display name).
                if let remote = connection.currentPath?.remoteEndpoint,
                   case .hostPort(let host, let port) = remote,
                   let txt = connection.endpoint.txtRecord,
                   let payload = try? TXTRecordDecoder().decode(TXTPayload.self, from: txt),
                   let id = payload.id.flatMap(UUID.init(uuidString:)) {
                    Task { @MainActor in
                        self?.resolved[name] = DiscoveredLibrary(
                            id: id,
                            name: payload.name ?? name,
                            host: host.debugDescription,
                            port: Int(port.rawValue)
                        )
                    }
                }
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: .main)
    }

    /// The `_stacks._tcp` TXT record shape: name, library id, protocol
    /// version, OPDS path, API path.
    private struct TXTPayload: Decodable {
        let name: String?
        let id: String?
        let v: String?
        let path: String?
        let api: String?
    }
}
