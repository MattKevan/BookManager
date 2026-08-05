import Foundation
import IOKit
import os

/// Watches USB attach/detach via IOKit and calls `onChange` so the app can re-scan
/// automatically. Switching a phone to "file transfer" re-enumerates the USB device,
/// which fires the matched notification — no manual refresh needed.
public final class USBWatcher: @unchecked Sendable {
    private let handler: @Sendable () -> Void
    private let queue = DispatchQueue(label: "com.Ricky.Android-File-Transfer.usb-watch")
    private var port: IONotificationPortRef?
    private var matchedIter: io_iterator_t = 0
    private var terminatedIter: io_iterator_t = 0

    public init(onChange: @escaping @Sendable () -> Void) {
        self.handler = onChange
        queue.async { [weak self] in self?.start() }
    }

    deinit {
        if matchedIter != 0 { IOObjectRelease(matchedIter) }
        if terminatedIter != 0 { IOObjectRelease(terminatedIter) }
        if let port { IONotificationPortDestroy(port) }
    }

    private func start() {
        let port = IONotificationPortCreate(kIOMainPortDefault)
        self.port = port
        IONotificationPortSetDispatchQueue(port, queue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        let callback: IOServiceMatchingCallback = { refcon, iterator in
            guard let refcon else { return }
            Unmanaged<USBWatcher>.fromOpaque(refcon).takeUnretainedValue().handle(iterator)
        }

        IOServiceAddMatchingNotification(port, kIOMatchedNotification,
                                         IOServiceMatching("IOUSBHostDevice"),
                                         callback, refcon, &matchedIter)
        drain(matchedIter) // arm

        IOServiceAddMatchingNotification(port, kIOTerminatedNotification,
                                         IOServiceMatching("IOUSBHostDevice"),
                                         callback, refcon, &terminatedIter)
        drain(terminatedIter) // arm
    }

    private func handle(_ iterator: io_iterator_t) {
        drain(iterator)  // must consume to re-arm the notification
        handler()
    }

    private func drain(_ iterator: io_iterator_t) {
        var service = IOIteratorNext(iterator)
        while service != 0 {
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
    }
}
