import Foundation

/// In-memory `DeviceTransport` used to build and demo the UI without a real phone.
///
/// It seeds a small folder tree and implements every operation against a dictionary
/// of nodes, emitting `DeviceChange` events exactly like a real device would. The
/// `simulateExternal*` helpers stand in for "another app on the phone changed a file",
/// which is how we exercise live sync (e.g. delete on device -> row disappears).
public actor MockTransport: DeviceTransport {
    public nonisolated let id = "mock-pixel-8"
    public nonisolated let displayName = "Pixel 8（示範裝置）"
    public nonisolated let kind = TransportKind.mock
    public nonisolated let changes: AsyncStream<DeviceChange>

    private let continuation: AsyncStream<DeviceChange>.Continuation
    private var nodes: [String: FileNode] = [:]
    private var storageList: [StorageInfo] = []
    private var nextHandle = 1

    public init() {
        let (stream, continuation) = AsyncStream.makeStream(of: DeviceChange.self)
        self.changes = stream
        self.continuation = continuation
        let seeded = Self.makeSeed()
        self.nodes = seeded.nodes
        self.storageList = seeded.storages
        self.nextHandle = seeded.nextHandle
    }

    // MARK: DeviceTransport

    public func storages() async throws -> [StorageInfo] { storageList }

    public func listChildren(of parentID: String?, in storageID: String) async throws -> [FileNode] {
        nodes.values
            .filter { $0.storageID == storageID && $0.parentID == parentID }
            .sorted(by: Self.displayOrder)
    }

    public func metadata(for id: String) async throws -> FileNode {
        guard let node = nodes[id] else { throw TransportError.notFound(id: id) }
        return node
    }

    public func download(_ id: String, to destinationURL: URL, progress: @escaping ProgressHandler) async throws {
        guard let node = nodes[id] else { throw TransportError.notFound(id: id) }
        let total = max(node.size, 1)
        FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destinationURL)
        defer { try? handle.close() }

        let chunk = 256 * 1024
        var written: Int64 = 0
        let payload = Data(count: min(chunk, Int(total)))
        while written < total {
            try Task.checkCancellation()
            let thisChunk = Int(min(Int64(chunk), total - written))
            handle.write(payload.prefix(thisChunk))
            written += Int64(thisChunk)
            progress(TransferProgress(fileName: node.name, completedBytes: written, totalBytes: total))
            try await Task.sleep(nanoseconds: 30_000_000) // simulate transfer time
        }
    }

    @discardableResult
    public func upload(
        localURL: URL,
        as name: String,
        toParent parentID: String?,
        in storageID: String,
        progress: @escaping ProgressHandler
    ) async throws -> FileNode {
        let attrs = try? FileManager.default.attributesOfItem(atPath: localURL.path)
        let total = (attrs?[.size] as? Int64) ?? 0
        var sent: Int64 = 0
        let step = max(total / 8, 1)
        while sent < total {
            try Task.checkCancellation()
            sent = min(total, sent + step)
            progress(TransferProgress(fileName: name, completedBytes: sent, totalBytes: total))
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        let node = makeNode(name: name, isDirectory: false, parentID: parentID, storageID: storageID, size: total)
        nodes[node.id] = node
        emit(.added(node))
        return node
    }

    @discardableResult
    public func createDirectory(named name: String, inParent parentID: String?, in storageID: String) async throws -> FileNode {
        let node = makeNode(name: name, isDirectory: true, parentID: parentID, storageID: storageID, size: 0)
        nodes[node.id] = node
        emit(.added(node))
        return node
    }

    public func delete(_ id: String) async throws {
        guard nodes[id] != nil else { throw TransportError.notFound(id: id) }
        removeSubtree(id)
        emit(.removed(id: id))
    }

    @discardableResult
    public func rename(_ id: String, to newName: String) async throws -> FileNode {
        guard var node = nodes[id] else { throw TransportError.notFound(id: id) }
        node.name = newName
        node.fileExtension = node.isDirectory ? nil : (newName as NSString).pathExtension.lowercased().nilIfEmpty
        nodes[id] = node
        emit(.changed(node))
        return node
    }

    public func move(_ id: String, toParent newParentID: String?, in storageID: String) async throws {
        guard var node = nodes[id] else { throw TransportError.notFound(id: id) }
        node = FileNode(
            id: node.id, storageID: storageID, parentID: newParentID, name: node.name,
            isDirectory: node.isDirectory, size: node.size, modifiedDate: node.modifiedDate,
            fileExtension: node.fileExtension
        )
        nodes[id] = node
        emit(.removed(id: id))     // drop from the old directory's view
        emit(.added(node))         // appear in the new directory's view
    }

    // MARK: Simulating device-side changes (for live-sync demo & tests)

    /// Mimics another app on the phone creating a file/folder. Emits `.added`.
    @discardableResult
    public func simulateExternalAdd(
        named name: String,
        isDirectory: Bool = false,
        inParent parentID: String?,
        in storageID: String
    ) -> FileNode {
        let node = makeNode(name: name, isDirectory: isDirectory, parentID: parentID, storageID: storageID,
                            size: isDirectory ? 0 : Int64.random(in: 50_000...5_000_000))
        nodes[node.id] = node
        emit(.added(node))
        return node
    }

    /// Mimics the file being deleted on the phone. Emits `.removed`.
    public func simulateExternalRemove(_ id: String) {
        guard nodes[id] != nil else { return }
        removeSubtree(id)
        emit(.removed(id: id))
    }

    // MARK: Helpers

    private func emit(_ change: DeviceChange) { continuation.yield(change) }

    private func makeNode(name: String, isDirectory: Bool, parentID: String?, storageID: String, size: Int64) -> FileNode {
        defer { nextHandle += 1 }
        let id = "h\(nextHandle)"
        return FileNode(
            id: id, storageID: storageID, parentID: parentID, name: name,
            isDirectory: isDirectory, size: size, modifiedDate: Date(),
            fileExtension: isDirectory ? nil : (name as NSString).pathExtension.lowercased().nilIfEmpty
        )
    }

    private func removeSubtree(_ id: String) {
        for child in nodes.values where child.parentID == id {
            removeSubtree(child.id)
        }
        nodes[id] = nil
    }

    private static func displayOrder(_ a: FileNode, _ b: FileNode) -> Bool {
        if a.isDirectory != b.isDirectory { return a.isDirectory && !b.isDirectory }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }

    private static func makeSeed() -> (nodes: [String: FileNode], storages: [StorageInfo], nextHandle: Int) {
        var handle = 1
        var nodes: [String: FileNode] = [:]
        func node(_ name: String, _ isDir: Bool, parent: String?, storage: String, size: Int64) -> FileNode {
            defer { handle += 1 }
            return FileNode(
                id: "h\(handle)", storageID: storage, parentID: parent, name: name,
                isDirectory: isDir, size: size, modifiedDate: Date(),
                fileExtension: isDir ? nil : (name as NSString).pathExtension.lowercased().nilIfEmpty
            )
        }
        func add(_ n: FileNode) { nodes[n.id] = n }

        let storages = [
            StorageInfo(id: "s1", name: "內部儲存空間", capacityBytes: 128_000_000_000, freeBytes: 52_300_000_000),
            StorageInfo(id: "s2", name: "SD 卡", capacityBytes: 64_000_000_000, freeBytes: 60_100_000_000),
        ]

        let dcim = node("DCIM", true, parent: nil, storage: "s1", size: 0); add(dcim)
        let download = node("Download", true, parent: nil, storage: "s1", size: 0); add(download)
        let music = node("Music", true, parent: nil, storage: "s1", size: 0); add(music)
        add(node("Documents", true, parent: nil, storage: "s1", size: 0))

        let camera = node("Camera", true, parent: dcim.id, storage: "s1", size: 0); add(camera)
        for i in 1...6 {
            add(node(String(format: "IMG_%04d.jpg", i), false, parent: camera.id, storage: "s1",
                     size: Int64.random(in: 1_500_000...4_500_000)))
        }
        for name in ["report.pdf", "invoice.pdf", "notes.txt"] {
            add(node(name, false, parent: download.id, storage: "s1", size: Int64.random(in: 30_000...2_000_000)))
        }
        for i in 1...3 {
            add(node("track_\(i).mp3", false, parent: music.id, storage: "s1",
                     size: Int64.random(in: 3_000_000...8_000_000)))
        }
        return (nodes, storages, handle)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
