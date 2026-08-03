import Testing
import Foundation
@testable import MTPKit

@Suite struct ADBClientSmokeTests {
    // Use the downloaded adb for CI/dev (machine may have no adb in PATH).
    static let devADB = "/tmp/platform-tools/adb"

    @Test func runsVersionAndDevices() async throws {
        guard FileManager.default.isExecutableFile(atPath: Self.devADB) else {
            print("（無 adb 可測，略過）"); return
        }
        let client = ADBClient(adbPath: Self.devADB, serverPort: 5599)!
        let v = try await client.run(["version"], timeout: 15)
        print(">>> adb version ok=\(v.ok)\n\(v.stdout.split(separator: "\n").first ?? "")")
        #expect(v.ok)
        #expect(v.stdout.contains("Android Debug Bridge"))

        let d = try await client.run(["devices"], timeout: 15)
        print(">>> adb devices:\n\(d.stdout)")
        #expect(d.ok)
        #expect(d.stdout.contains("List of devices"))

        // tidy up our isolated server
        _ = try? await client.run(["kill-server"], timeout: 10)
    }

    @Test func streamingCapturesLines() async throws {
        guard FileManager.default.isExecutableFile(atPath: Self.devADB) else {
            print("（無 adb 可測，略過）"); return
        }
        let client = ADBClient(adbPath: Self.devADB, serverPort: 5599)!
        let box = LineBox()
        _ = try await client.runStreaming(["version"], timeout: 15) { box.add($0) }
        print(">>> streamed \(box.count) lines")
        #expect(box.count >= 1)
    }
}

final class LineBox: @unchecked Sendable {
    private let lock = NSLock(); private var lines: [String] = []
    func add(_ s: String) { lock.lock(); lines.append(s); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return lines.count }
}
