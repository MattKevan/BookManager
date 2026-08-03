import Foundation
import Network
import os

/// A wireless adb endpoint discovered via mDNS/Bonjour.
public struct ADBService: Sendable, Hashable {
    public enum Kind: Sendable { case connect, pairing }
    public var name: String          // Bonjour instance name (often "adb-<serial>-<random>")
    public var host: String          // resolved host or IP
    public var port: Int
    public var kind: Kind
    /// adb connect/pair target.
    public var endpoint: String { "\(host):\(port)" }

    public init(name: String, host: String, port: Int, kind: Kind) {
        self.name = name
        self.host = host
        self.port = port
        self.kind = kind
    }
}

/// Browses the local network for wireless-debugging Android devices.
///
/// Android 11+ advertises three mDNS service types; we watch two:
///   • `_adb-tls-connect._tcp` — published once a device's TLS server is active (paired,
///     ready to `adb connect`). These we auto-connect.
///   • `_adb-tls-pairing._tcp` — published while the "Pair device with pairing code"
///     screen is open. These we surface so the pairing sheet can pre-fill the host:port.
/// macOS always runs the Bonjour daemon, so `NWBrowser` works with no extra setup.
public final class ADBDiscovery: @unchecked Sendable {
    static let log = Logger(subsystem: "com.Ricky.Android-File-Transfer", category: "ADBDiscovery")

    private var browsers: [NWBrowser] = []
    private let onChange: @Sendable ([ADBService]) -> Void
    private let lock = NSLock()
    private var services: [String: ADBService] = [:]   // keyed by "kind/name"

    public init(onChange: @escaping @Sendable ([ADBService]) -> Void) {
        self.onChange = onChange
    }

    public func start() {
        startBrowser(type: "_adb-tls-connect._tcp", kind: .connect)
        startBrowser(type: "_adb-tls-pairing._tcp", kind: .pairing)
    }

    public func stop() {
        browsers.forEach { $0.cancel() }
        browsers.removeAll()
    }

    private func startBrowser(type: String, kind: ADBService.Kind) {
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: type, domain: nil), using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.handle(results, kind: kind)
        }
        browser.stateUpdateHandler = { state in
            if case .failed(let err) = state {
                Self.log.error("Browser(\(type, privacy: .public)) failed: \(err.localizedDescription, privacy: .public)")
            }
        }
        browser.start(queue: .global(qos: .utility))
        browsers.append(browser)
    }

    private func handle(_ results: Set<NWBrowser.Result>, kind: ADBService.Kind) {
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint else { continue }
            resolve(result, name: name, kind: kind)
        }
        // Drop entries of this kind that are no longer advertised.
        let liveKeys = Set(results.compactMap { r -> String? in
            if case let .service(name, _, _, _) = r.endpoint { return Self.key(kind, name) }
            return nil
        })
        lock.lock()
        services = services.filter { entry in
            // keep other-kind entries; for this kind, keep only live ones
            let isThisKind = entry.value.kind == kind
            return !isThisKind || liveKeys.contains(entry.key)
        }
        let snapshot = Array(services.values)
        lock.unlock()
        onChange(snapshot)
    }

    /// Resolve a browse result to an IP:port using a short-lived NWConnection.
    private func resolve(_ result: NWBrowser.Result, name: String, kind: ADBService.Kind) {
        let conn = NWConnection(to: result.endpoint, using: .tcp)
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let remote = conn.currentPath?.remoteEndpoint,
                   case let .hostPort(host, port) = remote {
                    let svc = ADBService(name: name, host: Self.hostString(host),
                                         port: Int(port.rawValue), kind: kind)
                    self.lock.lock(); self.services[Self.key(kind, name)] = svc
                    let snap = Array(self.services.values); self.lock.unlock()
                    self.onChange(snap)
                }
                conn.cancel()
            case .failed, .cancelled:
                conn.cancel()
            default:
                break
            }
        }
        conn.start(queue: .global(qos: .utility))
    }

    private static func key(_ kind: ADBService.Kind, _ name: String) -> String {
        "\(kind == .connect ? "c" : "p")/\(name)"
    }

    private static func hostString(_ host: NWEndpoint.Host) -> String {
        switch host {
        case .ipv4(let a): return "\(a)".components(separatedBy: "%").first ?? "\(a)"
        case .ipv6(let a): return "\(a)".components(separatedBy: "%").first ?? "\(a)"
        case .name(let n, _): return n
        @unknown default: return "\(host)"
        }
    }
}
