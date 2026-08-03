import Foundation

/// QR-code wireless pairing.
///
/// Mechanism (the Mac shows a QR, the phone scans it):
///  1. We generate a payload string `WIFI:T:ADB;S:<service>;P:<password>;;` where we pick
///     both the mDNS service-instance name (`S:`) and the shared password (`P:`).
///  2. The phone's "Pair device with QR code" scanner sees `T:ADB`, starts a pairing
///     server advertised as `_adb-tls-pairing._tcp` with instance name == our `<service>`.
///  3. We watch mDNS for a pairing service whose instance name matches `<service>`, then
///     run `adb pair <host:port> <password>` — fully automatic, no code typing.
///
/// Because we choose `<service>` and `<password>`, we know exactly which advertisement is
/// ours and how to authenticate it.
public enum ADBQRPairing {

    /// A freshly generated QR session: the payload to render, plus the service name and
    /// password we'll match/use when the phone responds.
    public struct Session: Sendable {
        public let serviceName: String   // mDNS instance name we requested via S:
        public let password: String      // shared secret we requested via P:
        public var payload: String { "WIFI:T:ADB;S:\(serviceName);P:\(password);;" }
    }

    /// Create a new QR session with a random service name and password.
    public static func makeSession() -> Session {
        // Service name: must be unique on the network; keep it short and adb-friendly.
        let suffix = String((0..<6).map { _ in "ABCDEFGHJKLMNPQRSTUVWXYZ23456789".randomElement()! })
        // Password: adb's QR flow uses up to a 10-digit-ish secret; a random alphanumeric
        // string of decent length is accepted as the pairing password.
        let password = String((0..<12).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! })
        return Session(serviceName: "AFT-\(suffix)", password: password)
    }

    /// Given the live mDNS services, find the pairing endpoint whose instance name matches
    /// this session, and attempt `adb pair`. Returns the paired host:port on success, or
    /// nil if our service hasn't appeared yet / pairing failed.
    public static func tryPair(session: Session, services: [ADBService], client: ADBClient) async -> String? {
        guard let match = services.first(where: {
            $0.kind == .pairing && $0.name == session.serviceName
        }) else { return nil }

        do {
            let ok = try await ADBPairing.pair(client: client, hostPort: match.endpoint, code: session.password)
            return ok ? match.endpoint : nil
        } catch {
            return nil
        }
    }
}
