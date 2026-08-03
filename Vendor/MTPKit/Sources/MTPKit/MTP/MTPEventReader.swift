import Foundation
import os

/// Reads MTP events off the interrupt endpoint on a dedicated thread and forwards parsed
/// events via a callback. A dedicated thread (not a Task) is used because the interrupt
/// read blocks indefinitely until an event arrives — we must not occupy a cooperative
/// executor thread for that. The loop ends when `stop()` is called and the pending read
/// unblocks (which happens naturally when the session/interface is destroyed).
public final class MTPEventReader: @unchecked Sendable {
    static let log = Logger(subsystem: "com.Ricky.Android-File-Transfer", category: "MTPEvent")

    private let session: MTPSession
    private let onEvent: @Sendable (MTPEvent) -> Void
    private let stateLock = NSLock()
    private var running = false
    private var thread: Thread?

    public init(session: MTPSession, onEvent: @escaping @Sendable (MTPEvent) -> Void) {
        self.session = session
        self.onEvent = onEvent
    }

    public func start() {
        guard session.hasEventEndpoint else {
            Self.log.info("No interrupt endpoint; event monitoring disabled")
            return
        }
        stateLock.lock(); running = true; stateLock.unlock()
        let thread = Thread { [weak self] in self?.loop() }
        thread.name = "com.Ricky.Android-File-Transfer.mtp-events"
        thread.start()
        self.thread = thread
    }

    public func stop() {
        stateLock.lock(); running = false; stateLock.unlock()
    }

    private var isRunning: Bool {
        stateLock.lock(); defer { stateLock.unlock() }; return running
    }

    private func loop() {
        Self.log.info("Event loop started")
        // Interrupt reads share the USB interface with the actor's bulk transactions.
        // If the device repeatedly errors on interrupt I/O, give up entirely rather than
        // risk interfering with file transfers — the polling fallback covers sync anyway.
        var consecutiveErrors = 0
        let maxConsecutiveErrors = 5
        while isRunning {
            do {
                let packet = try session.readEventPacket()
                guard isRunning else { break }
                consecutiveErrors = 0
                if let event = MTPEvent(parsing: packet) {
                    onEvent(event)
                }
            } catch {
                if !isRunning { break }
                consecutiveErrors += 1
                if consecutiveErrors >= maxConsecutiveErrors {
                    Self.log.info("Interrupt events unsupported/unstable on this device; disabling (polling covers sync)")
                    break
                }
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        Self.log.info("Event loop ended")
    }
}
