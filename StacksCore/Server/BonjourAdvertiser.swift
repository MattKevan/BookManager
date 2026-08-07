import Foundation
import Network

/// Advertises a library on the LAN via Bonjour (`_bookmanager._tcp`) with
/// TXT records: display name, library id, protocol version, and the OPDS +
/// sync API paths (mirrors Calibre's `path=/opds` TXT convention).
///
/// Uses `NetService` (macOS): it announces a port WITHOUT binding a socket,
/// so it can sit alongside the Hummingbird listener on the same port. Linux
/// gets an Avahi seam in the port plan.
public final class BonjourAdvertiser: @unchecked Sendable {
    private let service: NetService

    public init(displayName: String, libraryID: UUID, port: Int) {
        let service = NetService(
            domain: "local.",
            type: "_bookmanager._tcp.",
            name: displayName,
            port: Int32(port)
        )
        service.setTXTRecord(NetService.data(fromTXTRecord: Self.txtRecord(
            name: displayName, libraryID: libraryID
        )))
        self.service = service
    }

    public func start() {
        service.publish()
    }

    public func stop() {
        service.stop()
    }

    /// The advertised TXT record — name, library id, protocol version, and
    /// the OPDS + sync API paths.
    public static func txtRecord(name: String, libraryID: UUID) -> [String: Data] {
        [
            "name": Data(name.utf8),
            "id": Data(libraryID.uuidString.utf8),
            "v": Data("1".utf8),
            "path": Data("/opds".utf8),
            "api": Data("/api".utf8),
        ]
    }
}
