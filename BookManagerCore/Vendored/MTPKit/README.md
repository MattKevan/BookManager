# Vendored MTPKit (inlined into BookManagerCore)

MTPKit is the pure-Swift MTP-over-USB stack (native IOUSBHost — no libusb, no
libmtp) used by the app's device backend. It is **vendored directly into the
BookManagerCore target** (no Swift package) so the build is self-contained:
Xcode 26 (beta) mishandles local path packages (it recreates
`.swiftpm/xcode` metadata inside the package on every open and fails to load
it as a project, plus intermittent "Missing package product" errors). Inlining
eliminates package resolution and those GUI failures entirely — matching the
repo's precedent of vendoring libmobi's C sources.

## Source

- Upstream: <https://github.com/5j54d93/MTPKit> — revision **0.1.4** (MIT license).
- Imported files: `MTP/*` (12 files) + `Transport/DeviceTransport.swift`.
  The ADB layer (`ADB/`) and `Transport/MockTransport.swift` are Android/
  test-only and were not imported (verified: nothing in the imported files
  references them).

## Patches applied (drift from upstream)

1. **Discovery accepts interface class 255** (`USBDevice.swift`): the Kindle
   Paperwhite exposes a vendor-specific interface (class 255 / protocol 0),
   which stock MTPKit's discovery filter (`class == 6 && protocol == 1`)
   rejected. Widened to `(class == 6 && protocol == 1 || class == 255)`,
   still skipping Apple devices (vendor `0x05AC`).
2. **`DeviceTransport` renamed → `MTPDeviceTransport`**
   (`DeviceTransport.swift`, `MTPTransport.swift`): MTPKit's own transport
   protocol collided with BookManagerCore's app-facing `DeviceTransport`
   protocol. All other MTPKit types (`StorageInfo`, `FileNode`,
   `TransportError`, `DeviceChange`, `TransferProgress`, `TransportKind`,
   `ProgressHandler`) keep their upstream names — verified no collisions in
   BookManagerCore.
3. **`Bundle.module` replaced with `Bundle.main`** (`MTPError+Message.swift`):
   `Bundle.module` is SwiftPM-only and does not exist in an XcodeGen target.
   Localized error strings now fall back to the English key (the app is
   English-only). The helper `L(_:args:)` was renamed `loc(_:args:)` to
   satisfy the repo's lint rules.
4. **Mechanical rename** (`MTPTransport.swift`): local variable `e` → `ext`
   to satisfy the repo's lint rules (identifier length).

If you ever update MTPKit, re-apply the patches above and re-run the device
suites plus the hardware probe.
