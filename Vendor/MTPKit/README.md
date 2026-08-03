# Book Manager vendoring

Vendored from [5j54d93/MTPKit](https://github.com/5j54d93/MTPKit) 0.1.4 (MIT — see LICENSE).

**Patch applied** (`Sources/MTPKit/MTP/USBDevice.swift`): discovery now accepts
vendor-specific interface class 255 in addition to standard MTP class 6 /
protocol 1. The Kindle Paperwhite exposes its MTP interface as class 255 /
protocol 0, so stock MTPKit cannot discover it. Apple devices (0x05AC) are
still skipped.

---

# MTPKit

A dependency-free Swift package for talking to Android devices from macOS — browse storage and move files both ways over **USB（MTP）** and **Wi-Fi（ADB）**, behind one `async` `DeviceTransport` abstraction.

## Features

- **MTP over USB**, spoken directly through `IOUSBHost` — no `libmtp`, no C dependencies.
- **ADB over Wi-Fi** transport, with QR／pairing-code／IP pairing and mDNS auto-discovery.
- A single `DeviceTransport` protocol for both backends, plus a `MockTransport` for tests and previews.
- `async`/`await` throughout, `Sendable` value types, and a real-time `DeviceChange` event stream.
- Streaming up/download with progress reporting; handles files larger than 4 GB.
- **USB reliability built in**：data phases are terminated with a zero-length packet when their length is an exact multiple of the endpoint's max packet size（the classic "an upload of one specific size hangs forever" MTP failure）, halted bulk endpoints are cleared automatically after I/O errors instead of wedging the whole connection, and write draining is cancellation-aware and time-bounded so a stuck device can't freeze the session.
- **Android-only discovery**：Apple devices expose PTP too（an iPhone's photo interface）, so discovery skips them — an attached iPhone never shadows the actual Android phone.
- Zero third-party dependencies. Error messages localized in English and 繁體中文.

## Requirements

- macOS 15+
- Swift 6+（Xcode 16+）

## Installation

Swift Package Manager：

```swift
.package(url: "https://github.com/5j54d93/MTPKit.git", from: "0.1.4")
```

Then add `"MTPKit"` to your target's dependencies.

## Usage

```swift
import MTPKit

// USB／MTP
guard let transport = await MTPTransport.discover() else { return }
let storages = try await transport.storages()
let root = try await transport.listChildren(of: nil, in: storages[0].id)

try await transport.download(node.id, to: localURL) { progress in
    print(progress.fractionCompleted)
}
```

Both USB and Wi-Fi backends conform to `DeviceTransport`, so they're interchangeable from the caller's side.

## Notes for consumers

- **`adb` binary（Wi-Fi only）：** MTPKit does **not** bundle `adb`. `ADBClient` looks for it first in your app bundle（`Bundle.main`）, then in common install locations（Homebrew、Android SDK）, or you can pass an explicit path with `ADBClient(adbPath:)`. The USB／MTP path needs nothing extra.
- **Entitlements：** USB access via `IOUSBHost` requires the *consuming app* to declare the appropriate USB device entitlement, and the ADB transport spawns the `adb` subprocess — configure your app's sandbox/entitlements accordingly. A library can't carry these for you.
- **Tests：** the hardware（"live"）tests no-op gracefully when no device is attached, so the suite stays green on CI／without a phone.

## License

This package is [MIT licensed](https://github.com/5j54d93/MTPKit/blob/main/LICENSE).
