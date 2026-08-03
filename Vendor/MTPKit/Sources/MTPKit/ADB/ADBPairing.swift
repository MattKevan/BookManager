import Foundation

/// One-time wireless pairing via a pairing code (Android 11+:
/// Developer options → Wireless debugging → Pair device with pairing code).
public enum ADBPairing {

    /// Run `adb pair <host:port> <code>`. The pairing host:port is shown on the phone
    /// under "Pair device with pairing code" — note it differs from the connect port.
    /// Returns the parsed result. Throws on launch failure.
    public static func pair(client: ADBClient, hostPort: String, code: String) async throws -> Bool {
        // adb prompts for the code on stdin in some versions, but also accepts it as a
        // trailing argument. The trailing-arg form is the reliable one for scripting.
        let result = try await client.run(["pair", hostPort, code], timeout: 30)
        // Success line: "Successfully paired to <host:port> [guid ...]"
        return result.ok && result.stdout.localizedCaseInsensitiveContains("successfully paired")
    }

    /// Run `adb connect <host:port>` after pairing (or for an already-paired device).
    /// Returns the connected serial (host:port) on success.
    public static func connect(client: ADBClient, hostPort: String) async throws -> String? {
        let result = try await client.run(["connect", hostPort], timeout: 20)
        // Success: "connected to 192.168.1.23:5555" or "already connected to ..."
        let text = result.stdout.lowercased()
        if text.contains("connected to") {
            return hostPort
        }
        return nil
    }
}
