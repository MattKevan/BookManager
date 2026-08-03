import Foundation
import os

/// Serializes MTP transactions over a `USBDevice`. MTP is strictly one-transaction-
/// at-a-time, so this is an `actor`: every operation runs to completion before the
/// next begins. Blocking USB I/O happens inside the actor's isolation.
public actor MTPSession {
    static let log = Logger(subsystem: "com.Ricky.Android-File-Transfer", category: "MTP")

    private nonisolated let device: USBDevice
    private var transactionID: UInt32 = 0
    private var sessionOpen = false

    public init(device: USBDevice) { self.device = device }

    public var deviceInfo: USBDevice.Info { device.info }

    /// True if the device exposes an interrupt endpoint for asynchronous events.
    public nonisolated var hasEventEndpoint: Bool { device.info.interruptInAddress != nil }

    /// Read one interrupt event packet. Blocking (no timeout). Safe to call from a
    /// dedicated thread in parallel with bulk transactions — it uses a separate pipe and
    /// does not touch the actor's serialized state.
    public nonisolated func readEventPacket() throws -> Data {
        try device.readInterrupt()
    }

    // MARK: Session lifecycle

    public func open() throws {
        guard !sessionOpen else { return }
        do {
            _ = try runCommand(.openSession, params: [1]) // session id = 1
        } catch MTPError.operationFailed(let code) where code == MTPResponse.sessionAlreadyOpen.rawValue {
            // A session is still open from a previous run or another app (e.g. Android
            // File Transfer). The device allows only one — reset it and take over.
            Self.log.info("Session already open; resetting and reopening")
            _ = try? runCommand(.closeSession)
            do {
                _ = try runCommand(.openSession, params: [1])
            } catch MTPError.operationFailed(let code2) where code2 == MTPResponse.sessionAlreadyOpen.rawValue {
                // Device still reports it open; the single implicit session is usable.
            }
        }
        sessionOpen = true
        Self.log.info("MTP session opened")
    }

    public func close() {
        if sessionOpen {
            _ = try? runCommand(.closeSession)
            sessionOpen = false
        }
        device.close()
    }

    // MARK: High-level operations

    public func storageIDs() throws -> [UInt32] {
        var r = ByteReader(try receiveData(.getStorageIDs))
        return try r.u32Array()
    }

    public func storageInfo(_ id: UInt32) throws -> MTPStorageInfo {
        try MTPStorageInfo(parsing: try receiveData(.getStorageInfo, params: [id]))
    }

    /// Immediate children of `parent` (use `mtpRootParentHandle` for a storage root).
    public func objectHandles(storage: UInt32, parent: UInt32) throws -> [UInt32] {
        var r = ByteReader(try receiveData(.getObjectHandles, params: [storage, mtpAllFormats, parent]))
        return try r.u32Array()
    }

    public func objectInfo(_ handle: UInt32) throws -> MTPObjectInfo {
        try MTPObjectInfo(parsing: try receiveData(.getObjectInfo, params: [handle]))
    }

    /// The object's true size via the 64-bit ObjectSize property (0xDC04). ObjectInfo's
    /// ObjectCompressedSize is only 32-bit, so devices pin it to 0xFFFFFFFF for files larger
    /// than 4 GB — this property carries the real value.
    public func objectSize(_ handle: UInt32) throws -> UInt64 {
        var r = ByteReader(try receiveData(.getObjectPropValue,
                                           params: [handle, UInt32(MTPObjectProperty.objectSize)]))
        return try r.u64()
    }

    public func getObject(_ handle: UInt32) throws -> Data {
        try receiveData(.getObject, params: [handle])
    }

    /// Ranged read for streaming downloads. Returns up to `count` bytes from `offset`.
    public func getPartialObject(_ handle: UInt32, offset: UInt32, count: UInt32) throws -> Data {
        try receiveData(.getPartialObject, params: [handle, offset, count])
    }

    /// Ranged read with a 64-bit offset (Android extension), needed for files >4 GB whose
    /// offsets overflow the 32-bit `getPartialObject`. The offset is passed as low/high words.
    public func getPartialObject64(_ handle: UInt32, offset: UInt64, count: UInt32) throws -> Data {
        let low = UInt32(offset & 0xFFFFFFFF)
        let high = UInt32(offset >> 32)
        return try receiveData(.getPartialObject64, params: [handle, low, high, count])
    }

    public func deleteObject(_ handle: UInt32) throws {
        try runCommand(.deleteObject, params: [handle, 0])
    }

    /// Create a folder. Returns the new object handle.
    @discardableResult
    public func createFolder(storage: UInt32, parent: UInt32, name: String) throws -> UInt32 {
        let payload = MTPObjectInfo.encode(storageID: storage, parentObject: parent,
                                           format: MTPObjectFormat.association, sizeBytes: 0, filename: name)
        let resp = try sendData(.sendObjectInfo, params: [storage, parent], payload: payload)
        return resp.count >= 3 ? resp[2] : 0
    }

    /// Upload a file: SendObjectInfo (metadata) then SendObject (bytes). Returns the new handle.
    @discardableResult
    public func sendObject(storage: UInt32, parent: UInt32, name: String, format: UInt16, data: Data) throws -> UInt32 {
        let info = MTPObjectInfo.encode(storageID: storage, parentObject: parent,
                                        format: format, sizeBytes: UInt32(clamping: data.count), filename: name)
        let resp = try sendData(.sendObjectInfo, params: [storage, parent], payload: info)
        let newHandle = resp.count >= 3 ? resp[2] : 0
        try sendData(.sendObject, params: [], payload: data)
        return newHandle
    }

    /// Upload a file from disk with live progress.
    ///
    /// The whole SendObject data phase (12-byte header + file bytes) is sent as ONE
    /// logical USB transfer, but split into segments that are all *enqueued up front*
    /// (`enqueueIORequest`). IOUSBHost pipelines them as a continuous stream, so — unlike
    /// issuing multiple *synchronous* `sendIORequest`s, which each end with a short packet
    /// that makes the MTP responder think the data phase finished and wedges the device —
    /// no inter-segment short packet is produced. Per-segment completions drive progress.
    ///
    /// The file is memory-mapped (paged in on demand) so RAM stays low even for multi-GB
    /// files. Chunking is invisible to Android: the header declares the total length and
    /// the device reassembles the byte stream itself.
    @discardableResult
    public func sendObjectFromFile(
        storage: UInt32,
        parent: UInt32,
        name: String,
        format: UInt16,
        fileURL: URL,
        segmentSize: Int = 256 * 1024,
        onProgress: @escaping @Sendable (Int64) -> Void
    ) throws -> UInt32 {
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let totalSize = (attrs[.size] as? Int64).map { Int($0) } ?? 0

        // 1) Announce the object (name + size). ObjectInfo's size field is 32-bit; for files
        //    ≥ 4 GB MTP uses 0xFFFFFFFF as a sentinel ("see the actual data phase length").
        let infoSize: UInt32 = totalSize > Int(UInt32.max) ? 0xFFFFFFFF : UInt32(totalSize)
        let info = MTPObjectInfo.encode(storageID: storage, parentObject: parent,
                                        format: format, sizeBytes: infoSize, filename: name)
        let resp = try sendData(.sendObjectInfo, params: [storage, parent], payload: info)
        let newHandle = resp.count >= 3 ? resp[2] : 0

        if Task.isCancelled { throw TransportError.cancelled }

        // 2) SendObject command, then the data phase streamed straight from the mmap'd file.
        let tx = nextTransaction()
        try device.writeBulk(MTPContainer.encodeCommand(operation: .sendObject, transactionID: tx))

        // 12-byte data-phase header. Total length is 64-bit; if it overflows UInt32 (the
        // container length field), send 0xFFFFFFFF per the MTP large-object convention.
        let phaseLen = Int64(MTPContainerHeader.size) + Int64(totalSize)
        let lenField: UInt32 = phaseLen > Int64(UInt32.max) ? 0xFFFFFFFF : UInt32(phaseLen)
        var head = ByteWriter()
        head.u32(lenField)
        head.u16(MTPContainerType.data.rawValue)
        head.u16(MTPOperation.sendObject.rawValue)
        head.u32(tx)

        // Pipelined stream straight from the mmap'd file (memory stays bounded for multi-GB files).
        // A terminating ZLP is appended inside when the length is a multiple of the max packet size.
        try device.writeDataPhaseStreaming(header: head.bytes, fileURL: fileURL, segmentSize: segmentSize,
                                           onProgress: onProgress)

        // 3) Response closes the transaction.
        let response = try readContainer()
        try checkResponse(response.header, op: .sendObject)
        return newHandle
    }

    /// Rename by setting the ObjectFileName property. The value is an MTP string dataset.
    public func rename(_ handle: UInt32, to newName: String) throws {
        var w = ByteWriter()
        w.mtpString(newName)
        try sendData(.setObjectPropValue, params: [handle, UInt32(MTPObjectProperty.objectFileName)], payload: w.data)
    }

    /// Move an object to another folder within a storage (MoveObject).
    public func moveObject(_ handle: UInt32, toStorage storage: UInt32, parent: UInt32) throws {
        try runCommand(.moveObject, params: [handle, storage, parent])
    }

    // MARK: Transaction primitives

    private func nextTransaction() -> UInt32 {
        defer { transactionID &+= 1 }
        return transactionID
    }

    /// Command + Response (no data phase). Returns the response parameters.
    @discardableResult
    private func runCommand(_ op: MTPOperation, params: [UInt32] = []) throws -> [UInt32] {
        let tx = nextTransaction()
        try device.writeBulk(MTPContainer.encodeCommand(operation: op, transactionID: tx, parameters: params))
        let response = try readContainer()
        try checkResponse(response.header, op: op)
        return parameters(from: response.payload)
    }

    /// Command + Data-in + Response. Returns the data payload.
    private func receiveData(_ op: MTPOperation, params: [UInt32] = []) throws -> Data {
        let tx = nextTransaction()
        try device.writeBulk(MTPContainer.encodeCommand(operation: op, transactionID: tx, parameters: params))

        let first = try readContainer()
        if first.header.type == MTPContainerType.response.rawValue {
            try checkResponse(first.header, op: op) // device returned no data
            return Data()
        }
        guard first.header.type == MTPContainerType.data.rawValue else {
            throw MTPError.protocolError("預期 data 容器，收到 type=\(first.header.type)")
        }
        let response = try readContainer()
        try checkResponse(response.header, op: op)
        return first.payload
    }

    /// Command + Data-out + Response. Returns the response parameters.
    @discardableResult
    private func sendData(_ op: MTPOperation, params: [UInt32], payload: Data) throws -> [UInt32] {
        let tx = nextTransaction()
        try device.writeBulk(MTPContainer.encodeCommand(operation: op, transactionID: tx, parameters: params))
        try device.writeBulk(MTPContainer.encodeData(operation: op, transactionID: tx, payload: payload))
        let response = try readContainer()
        try checkResponse(response.header, op: op)
        return parameters(from: response.payload)
    }

    /// Read one full MTP container (handles multi-transfer data phases and ZLPs).
    private func readContainer() throws -> (header: MTPContainerHeader, payload: Data) {
        var buffer = Data()
        // Skip any zero-length packets before the header arrives.
        while buffer.count < MTPContainerHeader.size {
            let chunk = try device.readBulk()
            if chunk.isEmpty { continue }
            buffer.append(chunk)
        }
        let header = try MTPContainer.decodeHeader(buffer)
        let total = Int(header.length)
        // For exact-length containers, keep reading until we have it all.
        while total > buffer.count && total != Int(UInt32.max) {
            let chunk = try device.readBulk()
            if chunk.isEmpty { break }
            buffer.append(chunk)
        }
        let end = min(total, buffer.count)
        let payload = end > MTPContainerHeader.size ? buffer.subdata(in: MTPContainerHeader.size..<end) : Data()
        return (header, payload)
    }

    private func checkResponse(_ header: MTPContainerHeader, op: MTPOperation) throws {
        guard header.type == MTPContainerType.response.rawValue else {
            throw MTPError.protocolError("\(op) 預期 response，收到 type=\(header.type)")
        }
        guard header.code == MTPResponse.ok.rawValue else {
            Self.log.error("\(String(describing: op), privacy: .public) failed: 0x\(String(header.code, radix: 16))")
            throw MTPError.operationFailed(code: header.code)
        }
    }

    private func parameters(from payload: Data) -> [UInt32] {
        var r = ByteReader(payload)
        var params = [UInt32]()
        while r.remaining >= 4, let v = try? r.u32() { params.append(v) }
        return params
    }
}
