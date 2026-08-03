import Testing
import Foundation
@testable import MTPKit

@Suite(.serialized) struct ADBTransportLiveTests {
    static let devADB = "/Users/Ricky/Developer/Android-File-Transfer/Android-File-Transfer/Resources/adb"
    static let serial = "192.168.1.106:41899"

    @Test func browseStoragesAndRoot() async throws {
        guard FileManager.default.isExecutableFile(atPath: Self.devADB) else { print("（無 adb，略過）"); return }
        let client = ADBClient(adbPath: Self.devADB, serverPort: 5577)!
        _ = try? await client.run(["connect", Self.serial], timeout: 15)
        guard let t = await ADBTransport.connect(client: client, serial: Self.serial) else {
            print("（連不上 \(Self.serial)，略過——請確認手機無線偵錯開著）"); return
        }
        print(">>> device: \(t.displayName)")
        let storages = (try? await t.storages()) ?? []
        print(">>> storages: \(storages.map { "\($0.name) \($0.id)" })")
        #expect(!storages.isEmpty)

        if let sid = storages.first?.id {
            let kids = (try? await t.listChildren(of: nil, in: sid)) ?? []
            let dirs = kids.filter(\.isDirectory).count
            print(">>> \(sid): \(kids.count) items (\(dirs) dirs)")
            for k in kids.prefix(6) {
                print("    \(k.isDirectory ? "📁" : "📄") \(k.name)  \(k.size)B  \(k.modifiedDate.map { "\($0)" } ?? "no-date")")
            }
            #expect(kids.count > 0)
        }
        await t.close()
    }
}
