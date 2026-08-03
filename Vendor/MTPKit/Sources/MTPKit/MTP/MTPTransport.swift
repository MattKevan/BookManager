import Foundation

/// `DeviceTransport` backed by a real USB MTP device via `MTPSession`. The UI and
/// view models are unchanged — this simply slots in beneath the same abstraction the
/// mock uses. Operations also emit `DeviceChange` optimistically so the list updates
/// immediately; interrupt-endpoint events (Phase 3) will additionally cover changes
/// made on the phone itself.
public final class MTPTransport: DeviceTransport, @unchecked Sendable {
    public let id: String
    public let displayName: String
    public let kind = TransportKind.usbMTP
    public let changes: AsyncStream<DeviceChange>

    let session: MTPSession
    private let changeContinuation: AsyncStream<DeviceChange>.Continuation
    private var eventReader: MTPEventReader?

    private init(session: MTPSession, info: USBDevice.Info) {
        self.session = session
        self.id = String(format: "usb-%04x-%04x", info.vendorID, info.productID)
        self.displayName = info.product
        let (stream, continuation) = AsyncStream.makeStream(of: DeviceChange.self)
        self.changes = stream
        self.changeContinuation = continuation
        startEventMonitoring()
    }

    /// Begin forwarding device-side changes (files added/removed/renamed on the phone)
    /// into the `changes` stream — this is what makes the list update live without a
    /// reopen. Runs on a dedicated thread; metadata lookups go through the actor.
    private func startEventMonitoring() {
        let reader = MTPEventReader(session: session) { [weak self] event in
            guard let self else { return }
            Task { await self.handle(event) }
        }
        reader.start()
        eventReader = reader
    }

    private func handle(_ event: MTPEvent) async {
        switch event.eventCode {
        case .objectAdded:
            guard let handle = event.firstParameter else { return }
            if let info = try? await session.objectInfo(handle) {
                changeContinuation.yield(.added(Self.node(from: info, handle: handle)))
            }
        case .objectRemoved:
            guard let handle = event.firstParameter else { return }
            changeContinuation.yield(.removed(id: String(handle)))
        case .objectInfoChanged:
            guard let handle = event.firstParameter else { return }
            if let info = try? await session.objectInfo(handle) {
                changeContinuation.yield(.changed(Self.node(from: info, handle: handle)))
            }
        case .storeAdded, .storeRemoved, .storageInfoChanged:
            changeContinuation.yield(.storagesChanged)
        default:
            break
        }
    }

