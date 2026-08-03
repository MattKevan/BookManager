import Testing
import Foundation
@testable import MTPKit

@Suite struct MockTransportTests {

    @Test func seedsTwoStoragesWithRootFolders() async throws {
        let t = MockTransport()
        let storages = try await t.storages()
        #expect(storages.count == 2)

        let root = try await t.listChildren(of: nil, in: "s1")
        let names = root.map(\.name)
        #expect(names.contains("DCIM"))
        #expect(names.contains("Download"))
        // Directories sort before files; all root entries here are directories.
        let allDirectories = root.allSatisfy { $0.isDirectory }
        #expect(allDirectories)
    }

    @Test func navigatesIntoSubdirectory() async throws {
        let t = MockTransport()
        let root = try await t.listChildren(of: nil, in: "s1")
        let dcim = try #require(root.first { $0.name == "DCIM" })
        let dcimChildren = try await t.listChildren(of: dcim.id, in: "s1")
        let camera = try #require(dcimChildren.first { $0.name == "Camera" })
        let photos = try await t.listChildren(of: camera.id, in: "s1")
        #expect(photos.count == 6)
        let allJPEG = photos.allSatisfy { $0.fileExtension == "jpg" }
        #expect(allJPEG)
    }

    @Test func deleteRemovesNodeAndEmitsEvent() async throws {
        let t = MockTransport()
        var iterator = t.changes.makeAsyncIterator()

        let root = try await t.listChildren(of: nil, in: "s1")
        let download = try #require(root.first { $0.name == "Download" })
        let before = try await t.listChildren(of: download.id, in: "s1")
        let victim = try #require(before.first)

        try await t.delete(victim.id)

        let change = await iterator.next()
        guard case .removed(let id)? = change else {
            Issue.record("expected .removed, got \(String(describing: change))")
            return
        }
        #expect(id == victim.id)

        let after = try await t.listChildren(of: download.id, in: "s1")
        #expect(after.count == before.count - 1)
    }

    @Test func simulateExternalAddEmitsAdded() async throws {
        let t = MockTransport()
        var iterator = t.changes.makeAsyncIterator()

        let added = await t.simulateExternalAdd(named: "surprise.png", inParent: nil, in: "s1")

        let change = await iterator.next()
        guard case .added(let node)? = change else {
            Issue.record("expected .added, got \(String(describing: change))")
            return
        }
        #expect(node.id == added.id)
        #expect(node.name == "surprise.png")
        #expect(node.fileExtension == "png")
    }

    @Test func renameUpdatesNameAndExtension() async throws {
        let t = MockTransport()
        let root = try await t.listChildren(of: nil, in: "s1")
        let download = try #require(root.first { $0.name == "Download" })
        let file = try #require(try await t.listChildren(of: download.id, in: "s1").first { !$0.isDirectory })

        let renamed = try await t.rename(file.id, to: "renamed.zip")
        #expect(renamed.name == "renamed.zip")
        #expect(renamed.fileExtension == "zip")
    }
}
