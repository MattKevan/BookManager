import Testing
import Foundation
import CryptoKit
@testable import MTPKit

/// Large-file upload: verifies byte-perfect result on the device (Android reassembles
/// transparently), live per-segment progress, and throughput. Cleans up after itself.
@Suite(.serialized) struct StreamingUploadLiveTests {

    final class Progress: @unchecked Sendable {
        private let lock = NSLock(); private(set) var updates = 0; private(set) var last: Int64 = 0
        func record(_ v: Int64) { lock.lock(); updates += 1; last = v; lock.unlock() }
    }

    @Test func largeFileUploadsIntactWithProgress() async throws {
        guard let transport = await MTPTransport.discover() else { print("（找不到裝置，略過）"); return }
        defer { Task { await transport.close() } }
        guard let sid = (try? await transport.storages())?.first?.id else { print("（鎖定/無儲存空間，略過）"); return }

        let sizeMB = 80
        let stamp = Int(Date().timeIntervalSince1970)
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("aft_big_\(stamp).bin")
        var data = Data(count: sizeMB * 1_048_576)
        data.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: UInt64.self); var g = SystemRandomNumberGenerator()
            for i in 0..<p.count { p[i] = g.next() }
        }
        try data.write(to: src)
        defer { try? FileManager.default.removeItem(at: src) }
        let srcDigest = SHA256.hash(data: data)

        let folder = try await transport.createDirectory(named: "AFT_BIG_\(stamp)", inParent: nil, in: sid)
        defer { Task { try? await transport.delete(folder.id) } }

        let prog = Progress()
        let start = Date()
        let uploaded = try await transport.upload(localURL: src, as: "big.bin", toParent: folder.id, in: sid) { p in
            prog.record(p.completedBytes)
        }
        let elapsed = Date().timeIntervalSince(start)
        #expect(uploaded.size == Int64(data.count))
        print(String(format: "\n上傳 %d MB 耗時 %.2fs → %.1f MB/s，進度回報 %d 次（最後 %d bytes）",
                     sizeMB, elapsed, Double(sizeMB)/elapsed, prog.updates, prog.last))
        #expect(prog.updates > 10)   // proves progress is fine-grained, not just 0→100%

        let back = FileManager.default.temporaryDirectory.appendingPathComponent("aft_back_\(stamp).bin")
        try await transport.download(uploaded.id, to: back) { _ in }
        defer { try? FileManager.default.removeItem(at: back) }
        let ok = SHA256.hash(data: try Data(contentsOf: back)) == srcDigest
        #expect(ok)
        print("SHA-256 相符：\(ok)（裝置端完整重組）\n")
    }
}
