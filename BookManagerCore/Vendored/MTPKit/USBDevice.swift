import Foundation
import IOKit
import IOUSBHost
import os

/// Thin wrapper over an opened MTP USB interface: finds the PTP/MTP interface,
/// seizes it from the system (`ptpcamerad`), opens the bulk-in / bulk-out /
/// interrupt-in pipes, and exposes blocking bulk read/write used by `MTPSession`.
///
/// Blocking I/O is intentional: `MTPSession` is an actor that serializes all access,
/// and the work runs off the main thread.
public final class USBDevice: @unchecked Sendable {
    public struct Info: Sendable {
        public var vendorID: Int
        public var productID: Int
        public var product: String
        public var bulkOutAddress: Int
        public var bulkInAddress: Int
        public var interruptInAddress: Int?
    }

    static let log = Logger(subsystem: "com.Ricky.Android-File-Transfer", category: "USB")

    /// IOUSBHost dispatches async I/O completions on this queue. It must be user-initiated so the
    /// high-QoS transfer thread that blocks on those completions (the `DispatchSemaphore` /
    /// `DispatchGroup` waits in `writeDataPhaseStreaming`) never waits on a lower-QoS thread —
    /// otherwise the Thread Performance Checker flags a priority inversion. Pipes copied from the
    /// interface inherit this queue.
    private static let ioQueue = DispatchQueue(label: "com.Ricky.MTPKit.usb-io", qos: .userInitiated)

    private let interface: IOUSBHostInterface
    private let bulkOut: IOUSBHostPipe
    private let bulkIn: IOUSBHostPipe
    private let interruptIn: IOUSBHostPipe?
    /// Max packet size of the bulk OUT endpoint (512 on HS, 1024 on SS). Needed to know when a
    /// data phase whose length is an exact multiple requires a terminating Zero-Length Packet.
    private let bulkOutMaxPacket: Int
    public let info: Info

    private init(interface: IOUSBHostInterface, bulkOut: IOUSBHostPipe, bulkIn: IOUSBHostPipe,
                 interruptIn: IOUSBHostPipe?, bulkOutMaxPacket: Int, info: Info) {
        self.interface = interface
        self.bulkOut = bulkOut
        self.bulkIn = bulkIn
        self.interruptIn = interruptIn
        self.bulkOutMaxPacket = max(1, bulkOutMaxPacket)
        self.info = info
    }

    // MARK: Open

