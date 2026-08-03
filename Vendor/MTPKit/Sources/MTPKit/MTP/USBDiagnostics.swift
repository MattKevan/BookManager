import Foundation
import IOKit
import IOKit.usb

/// Enumerates connected USB devices and their interfaces via the IORegistry.
///
/// This is a diagnostic aid: because Android phones expose MTP differently across
/// vendors (some as interface class 6 / PTP, some as a vendor-specific class with an
/// "MTP" interface string), seeing the *real* descriptors of a given device tells us
/// exactly what to match when opening it. It needs no device to be opened, so it works
/// even while `ptpcamerad` holds the device.
public enum USBDiagnostics {

    public struct Interface: Sendable {
        public var number: Int
        public var classCode: Int
        public var subclass: Int
        public var protocolCode: Int
        public var name: String
        /// Heuristic: looks like an MTP/PTP data interface.
        public var looksLikeMTP: Bool {
            classCode == 6 || name.uppercased().contains("MTP") || classCode == 255
        }
    }

    public struct Device: Sendable {
        public var vendorID: Int
        public var productID: Int
        public var product: String
        public var vendor: String
        public var deviceClass: Int
        public var interfaces: [Interface]
    }

    /// Structured scan, for programmatic use (e.g. device matching).
    public static func scan() -> [Device] {
        var iter: io_iterator_t = 0
        let matching = IOServiceMatching("IOUSBHostDevice")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iter) }

        var devices: [Device] = []
        while true {
            let service = IOIteratorNext(iter)
            if service == 0 { break }
            defer { IOObjectRelease(service) }
            var interfaces: [Interface] = []
            collectInterfaces(service, depth: 0, into: &interfaces)
            devices.append(Device(
                vendorID: intProp(service, "idVendor") ?? -1,
                productID: intProp(service, "idProduct") ?? -1,
                product: strProp(service, "USB Product Name") ?? strProp(service, "kUSBProductString") ?? "未知裝置",
                vendor: strProp(service, "USB Vendor Name") ?? strProp(service, "kUSBVendorString") ?? "未知廠商",
                deviceClass: intProp(service, "bDeviceClass") ?? -1,
                interfaces: interfaces
            ))
        }
        return devices
    }

    /// Human-readable report to paste back for debugging.
    public static func report() -> String {
        let devices = scan()
        var lines: [String] = []
        lines.append("USB 裝置掃描 — \(Date().formatted(date: .abbreviated, time: .standard))")
        lines.append(String(repeating: "─", count: 48))

        if devices.isEmpty {
            lines.append("找不到任何 USB 裝置。")
            lines.append("• 確認手機已用 USB 線接上 Mac")
            lines.append("• 在手機通知列把 USB 用途改成「檔案傳輸 / MTP」")
            return lines.joined(separator: "\n")
        }

        for device in devices {
            lines.append("")
            lines.append("▍\(device.vendor) — \(device.product)")
            lines.append(String(format: "   VID 0x%04X · PID 0x%04X · deviceClass %d",
                                device.vendorID, device.productID, device.deviceClass))
            if device.interfaces.isEmpty {
                lines.append("   ⚠️ 未列出介面（可能被 ptpcamerad / Image Capture 佔用）")
            }
            for itf in device.interfaces {
                let hint = itf.looksLikeMTP ? "   ← 可能是 MTP/PTP 介面" : ""
                let name = itf.name.isEmpty ? "" : " \"\(itf.name)\""
                lines.append(String(format: "   介面#%d  class=%d subclass=%d protocol=%d%@%@",
                                    itf.number, itf.classCode, itf.subclass, itf.protocolCode, name, hint))
            }
        }
        lines.append("")
        lines.append("共 \(devices.count) 個 USB 裝置。MTP 介面通常 class=6（PTP）或 vendor class=255，")
        lines.append("並具備 bulk-in / bulk-out / interrupt-in 三個端點（端點位址會在開啟介面後取得）。")
        return lines.joined(separator: "\n")
    }

    // MARK: IORegistry helpers

    private static func collectInterfaces(_ entry: io_registry_entry_t, depth: Int, into result: inout [Interface]) {
        guard depth < 6 else { return }
        var iter: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, kIOServicePlane, &iter) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iter) }
        while true {
            let child = IOIteratorNext(iter)
            if child == 0 { break }
            defer { IOObjectRelease(child) }
            if let cls = intProp(child, "bInterfaceClass") {
                result.append(Interface(
                    number: intProp(child, "bInterfaceNumber") ?? -1,
                    classCode: cls,
                    subclass: intProp(child, "bInterfaceSubClass") ?? -1,
                    protocolCode: intProp(child, "bInterfaceProtocol") ?? -1,
                    name: strProp(child, "USB Interface Name") ?? strProp(child, "kUSBString") ?? ""
                ))
            }
            collectInterfaces(child, depth: depth + 1, into: &result)
        }
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
