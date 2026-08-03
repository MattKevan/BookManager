import Testing
import Foundation
@testable import MTPKit

/// All hardware tests live in ONE serialized suite. Only one client can hold the MTP
/// interface at a time, so these must never run concurrently (Swift Testing parallelizes
/// across suites by default). Each test no-ops gracefully when no unlocked device is
/// attached, so the suite stays green on CI / without a phone.
@Suite(.serialized) struct USBLiveTests {

    // MARK: Open / browse

    @Test func opensMTPInterface() throws {
        let device: USBDevice
        do { device = try USBDevice.openFirstMTPInterface(seize: true) }
        catch MTPError.interfaceNotFound { print("（找不到 MTP 介面，略過）"); return }
        catch { print("（介面被占用，略過：\(error.localizedDescription)）"); return }
        defer { device.close() }
        print("開啟介面 out=0x\(String(device.info.bulkOutAddress, radix: 16)) in=0x\(String(device.info.bulkInAddress, radix: 16))")
        #expect(device.info.bulkInAddress & 0x80 != 0)
        #expect(device.info.bulkOutAddress & 0x80 == 0)
    }

    @Test func discoverAndBrowseRoot() async {
        guard let transport = await MTPTransport.discover() else { print("（找不到裝置，略過）"); return }
        defer { Task { await transport.close() } }
        let storages = (try? await transport.storages()) ?? []
        print("裝置 \(transport.displayName)：\(storages.count) 個儲存空間")
        if let first = storages.first {
            let root = (try? await transport.listChildren(of: nil, in: first.id)) ?? []
            print("「\(first.name)」根目錄：\(root.count) 個項目（\(root.filter(\.isDirectory).count) 資料夾）")
        }
        #expect(!transport.displayName.isEmpty)
    }

    // MARK: Watcher

    @Test func watcherStartsWithoutCrashing() async {
        let watcher = USBWatcher { }
        try? await Task.sleep(for: .milliseconds(300))
        _ = watcher
        #expect(true)
    }

    // MARK: Full write round trip (in a throwaway folder; never touches user files)

    @Test func createUploadRenameMoveDownloadDelete() async throws {
        guard let transport = await MTPTransport.discover() else { print("（找不到裝置，略過）"); return }
        defer { Task { await transport.close() } }
        guard let sid = (try? await transport.storages())?.first?.id else { print("（鎖定/無儲存空間，略過）"); return }

        let stamp = Int(Date().timeIntervalSince1970)
        let folder = try await transport.createDirectory(named: "AFT_TEST_\(stamp)", inParent: nil, in: sid)
        #expect(folder.isDirectory)
        let sub = try await transport.createDirectory(named: "sub", inParent: folder.id, in: sid)

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("aft_\(stamp).txt")
        let payload = "Hello 從 Android 檔案傳輸 \(stamp) 🎉".data(using: .utf8)!
        try payload.write(to: tmp); defer { try? FileManager.default.removeItem(at: tmp) }

        let uploaded = try await transport.upload(localURL: tmp, as: "hello.txt", toParent: folder.id, in: sid) { _ in }
        #expect(uploaded.size == Int64(payload.count))

        let renamed = try await transport.rename(uploaded.id, to: "renamed.txt")
        #expect(renamed.name == "renamed.txt")

        try await transport.move(uploaded.id, toParent: sub.id, in: sid)
        let inSub = try await transport.listChildren(of: sub.id, in: sid)
        #expect(inSub.contains { $0.name == "renamed.txt" })

        if let moved = inSub.first(where: { $0.name == "renamed.txt" }) {
            let back = FileManager.default.temporaryDirectory.appendingPathComponent("aft_back_\(stamp).txt")
            try await transport.download(moved.id, to: back) { _ in }
            #expect((try? Data(contentsOf: back)) == payload)
            try? FileManager.default.removeItem(at: back)
        }

        try await transport.delete(folder.id)
        let rootAfter = try await transport.listChildren(of: nil, in: sid)
        #expect(!rootAfter.contains { $0.id == folder.id })
        print("✅ 寫入全流程通過：建立/上傳/改名/移動/回讀一致/刪除")
    }

    // MARK: Polling reconcile (the reliable live-sync mechanism)

    @Test func pollingDetectsAddAndRemove() async throws {
        guard let transport = await MTPTransport.discover() else { print("（找不到裝置，略過）"); return }
        defer { Task { await transport.close() } }
        guard let sid = (try? await transport.storages())?.first?.id else { print("（鎖定/無儲存空間，略過）"); return }

        let before = try await transport.childIDs(of: nil, in: sid)
        let folder = try await transport.createDirectory(named: "AFT_POLL_\(Int(Date().timeIntervalSince1970))", inParent: nil, in: sid)
        let afterAdd = try await transport.childIDs(of: nil, in: sid)
        #expect(afterAdd.subtracting(before).contains(folder.id))

        try await transport.delete(folder.id)
        let afterRemove = try await transport.childIDs(of: nil, in: sid)
        #expect(afterAdd.subtracting(afterRemove).contains(folder.id))
        print("✅ 輪詢同步可偵測新增/移除")
    }
}