    /// Google's "Android File Transfer" installs a background agent that auto-grabs the
    /// MTP interface the moment a phone connects, fighting us for it. Since this app
    /// replaces it, terminate those processes before we claim the device. No-op if they
    /// aren't installed/running. (We run unsandboxed for personal use, so this is allowed.)
    public static func terminateCompetingClients() {
        for name in ["Android File Transfer Agent", "Android File Transfer"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            process.arguments = [name]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    log.info("Terminated competing client: \(name, privacy: .public)")
                }
            } catch {
                log.error("killall \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Find and open the first PTP/MTP interface (class 6, protocol 1). If `seize`,
    /// detach the current kernel owner (e.g. `ptpcamerad`) so we can claim it.
    public static func openFirstMTPInterface(seize: Bool = true) throws -> USBDevice {
        guard let service = findMTPInterfaceService() else { throw MTPError.interfaceNotFound }
        defer { IOObjectRelease(service) }

        let options: IOUSBHostObjectInitOptions = seize ? .deviceSeize : []
        let interface: IOUSBHostInterface
        do {
            interface = try IOUSBHostInterface(__ioService: service, options: options, queue: Self.ioQueue, interestHandler: nil)
        } catch {
            log.error("Open interface failed: \(error.localizedDescription, privacy: .public)")
            throw MTPError.usb("開啟 USB 介面失敗：\(error.localizedDescription)")
        }

        // Parse endpoints from the configuration descriptor.
        let config = interface.configurationDescriptor
        guard let ifaceDesc = IOUSBGetNextInterfaceDescriptor(config, nil) else {
            throw MTPError.usb("取不到介面描述子")
        }

        var bulkOutAddr: Int?
        var bulkInAddr: Int?
        var interruptInAddr: Int?
        var bulkOutMaxPacket = 512

        var current = UnsafeRawPointer(ifaceDesc).assumingMemoryBound(to: IOUSBDescriptorHeader.self)
        while let ep = IOUSBGetNextEndpointDescriptor(config, ifaceDesc, current) {
            let address = Int(IOUSBGetEndpointAddress(ep))
            let type = IOUSBGetEndpointType(ep)          // 2 = bulk, 3 = interrupt (USB bmAttributes)
            let isIn = (address & 0x80) != 0
            switch (type, isIn) {
            case (2, false):
                bulkOutAddr = address
                // wMaxPacketSize low 11 bits = packet size for bulk (bits 11–12 are HS high-
                // bandwidth, irrelevant for bulk). Descriptors are little-endian = native here.
                bulkOutMaxPacket = Int(ep.pointee.wMaxPacketSize & 0x07FF)
            case (2, true): bulkInAddr = address
            case (3, true): interruptInAddr = address
            default: break
            }
            current = UnsafeRawPointer(ep).assumingMemoryBound(to: IOUSBDescriptorHeader.self)
        }

        guard let outA = bulkOutAddr, let inA = bulkInAddr else {
            throw MTPError.usb("找不到 bulk 端點（out=\(String(describing: bulkOutAddr)) in=\(String(describing: bulkInAddr))）")
        }

        let bulkOut = try interface.copyPipe(withAddress: outA)
        let bulkIn = try interface.copyPipe(withAddress: inA)
        let interruptIn = interruptInAddr.flatMap { try? interface.copyPipe(withAddress: $0) }

        let info = Info(
            vendorID: intProp(service, "idVendor") ?? -1,
            productID: intProp(service, "idProduct") ?? -1,
            product: strProp(service, "USB Product Name") ?? "Android",
            bulkOutAddress: outA, bulkInAddress: inA, interruptInAddress: interruptInAddr
        )
        log.info("Opened MTP interface out=0x\(String(outA, radix: 16)) in=0x\(String(inA, radix: 16)) intr=\(interruptInAddr.map { "0x" + String($0, radix: 16) } ?? "none", privacy: .public) mps=\(bulkOutMaxPacket)")
        return USBDevice(interface: interface, bulkOut: bulkOut, bulkIn: bulkIn, interruptIn: interruptIn,
                         bulkOutMaxPacket: bulkOutMaxPacket, info: info)
    }

    // MARK: Bulk I/O

    /// Largest single bulk OUT request. Above ~1 MB some devices (e.g. Pixel 3a) wedge
    /// their USB state machine, so we cap each USB transfer here and loop. This is purely
    /// a transport-layer split within one MTP data phase — invisible to the device.
    static let maxBulkWriteChunk = 256 * 1024

    public func writeBulk(_ data: Data, timeout: TimeInterval = 15) throws {
        var offset = 0
        while offset < data.count {
            let end = min(offset + Self.maxBulkWriteChunk, data.count)
            let slice = data.subdata(in: offset..<end)
            let buffer = NSMutableData(data: slice)
            var transferred = 0
            do {
                try bulkOut.__sendIORequest(with: buffer, bytesTransferred: &transferred, completionTimeout: timeout)
            } catch {
                recoverHalt(bulkOut, after: error)
                throw Self.mapIOError(error)
            }
            if transferred != slice.count {
                Self.log.error("Short bulk write: \(transferred)/\(slice.count)")
            }
            offset = end
        }
    }

    /// Single-shot bulk write (no internal splitting) — one USB transfer for the whole
    /// buffer. Used to test/establish that an MTP data phase must be one sendIORequest.
    public func writeBulkRaw(_ data: Data, timeout: TimeInterval = 60) throws {
        let buffer = NSMutableData(data: data)
        var transferred = 0
        do {
            try bulkOut.__sendIORequest(with: buffer, bytesTransferred: &transferred, completionTimeout: timeout)
        } catch {
            recoverHalt(bulkOut, after: error)
            throw Self.mapIOError(error)
        }
    }

    /// A USB bulk OUT transfer whose total length is an exact multiple of the endpoint's max packet
    /// size needs a terminating Zero-Length Packet (USB 2.0 §5.8.3) — otherwise the device keeps
    /// waiting for more data and never sends its response, so the upload times out and the
    /// connection wedges. MTP responders depend on this; missing it is the classic cause of
    /// "uploads of certain sizes hang". Best-effort.
    private func sendZeroLengthPacketIfNeeded(totalBytes: Int) {
        guard bulkOutMaxPacket > 0, totalBytes % bulkOutMaxPacket == 0 else { return }
        var transferred = 0
        do {
            try bulkOut.__sendIORequest(with: NSMutableData(), bytesTransferred: &transferred, completionTimeout: 15)
            Self.log.info("Sent ZLP to terminate \(totalBytes)-byte data phase (mps=\(self.bulkOutMaxPacket))")
        } catch {
            recoverHalt(bulkOut, after: error)
            Self.log.error("ZLP send failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Stream `header` immediately followed by the bytes of `fileURL` as ONE continuous
    /// MTP data phase, split into pipelined bulk segments.
    ///
    /// Memory is bounded two ways, which matters for multi-GB files:
    ///  • the file is memory-mapped and each segment is copied out only when its request
    ///    is issued (never the whole file at once), and
    ///  • at most `maxInFlight` requests are outstanding (a sliding window), so we don't
    ///    allocate tens of thousands of buffers up front.
    /// Keeping several requests in flight preserves the "no inter-segment short packet"
    /// behaviour that a single synchronous-per-segment loop would break.
    func writeDataPhaseStreaming(header: [UInt8], fileURL: URL, segmentSize: Int,
                                 maxInFlight: Int = 8,
                                 onProgress: @escaping @Sendable (Int64) -> Void) throws {
        let mapped = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        let fileSize = mapped.count
        let total = header.count + fileSize

        let state = PipelineState()
        let inFlight = DispatchSemaphore(value: maxInFlight)
        let group = DispatchGroup()

        // Build the buffer for the segment covering [start, end) of the logical stream
        // (header occupies the first header.count bytes, file bytes follow).
        func makeBuffer(_ start: Int, _ end: Int) -> NSMutableData {
            let buf = NSMutableData(length: end - start)!
            let dst = buf.mutableBytes
            var cursor = start
            var outOff = 0
            // header portion
            if cursor < header.count {
                let hEnd = Swift.min(end, header.count)
                header.withUnsafeBytes { hp in
                    _ = memcpy(dst + outOff, hp.baseAddress!.advanced(by: cursor), hEnd - cursor)
                }
                outOff += hEnd - cursor
                cursor = hEnd
            }
            // file portion (offset into the file = cursor - header.count)
            if cursor < end {
                let fStart = cursor - header.count
                let fLen = end - cursor
                mapped.withUnsafeBytes { fp in
                    _ = memcpy(dst + outOff, fp.baseAddress!.advanced(by: fStart), fLen)
                }
            }
            return buf
        }

        var sent = 0
        var threwError: Error?
        while sent < total {
            if Task.isCancelled { threwError = TransportError.cancelled; break }
            if let err = state.firstError { threwError = Self.mapIOError(err); break }
            inFlight.wait()  // block until a slot frees up — bounds memory

            let start = sent
            let end = Swift.min(start + segmentSize, total)
            let bytes = end - start
            let buffer = makeBuffer(start, end)
            group.enter()
            do {
                try bulkOut.enqueueIORequest(with: buffer, completionTimeout: 30) { status, _ in
                    let done = state.record(status: status, bytes: bytes)
                    if let done { onProgress(Int64(max(0, done - header.count))) }
                    inFlight.signal()
                    group.leave()
                }
            } catch {
                inFlight.signal()
                group.leave()
                threwError = Self.mapIOError(error)
                break
            }
            sent = end
        }

        // Drain the outstanding requests, but poll rather than block once for a long time, so
        // we stay responsive to cancellation and to an error reported by a completion, and so a
        // wedged device can't freeze the MTP session for minutes.
        if threwError == nil {
            let deadline = Date().addingTimeInterval(120)
            while group.wait(timeout: .now() + 0.1) == .timedOut {
                if Task.isCancelled { threwError = TransportError.cancelled; break }
                if let err = state.firstError { threwError = Self.mapIOError(err); break }
                if Date() >= deadline { threwError = MTPError.deviceStalled; break }
            }
        }

        // Terminate the data phase with a ZLP when its length is an exact multiple of the max
        // packet size, or the device waits forever for more data and never responds.
        if threwError == nil, state.firstError == nil {
            sendZeroLengthPacketIfNeeded(totalBytes: total)
        }

        // Stopping early (cancel / error / timeout) can leave USB requests in flight; abort them
        // so they finish now — otherwise the next transaction on this endpoint would collide. A
        // synchronous abort returns only once the aborted IO has completed.
        if let threwError {
            try? bulkOut.__abort(with: .synchronous)   // waits for aborted IO to finish
            _ = group.wait(timeout: .now() + 5)
            // Clear the endpoint halt so the *next* MTP transaction can use the pipe; without this
            // a failed upload leaves the whole connection dead ("Unable to send IO").
            recoverHalt(bulkOut, after: threwError)
        }

        if let threwError { throw threwError }
        if let err = state.firstError { throw Self.mapIOError(err) }
    }

    public func readBulk(maxLength: Int = 512 * 1024, timeout: TimeInterval = 15) throws -> Data {
        guard let buffer = NSMutableData(length: maxLength) else { throw MTPError.usb("配置讀取緩衝失敗") }
        var transferred = 0
        do {
            try bulkIn.__sendIORequest(with: buffer, bytesTransferred: &transferred, completionTimeout: timeout)
        } catch {
            recoverHalt(bulkIn, after: error)
            throw Self.mapIOError(error)
        }
        return (buffer as Data).subdata(in: 0..<transferred)
    }

    /// Classify a raw IOUSBHost error. "Unable to send IO" means the device's USB state
    /// machine is wedged and only a port reset (re-enumeration) recovers it.
    private static func mapIOError(_ error: Error) -> MTPError {
        let ns = error as NSError
        if ns.domain == "IOUSBHostErrorDomain" && ns.code == -536870186 {
            return .deviceStalled
        }
        return .usb(error.localizedDescription)
    }

    /// kIOReturnTimeout (0xE00002D6) as a signed 32-bit NSError code. A bulk *timeout* does not
    /// halt the endpoint, so it must not trigger clearStall (which would reset the data toggle).
    private static func isTimeout(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == "IOUSBHostErrorDomain" && ns.code == -536870186
    }

    /// Whether `error` likely left the bulk endpoint Halted (so clearStall must clear it).
    /// Timeouts don't halt; cancellation is a deliberate abort (clearing would reset the toggle).
    private static func haltsEndpoint(_ error: Error) -> Bool {
        if isTimeout(error) { return false }
        if error is CancellationError { return false }
        if case TransportError.cancelled = error { return false }
        return true
    }

    /// After a bulk IO error the USB endpoint transitions to Halted and *must* be cleared before
    /// any further IO — otherwise every subsequent request fails with "Unable to send IO" and the
    /// whole connection appears dead until a full re-enumeration. `clearStall` sends
    /// CLEAR_FEATURE(ENDPOINT_HALT), aborts pending IO, and resets the data toggle. Best-effort;
    /// timeouts and cancellations are skipped (the pipe isn't halted in those cases).
    private func recoverHalt(_ pipe: IOUSBHostPipe, after error: Error) {
        guard Self.haltsEndpoint(error) else { return }
        do {
            try pipe.clearStall()
            Self.log.info("Cleared halted bulk endpoint after IO error")
        } catch {
            Self.log.error("clearStall failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Read one interrupt packet (events). Timeout must be 0 for interrupt pipes.
    public func readInterrupt(maxLength: Int = 1024) throws -> Data {
        guard let pipe = interruptIn else { throw MTPError.usb("無 interrupt 端點") }
        guard let buffer = NSMutableData(length: maxLength) else { throw MTPError.usb("配置中斷緩衝失敗") }
        var transferred = 0
        try pipe.__sendIORequest(with: buffer, bytesTransferred: &transferred, completionTimeout: 0)
        return (buffer as Data).subdata(in: 0..<transferred)
    }

    public func close() {
        interface.destroy()
    }

    // MARK: Recovery

    /// Reset and re-enumerate the USB device (software equivalent of unplug/replug).
    /// Used to recover from a wedged interface ("Unable to send IO"). After this the old
    /// IOService is invalid, so callers must discard their transport and re-discover.
    /// Returns true if a reset was issued.
    @discardableResult
    public static func resetDevice() -> Bool {
        guard let ifaceService = findMTPInterfaceService() else { return false }
        defer { IOObjectRelease(ifaceService) }
        guard let deviceService = parentUSBHostDevice(of: ifaceService) else { return false }
        defer { IOObjectRelease(deviceService) }

        do {
            let device = try IOUSBHostDevice(__ioService: deviceService, options: .deviceSeize,
                                             queue: nil, interestHandler: nil)
            try device.reset()
            device.destroy()
            log.info("Issued USB device reset (re-enumerating)")
            return true
        } catch {
            log.error("USB device reset failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Walk up the IORegistry from an interface service to its owning IOUSBHostDevice.
    private static func parentUSBHostDevice(of service: io_service_t) -> io_service_t? {
        var current = service
        IOObjectRetain(current)
        for _ in 0..<8 {
            var parent: io_service_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else {
                IOObjectRelease(current)
                return nil
            }
            IOObjectRelease(current)
            current = parent
            if IOObjectConformsTo(current, "IOUSBHostDevice") != 0 {
                return current // caller releases
            }
        }
        IOObjectRelease(current)
        return nil
    }

    // MARK: Discovery helpers

    static func findMTPInterfaceService() -> io_service_t? {
        guard let matching = IOServiceMatching("IOUSBHostInterface") else { return nil }
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }

        var service = IOIteratorNext(iter)
        while service != 0 {
            let cls = intProp(service, "bInterfaceClass")
            let proto = intProp(service, "bInterfaceProtocol")
            let vendor = intProp(service, "idVendor")
            // Class 6 (still imaging), protocol 1 = PTP/MTP. Apple devices (0x05AC) expose PTP
            // too — an iPhone's photo interface matches — but they're not MTP responders, so
            // they'd show up as a bogus device with no storages. Skip them; this also keeps an
            // attached iPhone from shadowing the actual Android phone.
            if (cls == 6 && proto == 1 || cls == 255) && vendor != 0x05AC { return service } // caller releases
            IOObjectRelease(service)
            service = IOIteratorNext(iter)
        }
        return nil
    }

    private static func intProp(_ service: io_service_t, _ key: String) -> Int? {
        guard let cf = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
              let number = cf as? NSNumber else { return nil }
        return number.intValue
    }

    private static func strProp(_ service: io_service_t, _ key: String) -> String? {
        guard let cf = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
              let string = cf as? String else { return nil }
        return string
    }
}

/// Thread-safe accumulator for pipelined transfer completions.
private final class PipelineState: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = 0
    private(set) var firstError: Error?

    /// Records one completion. Returns the new total bytes on success, or nil on error.
    func record(status: Int32, bytes: Int) -> Int? {
        lock.lock(); defer { lock.unlock() }
        if status != 0 {
            if firstError == nil { firstError = NSError(domain: "IOUSBHostErrorDomain", code: Int(status)) }
            return nil
        }
        completed += bytes
        return completed
    }
}