    /// Open + seize the first MTP interface and start a session. Returns nil if none.
    ///
    /// Claiming the device is a timing race with Google's Android File Transfer agent,
    /// so we terminate it and retry a few times before giving up. A genuine "no MTP
    /// interface present" returns immediately (the USB hot-plug watcher re-triggers us
    /// when one appears).
    public static func discover() async -> MTPTransport? {
        var didReset = false
        for attempt in 0..<4 {
            USBDevice.terminateCompetingClients()
            do {
                let device = try USBDevice.openFirstMTPInterface(seize: true)
                let session = MTPSession(device: device)
                try await session.open()
                let info = await session.deviceInfo
                return MTPTransport(session: session, info: info)
            } catch MTPError.interfaceNotFound {
                return nil // no MTP device attached
            } catch MTPError.deviceStalled where !didReset {
                // The interface opens but I/O is wedged — reset the device once and wait
                // for it to re-enumerate, then retry. This is the auto-recovery path.
                USBDevice.log.error("Device wedged during discover; issuing USB reset")
                didReset = true
                USBDevice.resetDevice()
                try? await Task.sleep(for: .seconds(2))   // allow re-enumeration
            } catch {
                USBDevice.log.error("MTP discover attempt \(attempt) failed: \(error.localizedDescription, privacy: .public)")
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        return nil
    }

    /// Reset the underlying USB device and tear down this transport. The caller (device
    /// manager) should drop this instance and re-discover. Used when an in-flight
    /// transaction wedges the connection.
    public static func recoverByReset() {
        USBDevice.resetDevice()
    }

    public func storages() async throws -> [StorageInfo] {
        let ids = try await session.storageIDs()
        var result: [StorageInfo] = []
        for id in ids {
            let info = try await session.storageInfo(id)
            let name = info.storageDescription.isEmpty
                ? (info.volumeIdentifier.isEmpty ? L("storage.generic") : info.volumeIdentifier)
                : info.storageDescription
            result.append(StorageInfo(id: String(id), name: name,
                                      capacityBytes: Int64(clamping: info.maxCapacity),
                                      freeBytes: Int64(clamping: info.freeSpace)))
        }
        return result
    }

    public func listChildren(of parentID: String?, in storageID: String) async throws -> [FileNode] {
        guard let storage = UInt32(storageID) else { throw TransportError.notFound(id: storageID) }
        let parent = parentID.flatMap { UInt32($0) } ?? mtpRootParentHandle
        let handles = try await session.objectHandles(storage: storage, parent: parent)
        var nodes: [FileNode] = []
        nodes.reserveCapacity(handles.count)
        for handle in handles {
            let info = try await session.objectInfo(handle)
            nodes.append(Self.node(from: info, handle: handle, sizeOverride: await accurateSize(handle, info)))
        }
        return nodes
    }

    public func metadata(for id: String) async throws -> FileNode {
        guard let handle = UInt32(id) else { throw TransportError.notFound(id: id) }
        let info = try await session.objectInfo(handle)
        return Self.node(from: info, handle: handle, sizeOverride: await accurateSize(handle, info))
    }

    /// Correct size for files larger than 4 GB: ObjectInfo's ObjectCompressedSize is a 32-bit
    /// field the device pins to 0xFFFFFFFF once the real size exceeds it, so fall back to the
    /// 64-bit ObjectSize property in that case.
    private func accurateSize(_ handle: UInt32, _ info: MTPObjectInfo) async -> Int64 {
        guard info.compressedSize == 0xFFFFFFFF else { return Int64(info.compressedSize) }
        if let size = try? await session.objectSize(handle) { return Int64(clamping: size) }
        return Int64(info.compressedSize)
    }

    /// One MTP transaction (GetObjectHandles) — much cheaper than a full listing, for polling.
    public func childIDs(of parentID: String?, in storageID: String) async throws -> Set<String> {
        guard let storage = UInt32(storageID) else { throw TransportError.notFound(id: storageID) }
        let parent = parentID.flatMap { UInt32($0) } ?? mtpRootParentHandle
        let handles = try await session.objectHandles(storage: storage, parent: parent)
        return Set(handles.map { String($0) })
    }

    public func download(_ id: String, to destinationURL: URL, progress: @escaping ProgressHandler) async throws {
        guard let handle = UInt32(id) else { throw TransportError.notFound(id: id) }
        let info = try await session.objectInfo(handle)
        let total = await accurateSize(handle, info)   // 64-bit; correct for files >4 GB
        FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
        let fileHandle = try FileHandle(forWritingTo: destinationURL)
        defer { try? fileHandle.close() }

        progress(TransferProgress(fileName: info.filename, completedBytes: 0, totalBytes: total))
        guard total > 0 else { return }

        // 32-bit offsets overflow past 4 GB, so switch to GetPartialObject64 for large files.
        // Smaller files keep the universally-supported 32-bit op.
        let needs64 = total > Int64(UInt32.max)
        var offset: Int64 = 0
        let chunkSize: Int64 = 4 << 20 // 4 MB — fewer USB round trips => higher throughput
        while offset < total {
            try Task.checkCancellation()
            let want = UInt32(min(chunkSize, total - offset))
            let part = needs64
                ? try await session.getPartialObject64(handle, offset: UInt64(offset), count: want)
                : try await session.getPartialObject(handle, offset: UInt32(offset), count: want)
            if part.isEmpty { break }
            try fileHandle.write(contentsOf: part)
            offset += Int64(part.count)
            progress(TransferProgress(fileName: info.filename, completedBytes: offset, totalBytes: total))
        }
    }

    @discardableResult
    public func upload(localURL: URL, as name: String, toParent parentID: String?, in storageID: String,
                       progress: @escaping ProgressHandler) async throws -> FileNode {
        guard let storage = UInt32(storageID) else { throw TransportError.notFound(id: storageID) }
        let parent = parentID.flatMap { UInt32($0) } ?? mtpRootParentHandle
        let total = (try? FileManager.default.attributesOfItem(atPath: localURL.path))?[.size] as? Int64 ?? 0
        progress(TransferProgress(fileName: name, completedBytes: 0, totalBytes: total))

        // Stream from disk in chunks so memory stays flat for large files. The device
        // reassembles the byte stream from the size declared in the data-phase header,
        // so chunking is invisible on the Android side.
        let handle = try await session.sendObjectFromFile(
            storage: storage, parent: parent, name: name,
            format: MTPObjectFormat.undefined, fileURL: localURL
        ) { sent in
            progress(TransferProgress(fileName: name, completedBytes: sent, totalBytes: total))
        }

        let node = Self.node(from: try await session.objectInfo(handle), handle: handle)
        changeContinuation.yield(.added(node))
        return node
    }

    @discardableResult
    public func createDirectory(named name: String, inParent parentID: String?, in storageID: String) async throws -> FileNode {
        guard let storage = UInt32(storageID) else { throw TransportError.notFound(id: storageID) }
        let parent = parentID.flatMap { UInt32($0) } ?? mtpRootParentHandle
        let handle = try await session.createFolder(storage: storage, parent: parent, name: name)
        let node = Self.node(from: try await session.objectInfo(handle), handle: handle)
        changeContinuation.yield(.added(node))
        return node
    }

    public func delete(_ id: String) async throws {
        guard let handle = UInt32(id) else { throw TransportError.notFound(id: id) }
        try await session.deleteObject(handle)
        changeContinuation.yield(.removed(id: id))
    }

    @discardableResult
    public func rename(_ id: String, to newName: String) async throws -> FileNode {
        guard let handle = UInt32(id) else { throw TransportError.notFound(id: id) }
        try await session.rename(handle, to: newName)
        let node = Self.node(from: try await session.objectInfo(handle), handle: handle)
        changeContinuation.yield(.changed(node))
        return node
    }

    public func move(_ id: String, toParent newParentID: String?, in storageID: String) async throws {
        guard let handle = UInt32(id), let storage = UInt32(storageID) else { throw TransportError.notFound(id: id) }
        let parent = newParentID.flatMap { UInt32($0) } ?? mtpRootParentHandle
        try await session.moveObject(handle, toStorage: storage, parent: parent)
        changeContinuation.yield(.removed(id: id))
    }

    public func close() async {
        eventReader?.stop()
        eventReader = nil
        await session.close()   // tearing down the interface unblocks the pending event read
        changeContinuation.finish()
    }

    // MARK: Mapping

    static func node(from info: MTPObjectInfo, handle: UInt32, sizeOverride: Int64? = nil) -> FileNode {
        let isRoot = info.parentObject == 0 || info.parentObject == mtpRootParentHandle
        let ext: String? = info.isDirectory ? nil : {
            let e = (info.filename as NSString).pathExtension.lowercased()
            return e.isEmpty ? nil : e
        }()
        return FileNode(
            id: String(handle),
            storageID: String(info.storageID),
            parentID: isRoot ? nil : String(info.parentObject),
            name: info.filename,
            isDirectory: info.isDirectory,
            size: sizeOverride ?? Int64(info.compressedSize),
            modifiedDate: info.dateModified,
            fileExtension: ext
        )
    }
}
